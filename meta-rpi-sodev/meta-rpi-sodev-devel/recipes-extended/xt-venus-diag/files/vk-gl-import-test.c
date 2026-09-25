// SPDX-License-Identifier: Apache-2.0
/*
 * Headless reproducer for the venus->vrend cross-context sharing failure
 * (defect B): a Vulkan image is allocated through Venus, CLEARED BY THE GPU to a
 * known colour, exported as a dma-buf, and imported into a GL context served by
 * the same virtio-gpu device -- which is what makes the host's virglrenderer run
 * vrend_renderer_pipe_resource_set_type() on a resource created by its vkr side.
 *
 * STATUS: the defect this reproduces (defect B) is FIXED by meta-xt-qemu's 0117,
 * which gives virglrenderer the EGLDisplay SDL already created. The expected
 * result on a current image is exit 0 (import=ok); an exit of 2 means that fix
 * regressed. What the board used to show, and what an exit of 2 looks like:
 *   context 2 failed to dispatch PIPE_RESOURCE_SET_TYPE: 22
 *   vrend_decode_ctx_submit_cmd: context error reported 2 "agl-compositor" ...
 *
 * The verdict is deliberately content-based, not error-based: virgl command
 * submission is one-way, so a host-side refusal does NOT come back as a GL error
 * in the guest. The only guest-visible proof that the handover worked is reading
 * the Vulkan-written colour back out of the GL texture, so the program samples the
 * imported texture in a draw and glReadPixels one pixel.
 *
 * Everything the two APIs need is queried before it is used, and every exit path
 * prints a VERDICT line naming the stage -- a run that dies silently is
 * indistinguishable from a run that never started. Surfaceless EGL, so there is
 * no display dependency at all.
 *
 * Exit status -- THREE outcomes, not two, because "the environment is not set up"
 * and "the defect reproduced" must not look alike to a wrapper script:
 *   0 = the Vulkan-written colour came back out of the GL texture (import works).
 *   1 = SETUP/API failure: no Vulkan or EGL device, a missing extension or entry
 *       point, or an API error. Nothing was measured; VERDICT names the stage.
 *   2 = the defect REPRODUCED: everything ran and the pixels are wrong.
 * (The same convention in vk-fence-test and vk-suballoc-probe.)
 */
#define _GNU_SOURCE
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <vulkan/vulkan.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#define W 256
#define H 256

/* The colour the GPU clears the Vulkan image to, and what GL must read back. */
#define CLEAR_R 0.2f
#define CLEAR_G 0.4f
#define CLEAR_B 0.6f
#define TOL     10

#define VKCHECK(expr)                                                          \
   do {                                                                        \
      VkResult _r = (expr);                                                    \
      if (_r != VK_SUCCESS) {                                                  \
         printf("FAIL %s = %d\n", #expr, _r);                                  \
         printf("VERDICT: import=ERROR stage=vulkan at=%s\n", #expr);          \
         return 1;                                                             \
      }                                                                        \
   } while (0)

#define BAIL(stage, ...)                                                       \
   do {                                                                        \
      printf("FAIL " __VA_ARGS__);                                             \
      printf("VERDICT: import=ERROR stage=%s\n", stage);                       \
      return 1;                                                                \
   } while (0)

static bool
has_ext(const char *list, const char *ext)
{
   if (!list)
      return false;
   const size_t n = strlen(ext);
   for (const char *p = list; (p = strstr(p, ext)); p += n)
      if ((p == list || p[-1] == ' ') && (p[n] == ' ' || p[n] == '\0'))
         return true;
   return false;
}

static const char *vs_src =
   "attribute vec2 pos;\n"
   "varying vec2 uv;\n"
   "void main() { uv = pos * 0.5 + 0.5; gl_Position = vec4(pos, 0.0, 1.0); }\n";
static const char *fs_src =
   "precision mediump float;\n"
   "uniform sampler2D tex;\n"
   "varying vec2 uv;\n"
   "void main() { gl_FragColor = texture2D(tex, uv); }\n";

static GLuint
compile_shader(GLenum type, const char *src)
{
   GLuint s = glCreateShader(type);
   glShaderSource(s, 1, &src, NULL);
   glCompileShader(s);
   GLint ok = 0;
   glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
   if (!ok) {
      char log[512] = { 0 };
      glGetShaderInfoLog(s, sizeof(log) - 1, NULL, log);
      printf("shader compile failed: %s\n", log);
      return 0;
   }
   return s;
}

int
main(void)
{
   /* Line-buffer stdout: over ssh this is a pipe, and the default full buffering
    * would discard the whole log of a run killed by a wrapper timeout -- which is
    * exactly the failing run this exists to report on. */
   setvbuf(stdout, NULL, _IOLBF, 0);

   /* ---------------- Vulkan side: an exportable, GPU-cleared image ---------- */
   /* Both of the extensions this needs at instance level are core in 1.1, and
    * asking for them by name made the ICD refuse enumeration
    * (VK_ERROR_INITIALIZATION_FAILED) -- so declare 1.1 and use the core calls. */
   const VkApplicationInfo app = {
      .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .pApplicationName = "vk-gl-import-test",
      .apiVersion = VK_API_VERSION_1_1,
   };
   const VkInstanceCreateInfo ici = {
      .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
      .pApplicationInfo = &app,
   };
   VkInstance inst;
   VKCHECK(vkCreateInstance(&ici, NULL, &inst));

   /* Two-call form: the one-call form with a preset count came back
    * VK_ERROR_INITIALIZATION_FAILED from this ICD. */
   uint32_t n = 0;
   VKCHECK(vkEnumeratePhysicalDevices(inst, &n, NULL));
   printf("vk: %u physical device(s)\n", n);
   if (!n)
      BAIL("vk-device", "no physical device -- is the Venus ICD installed?\n");
   VkPhysicalDevice *pds = calloc(n, sizeof(*pds));
   VKCHECK(vkEnumeratePhysicalDevices(inst, &n, pds));
   VkPhysicalDevice pd = pds[0];
   for (uint32_t i = 0; i < n; i++) {
      VkPhysicalDeviceProperties p;
      vkGetPhysicalDeviceProperties(pds[i], &p);
      if (strstr(p.deviceName, "Venus")) {
         pd = pds[i];
         break;
      }
   }
   VkPhysicalDeviceProperties props;
   vkGetPhysicalDeviceProperties(pd, &props);
   printf("vk device: %s\n", props.deviceName);

   /* Check before enabling. venus only advertises dma-buf export when the HOST
    * renderer offers it, and that in turn needs EXT_image_drm_format_modifier and
    * EXT_queue_family_foreign on the host driver -- so on this board a missing
    * extension is a likely and interesting outcome in itself. An unchecked
    * vkCreateDevice would just fail with -7 and name none of them. */
   uint32_t de_count = 0;
   VKCHECK(vkEnumerateDeviceExtensionProperties(pd, NULL, &de_count, NULL));
   VkExtensionProperties *des = calloc(de_count, sizeof(*des));
   VKCHECK(vkEnumerateDeviceExtensionProperties(pd, NULL, &de_count, des));
   bool have_fd = false, have_dmabuf = false, have_foreign = false;
   for (uint32_t i = 0; i < de_count; i++) {
      if (!strcmp(des[i].extensionName, VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME))
         have_fd = true;
      else if (!strcmp(des[i].extensionName,
                       VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME))
         have_dmabuf = true;
      else if (!strcmp(des[i].extensionName,
                       VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME))
         have_foreign = true;
   }
   printf("vk exts: external_memory_fd=%d external_memory_dma_buf=%d "
          "queue_family_foreign=%d\n",
          have_fd, have_dmabuf, have_foreign);
   if (!have_fd || !have_dmabuf)
      BAIL("vk-ext",
           "the guest driver does not advertise dma-buf export, so this test "
           "cannot reach the import at all\n");

   const char *dev_exts[4];
   uint32_t dev_ext_count = 0;
   dev_exts[dev_ext_count++] = VK_KHR_EXTERNAL_MEMORY_EXTENSION_NAME;
   dev_exts[dev_ext_count++] = VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME;
   dev_exts[dev_ext_count++] = VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME;
   if (have_foreign)
      dev_exts[dev_ext_count++] = VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME;

   const float prio = 1.0f;
   const VkDeviceQueueCreateInfo qci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueFamilyIndex = 0,
      .queueCount = 1,
      .pQueuePriorities = &prio,
   };
   const VkDeviceCreateInfo dci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .queueCreateInfoCount = 1,
      .pQueueCreateInfos = &qci,
      .enabledExtensionCount = dev_ext_count,
      .ppEnabledExtensionNames = dev_exts,
   };
   VkDevice dev;
   VKCHECK(vkCreateDevice(pd, &dci, NULL, &dev));
   VkQueue queue;
   vkGetDeviceQueue(dev, 0, 0, &queue);

   /* LINEAR so the importing side needs no modifier negotiation -- the point here
    * is the cross-context handover, not tiling. A tiled swapchain image with a
    * real DRM modifier is a different case, which this test does not cover. */
   const VkExternalMemoryImageCreateInfo emici = {
      .sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
      .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
   };
   const VkImageCreateInfo imci = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
      .pNext = &emici,
      .imageType = VK_IMAGE_TYPE_2D,
      .format = VK_FORMAT_B8G8R8A8_UNORM,
      .extent = { W, H, 1 },
      .mipLevels = 1,
      .arrayLayers = 1,
      .samples = VK_SAMPLE_COUNT_1_BIT,
      .tiling = VK_IMAGE_TILING_LINEAR,
      .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
      .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
      .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
   };
   VkImage img;
   VKCHECK(vkCreateImage(dev, &imci, NULL, &img));

   VkMemoryRequirements mr;
   vkGetImageMemoryRequirements(dev, img, &mr);
   VkPhysicalDeviceMemoryProperties mp;
   vkGetPhysicalDeviceMemoryProperties(pd, &mp);
   uint32_t mt = UINT32_MAX;
   for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
      if (mr.memoryTypeBits & (1u << i)) {
         mt = i;
         break;
      }
   }
   if (mt == UINT32_MAX)
      BAIL("vk-memory", "no memory type accepts this image\n");

   const VkExportMemoryAllocateInfo emai = {
      .sType = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
      .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
   };
   const VkMemoryDedicatedAllocateInfo mdai = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
      .pNext = &emai,
      .image = img,
   };
   const VkMemoryAllocateInfo mai = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .pNext = &mdai,
      .allocationSize = mr.size,
      .memoryTypeIndex = mt,
   };
   VkDeviceMemory mem;
   VKCHECK(vkAllocateMemory(dev, &mai, NULL, &mem));
   VKCHECK(vkBindImageMemory(dev, img, mem, 0));

   /* Put a known colour in it with the GPU, so the GL side has something to
    * verify rather than merely something to bind. */
   const VkCommandPoolCreateInfo cpci = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .queueFamilyIndex = 0,
   };
   VkCommandPool pool;
   VKCHECK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
   const VkCommandBufferAllocateInfo cbai = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
      .commandPool = pool,
      .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
      .commandBufferCount = 1,
   };
   VkCommandBuffer cmd;
   VKCHECK(vkAllocateCommandBuffers(dev, &cbai, &cmd));
   const VkCommandBufferBeginInfo cbbi = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
      .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
   };
   VKCHECK(vkBeginCommandBuffer(cmd, &cbbi));

   const VkImageSubresourceRange range = {
      .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
      .levelCount = 1,
      .layerCount = 1,
   };
   const VkImageMemoryBarrier to_general = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
      .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
      .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
      .newLayout = VK_IMAGE_LAYOUT_GENERAL,
      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .image = img,
      .subresourceRange = range,
   };
   vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                        VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1,
                        &to_general);
   const VkClearColorValue clear = {
      .float32 = { CLEAR_R, CLEAR_G, CLEAR_B, 1.0f },
   };
   vkCmdClearColorImage(cmd, img, VK_IMAGE_LAYOUT_GENERAL, &clear, 1, &range);
   /* Release to an external user of the dma-buf. Only correct to express when
    * EXT_queue_family_foreign is present; without it fall back to a plain
    * barrier, which is enough for a diagnostic. */
   const VkImageMemoryBarrier release = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
      .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
      .oldLayout = VK_IMAGE_LAYOUT_GENERAL,
      .newLayout = VK_IMAGE_LAYOUT_GENERAL,
      .srcQueueFamilyIndex = have_foreign ? 0 : VK_QUEUE_FAMILY_IGNORED,
      .dstQueueFamilyIndex =
         have_foreign ? VK_QUEUE_FAMILY_FOREIGN_EXT : VK_QUEUE_FAMILY_IGNORED,
      .image = img,
      .subresourceRange = range,
   };
   vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT,
                        VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, NULL, 0,
                        NULL, 1, &release);
   VKCHECK(vkEndCommandBuffer(cmd));

   const VkFenceCreateInfo fci = { .sType =
                                      VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
   VkFence fence;
   VKCHECK(vkCreateFence(dev, &fci, NULL, &fence));
   const VkSubmitInfo si = {
      .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
      .commandBufferCount = 1,
      .pCommandBuffers = &cmd,
   };
   VKCHECK(vkQueueSubmit(queue, 1, &si, fence));
   /* Finite wait: on this board a fence can fail to signal for an unrelated
    * reason (defect A), and that must not turn into a hang here. The import is
    * attempted either way, and the readback then says whether the clear landed. */
   const VkResult wr = vkWaitForFences(dev, 1, &fence, VK_TRUE, 5000000000ull);
   printf("vk: clear submitted, fence %s\n",
          wr == VK_SUCCESS   ? "signalled"
          : wr == VK_TIMEOUT ? "TIMED OUT (defect A? the readback below still "
                               "tells you whether the clear reached the image)"
                             : "ERROR");

   PFN_vkGetMemoryFdKHR get_fd =
      (PFN_vkGetMemoryFdKHR)vkGetDeviceProcAddr(dev, "vkGetMemoryFdKHR");
   if (!get_fd)
      BAIL("vk-export", "no vkGetMemoryFdKHR\n");
   const VkMemoryGetFdInfoKHR gfi = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR,
      .memory = mem,
      .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
   };
   int dmabuf = -1;
   VKCHECK(get_fd(dev, &gfi, &dmabuf));
   VkSubresourceLayout layout;
   const VkImageSubresource sub = { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT };
   vkGetImageSubresourceLayout(dev, img, &sub, &layout);
   printf("vk: exported dma-buf fd %d, stride %llu, offset %llu, size %llu\n",
          dmabuf, (unsigned long long)layout.rowPitch,
          (unsigned long long)layout.offset, (unsigned long long)mr.size);

   /* ---------------- GL side: import it and read it back -------------------- */
   const char *client_exts = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
   if (!has_ext(client_exts, "EGL_MESA_platform_surfaceless"))
      BAIL("egl-platform",
           "no EGL_MESA_platform_surfaceless, so there is no display to use\n");
   PFNEGLGETPLATFORMDISPLAYEXTPROC get_disp =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress(
         "eglGetPlatformDisplayEXT");
   if (!get_disp)
      BAIL("egl-platform", "no eglGetPlatformDisplayEXT\n");
   EGLDisplay disp = get_disp(EGL_PLATFORM_SURFACELESS_MESA, NULL, NULL);
   EGLint major, minor;
   if (disp == EGL_NO_DISPLAY || !eglInitialize(disp, &major, &minor))
      BAIL("egl-init", "eglInitialize (0x%x)\n", eglGetError());
   printf("egl: %d.%d %s\n", major, minor, eglQueryString(disp, EGL_VENDOR));

   const char *disp_exts = eglQueryString(disp, EGL_EXTENSIONS);
   const bool have_dmabuf_import =
      has_ext(disp_exts, "EGL_EXT_image_dma_buf_import");
   const bool have_no_config = has_ext(disp_exts, "EGL_KHR_no_config_context");
   printf("egl exts: image_dma_buf_import=%d no_config_context=%d\n",
          have_dmabuf_import, have_no_config);
   if (!have_dmabuf_import)
      BAIL("egl-ext",
           "no EGL_EXT_image_dma_buf_import: the guest cannot even ask for the "
           "import, so this says nothing about the host\n");

   eglBindAPI(EGL_OPENGL_ES_API);
   const EGLint cfg_attrs[] = { EGL_SURFACE_TYPE,    EGL_PBUFFER_BIT,
                                EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                                EGL_NONE };
   EGLConfig cfg;
   EGLint cfg_n = 0;
   if (!eglChooseConfig(disp, cfg_attrs, &cfg, 1, &cfg_n) || !cfg_n) {
      if (!have_no_config)
         BAIL("egl-config", "no usable EGLConfig, and no "
                            "EGL_KHR_no_config_context to do without one\n");
      printf("egl: no matching config, using EGL_NO_CONFIG_KHR\n");
   }
   const EGLint ctx_attrs[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
   EGLContext ctx = eglCreateContext(disp, cfg_n ? cfg : EGL_NO_CONFIG_KHR,
                                     EGL_NO_CONTEXT, ctx_attrs);
   if (ctx == EGL_NO_CONTEXT ||
       !eglMakeCurrent(disp, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx))
      BAIL("egl-context", "eglCreateContext/MakeCurrent (0x%x)\n",
           eglGetError());
   printf("gl: %s / %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));

   const char *gl_exts = (const char *)glGetString(GL_EXTENSIONS);
   if (!has_ext(gl_exts, "GL_OES_EGL_image"))
      BAIL("gl-ext", "no GL_OES_EGL_image\n");

   PFNEGLCREATEIMAGEKHRPROC create_image =
      (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
   PFNGLEGLIMAGETARGETTEXTURE2DOESPROC image_target_texture =
      (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress(
         "glEGLImageTargetTexture2DOES");
   if (!create_image || !image_target_texture)
      BAIL("gl-ext",
           "missing eglCreateImageKHR / glEGLImageTargetTexture2DOES\n");

   const EGLint img_attrs[] = {
      EGL_WIDTH, W,
      EGL_HEIGHT, H,
      EGL_LINUX_DRM_FOURCC_EXT, 0x34325241 /* DRM_FORMAT_ARGB8888 */,
      EGL_DMA_BUF_PLANE0_FD_EXT, dmabuf,
      EGL_DMA_BUF_PLANE0_OFFSET_EXT, (EGLint)layout.offset,
      EGL_DMA_BUF_PLANE0_PITCH_EXT, (EGLint)layout.rowPitch,
      EGL_NONE
   };
   EGLImageKHR eimg = create_image(disp, EGL_NO_CONTEXT,
                                   EGL_LINUX_DMA_BUF_EXT, NULL, img_attrs);
   if (eimg == EGL_NO_IMAGE_KHR)
      BAIL("egl-create-image", "eglCreateImageKHR (0x%x)\n", eglGetError());
   printf("egl: image created\n");

   GLuint tex = 0;
   glGenTextures(1, &tex);
   glBindTexture(GL_TEXTURE_2D, tex);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
   glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
   image_target_texture(GL_TEXTURE_2D, eimg);
   GLenum gerr = glGetError();
   if (gerr != GL_NO_ERROR)
      BAIL("gl-bind", "glEGLImageTargetTexture2DOES (0x%x)\n", gerr);

   /* Render target for the readback, checked separately so its failures are not
    * reported as import failures. */
   GLuint fbo = 0, dst = 0;
   glGenTextures(1, &dst);
   glBindTexture(GL_TEXTURE_2D, dst);
   glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE,
                NULL);
   glGenFramebuffers(1, &fbo);
   glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                          dst, 0);
   const GLenum fb = glCheckFramebufferStatus(GL_FRAMEBUFFER);
   if (fb != GL_FRAMEBUFFER_COMPLETE)
      BAIL("gl-fbo", "framebuffer incomplete (0x%x)\n", fb);
   gerr = glGetError();
   if (gerr != GL_NO_ERROR)
      BAIL("gl-fbo", "setting up the render target (0x%x)\n", gerr);

   const GLuint vs = compile_shader(GL_VERTEX_SHADER, vs_src);
   const GLuint fs = compile_shader(GL_FRAGMENT_SHADER, fs_src);
   if (!vs || !fs)
      BAIL("gl-shader", "shader compilation\n");
   const GLuint prog = glCreateProgram();
   glAttachShader(prog, vs);
   glAttachShader(prog, fs);
   glLinkProgram(prog);
   GLint linked = 0;
   glGetProgramiv(prog, GL_LINK_STATUS, &linked);
   if (!linked)
      BAIL("gl-shader", "program link\n");
   glUseProgram(prog);
   glUniform1i(glGetUniformLocation(prog, "tex"), 0);

   /* Sample the imported texture. This is the operation the host has to have
    * typed the resource for. */
   glViewport(0, 0, W, H);
   glClearColor(1.f, 0.f, 1.f, 1.f); /* magenta: unmistakable if nothing draws */
   glClear(GL_COLOR_BUFFER_BIT);
   glActiveTexture(GL_TEXTURE0);
   glBindTexture(GL_TEXTURE_2D, tex);
   const GLfloat quad[] = { -1, -1, 1, -1, -1, 1, 1, 1 };
   const GLint loc = glGetAttribLocation(prog, "pos");
   glEnableVertexAttribArray(loc);
   glVertexAttribPointer(loc, 2, GL_FLOAT, GL_FALSE, 0, quad);
   glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
   glFinish();
   gerr = glGetError();
   if (gerr != GL_NO_ERROR)
      BAIL("gl-draw", "sampling the imported texture (0x%x)\n", gerr);

   unsigned char px[4] = { 0, 0, 0, 0 };
   glReadPixels(W / 2, H / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
   gerr = glGetError();
   if (gerr != GL_NO_ERROR)
      BAIL("gl-readback", "glReadPixels (0x%x)\n", gerr);

   const int want[3] = { (int)(CLEAR_R * 255.0f + 0.5f),
                         (int)(CLEAR_G * 255.0f + 0.5f),
                         (int)(CLEAR_B * 255.0f + 0.5f) };
   printf("gl: read back %u,%u,%u,%u (expected %d,%d,%d in some channel order)\n",
          px[0], px[1], px[2], px[3], want[0], want[1], want[2]);
   /* Accept any channel order: a swizzle between B8G8R8A8_UNORM and ARGB8888
    * would still prove the content crossed, and the raw value is printed. */
   int matched = 0;
   for (int w = 0; w < 3; w++)
      for (int c = 0; c < 3; c++)
         if (abs((int)px[c] - want[w]) <= TOL) {
            matched++;
            break;
         }
   const bool ok = matched == 3;
   printf("VERDICT: import=%s\n", ok ? "ok" : "FAILED");
   if (!ok)
      printf("note: no GL error was raised -- virgl submission is one-way, so a "
             "host-side refusal only shows up as wrong pixels. Check the device "
             "model log for PIPE_RESOURCE_SET_TYPE / XT-DIAG.\n");

   free(des);
   free(pds);
   return ok ? 0 : 2;
}
