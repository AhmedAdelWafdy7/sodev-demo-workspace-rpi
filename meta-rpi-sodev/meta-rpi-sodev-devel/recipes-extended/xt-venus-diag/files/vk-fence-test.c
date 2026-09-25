// SPDX-License-Identifier: Apache-2.0
/*
 * Minimal headless reproducer for the venus fence-feedback hang.
 *
 * STATUS: the defect this reproduces (defect A -- venus suballocating
 * host-visible memory so every buffer aliases the pool base) is FIXED by
 * meta-agl-venus' mesa patch 0002. The expected result on a current image is
 * exit 0 with fence=ok fill=ok; an exit of 2 means that fix regressed.
 *
 * One vkCmdFillBuffer into host-visible memory, submitted with a fence, then:
 *   1. poll vkGetFenceStatus  -- the path venus answers from its feedback slot
 *      (shared memory written by the host GPU), which is where DomU hangs;
 *   2. vkWaitForFences with a finite timeout, so a hang is a result and not a hang;
 *   3. read the whole buffer back through its mapping, twice: once as soon as the
 *      wait gives up, and again after a further wall-clock delay.
 *
 * (3) is the independent liveness signal, and the second read is what makes it
 * one. If the pattern is absent at first and present later, the GPU did execute
 * the fill and the guest can see GPU-written memory -- so the pages are shared
 * correctly and only the fence path is broken. If it never appears, either the
 * pages are wrong OR the submission never ran; that ambiguity is why this test
 * is read together with two control runs, VN_PERF=no_fence_feedback and
 * VN_PERF=no_memory_suballoc.
 *
 * No window system, no compositor, no swapchain -- so it runs the same under
 * plain qemu on a PC as it does in DomU on the board.
 *
 * Exit status -- THREE outcomes, not two, because "the environment is not set up"
 * and "the defect reproduced" must not look alike to a wrapper script:
 *   0 = the fence signalled and the buffer read back correctly (no defect here).
 *   1 = SETUP/API failure: no Vulkan device, a Vulkan call returned an error, or
 *       no suitable memory type. Nothing was measured. VERDICT says fence=ERROR.
 *   2 = the defect REPRODUCED: the run completed and the fence never signalled
 *       and/or the second read still did not show the pattern.
 * (The same convention in vk-gl-import-test and vk-suballoc-probe.)
 */
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vulkan/vulkan.h>

/* Every exit path prints a VERDICT line: the shell wrappers grep for it, and a
 * run that dies without one looks identical to a run that never started. */
#define CHECK(expr)                                                            \
   do {                                                                        \
      VkResult _r = (expr);                                                    \
      if (_r != VK_SUCCESS) {                                                  \
         printf("FAIL %s = %d\n", #expr, _r);                                  \
         printf("VERDICT: fence=ERROR fill=ERROR at=%s\n", #expr);             \
         return 1;                                                             \
      }                                                                        \
   } while (0)

#define BAIL(...)                                                              \
   do {                                                                        \
      printf("FAIL " __VA_ARGS__);                                             \
      printf("VERDICT: fence=ERROR fill=ERROR\n");                             \
      return 1;                                                                \
   } while (0)

#define FILL_PATTERN 0x5a5aa5a5u
#define BUF_SIZE     4096
#define BUF_DWORDS   (BUF_SIZE / 4)

static double
now_s(void)
{
   struct timespec ts;
   clock_gettime(CLOCK_MONOTONIC, &ts);
   return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* Sample every dword, not just the ends: a partially landed fill would otherwise
 * read as complete or as absent depending on which two words were checked. */
static unsigned
mismatches(const volatile uint32_t *data)
{
   unsigned bad = 0;
   for (unsigned i = 0; i < BUF_DWORDS; i++)
      if (data[i] != FILL_PATTERN)
         bad++;
   return bad;
}

int
main(int argc, char **argv)
{
   /* Line-buffer stdout. Over ssh this is a pipe, so the default full buffering
    * would discard every line of a run that ends in SIGTERM (a wrapper timeout)
    * or SIGABRT (mesa's vn_relax aborts on a fatal ring status) -- exactly the
    * failing runs this program exists to report on. */
   setvbuf(stdout, NULL, _IOLBF, 0);

   const double budget = argc > 1 ? atof(argv[1]) : 5.0;

   const VkApplicationInfo app = {
      .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .pApplicationName = "vk-fence-test",
      .apiVersion = VK_API_VERSION_1_1,
   };
   const VkInstanceCreateInfo inst_info = {
      .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
      .pApplicationInfo = &app,
   };
   VkInstance inst;
   CHECK(vkCreateInstance(&inst_info, NULL, &inst));

   uint32_t pd_count = 0;
   CHECK(vkEnumeratePhysicalDevices(inst, &pd_count, NULL));
   if (!pd_count)
      BAIL("no physical device -- is the Venus ICD installed?\n");
   VkPhysicalDevice *pds = calloc(pd_count, sizeof(*pds));
   CHECK(vkEnumeratePhysicalDevices(inst, &pd_count, pds));
   VkPhysicalDevice pd = pds[0];
   for (uint32_t i = 0; i < pd_count; i++) {
      VkPhysicalDeviceProperties p;
      vkGetPhysicalDeviceProperties(pds[i], &p);
      if (strstr(p.deviceName, "Venus")) {
         pd = pds[i];
         break;
      }
   }

   VkPhysicalDeviceProperties props;
   vkGetPhysicalDeviceProperties(pd, &props);
   printf("device: %s (driver 0x%x, api %u.%u.%u)\n", props.deviceName,
          props.driverVersion, VK_VERSION_MAJOR(props.apiVersion),
          VK_VERSION_MINOR(props.apiVersion), VK_VERSION_PATCH(props.apiVersion));

   /* A queue family that can do transfers -- vkCmdFillBuffer needs one. */
   uint32_t qf_count = 0;
   vkGetPhysicalDeviceQueueFamilyProperties(pd, &qf_count, NULL);
   VkQueueFamilyProperties *qfs = calloc(qf_count, sizeof(*qfs));
   vkGetPhysicalDeviceQueueFamilyProperties(pd, &qf_count, qfs);
   uint32_t qf = UINT32_MAX;
   for (uint32_t i = 0; i < qf_count; i++) {
      if (qfs[i].queueFlags & (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT |
                               VK_QUEUE_TRANSFER_BIT)) {
         qf = i;
         break;
      }
   }
   if (qf == UINT32_MAX)
      BAIL("no transfer-capable queue family\n");

   const float prio = 1.0f;
   const VkDeviceQueueCreateInfo qci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueFamilyIndex = qf,
      .queueCount = 1,
      .pQueuePriorities = &prio,
   };
   const VkDeviceCreateInfo dci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .queueCreateInfoCount = 1,
      .pQueueCreateInfos = &qci,
   };
   VkDevice dev;
   CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
   VkQueue queue;
   vkGetDeviceQueue(dev, qf, 0, &queue);

   const VkBufferCreateInfo bci = {
      .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
      .size = BUF_SIZE,
      /* venus' own feedback buffer is TRANSFER_SRC|DST and CONCURRENT when the
       * device has more than one queue family; on V3DV there is one family and
       * one memory type, so this lands in the same place. */
      .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
      .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
   };
   VkBuffer buf;
   CHECK(vkCreateBuffer(dev, &bci, NULL, &buf));

   VkMemoryRequirements mem_req;
   vkGetBufferMemoryRequirements(dev, buf, &mem_req);
   VkPhysicalDeviceMemoryProperties mem_props;
   vkGetPhysicalDeviceMemoryProperties(pd, &mem_props);
   /* Same properties venus' feedback pool asks for (it asks for HOST_COHERENT
    * alone; HOST_VISIBLE is implied by it being mappable). */
   const VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                      VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
   uint32_t mt = UINT32_MAX;
   for (uint32_t i = 0; i < mem_props.memoryTypeCount; i++) {
      if ((mem_req.memoryTypeBits & (1u << i)) &&
          (mem_props.memoryTypes[i].propertyFlags & want) == want) {
         mt = i;
         break;
      }
   }
   if (mt == UINT32_MAX)
      BAIL("no HOST_VISIBLE|HOST_COHERENT memory type\n");
   printf("memory type %u, heap %u, flags 0x%x\n", mt,
          mem_props.memoryTypes[mt].heapIndex,
          mem_props.memoryTypes[mt].propertyFlags);

   const VkMemoryAllocateInfo mai = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = mem_req.size,
      .memoryTypeIndex = mt,
   };
   VkDeviceMemory mem;
   CHECK(vkAllocateMemory(dev, &mai, NULL, &mem));
   CHECK(vkBindBufferMemory(dev, buf, mem, 0));

   volatile uint32_t *data = NULL;
   CHECK(vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, (void **)&data));
   /* Zeroed through the SAME mapping that is read back later, so a mapping that
    * points at the wrong pages can only ever produce a false MISSING, never a
    * false FILLED. */
   for (unsigned i = 0; i < BUF_DWORDS; i++)
      data[i] = 0;
   printf("before submit: data[0] = 0x%08x, %u/%u dwords already match\n",
          data[0], BUF_DWORDS - mismatches(data), BUF_DWORDS);

   const VkCommandPoolCreateInfo cpci = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .queueFamilyIndex = qf,
   };
   VkCommandPool pool;
   CHECK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
   const VkCommandBufferAllocateInfo cbai = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
      .commandPool = pool,
      .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
      .commandBufferCount = 1,
   };
   VkCommandBuffer cmd;
   CHECK(vkAllocateCommandBuffers(dev, &cbai, &cmd));

   const VkCommandBufferBeginInfo cbbi = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
      .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
   };
   CHECK(vkBeginCommandBuffer(cmd, &cbbi));
   vkCmdFillBuffer(cmd, buf, 0, BUF_SIZE, FILL_PATTERN);
   /* Make the transfer write visible to a host read, exactly as venus does after
    * filling its feedback slot. */
   const VkBufferMemoryBarrier bmb = {
      .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
      .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
      .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .buffer = buf,
      .offset = 0,
      .size = BUF_SIZE,
   };
   vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT,
                        VK_PIPELINE_STAGE_HOST_BIT, 0, 0, NULL, 1, &bmb, 0,
                        NULL);
   CHECK(vkEndCommandBuffer(cmd));

   const VkFenceCreateInfo fci = { .sType =
                                      VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
   VkFence fence;
   CHECK(vkCreateFence(dev, &fci, NULL, &fence));

   const VkSubmitInfo si = {
      .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
      .commandBufferCount = 1,
      .pCommandBuffers = &cmd,
   };
   const double t0 = now_s();
   CHECK(vkQueueSubmit(queue, 1, &si, fence));
   printf("submitted at t=0\n");

   /* 1. the polling path, which is what vn_WaitForFences drives internally.
    *    Throttled: with feedback disabled each vkGetFenceStatus is a synchronous
    *    ring round-trip, and an unthrottled loop would hammer the ring for the
    *    whole budget -- perturbing the very thing being measured, and making the
    *    poll count incomparable between lanes. */
   VkResult st = VK_NOT_READY;
   uint64_t polls = 0;
   double t_signal = -1.0;
   while (now_s() - t0 < budget) {
      st = vkGetFenceStatus(dev, fence);
      polls++;
      if (st != VK_NOT_READY) {
         t_signal = now_s() - t0;
         break;
      }
      nanosleep(&(struct timespec){ .tv_nsec = 200000 }, NULL);
   }
   const char *fence_word = st == VK_SUCCESS  ? "ok"
                            : st < 0         ? "ERROR"
                                             : "STUCK";
   printf("vkGetFenceStatus: %s after %.2fs and %llu polls (result %d)\n",
          st == VK_SUCCESS ? "SIGNALLED"
                           : st < 0 ? "DEVICE ERROR" : "NEVER SIGNALLED",
          t_signal >= 0 ? t_signal : now_s() - t0,
          (unsigned long long)polls, st);

   /* 2. the blocking path with a finite timeout, so this never hangs */
   const uint64_t ns = (uint64_t)(budget * 1e9);
   VkResult wr = vkWaitForFences(dev, 1, &fence, VK_TRUE, ns);
   printf("vkWaitForFences(%.1fs): %s (result %d)\n", budget,
          wr == VK_SUCCESS ? "SUCCESS" : wr == VK_TIMEOUT ? "TIMEOUT" : "ERROR",
          wr);
   const bool signalled = st == VK_SUCCESS || wr == VK_SUCCESS;

   /* 3. did the GPU's write actually reach the guest's mapping? Read now, and
    *    again after a further delay: a pattern that only appears on the second
    *    read proves the GPU ran and the guest can see its writes, which is the
    *    one observation that separates "the pages are wrong" from "the fence
    *    path is broken". Bounded on purpose -- vkQueueWaitIdle would be the
    *    natural liveness probe but it can block forever on a stalled ring. */
   unsigned bad1 = mismatches(data);
   unsigned bad2 = bad1;
   if (bad1) {
      nanosleep(&(struct timespec){ .tv_sec = (time_t)budget }, NULL);
      bad2 = mismatches(data);
   }
   const char *fill_word = !bad1 ? "ok" : !bad2 ? "late" : "MISSING";
   printf("buffer: data[0] = 0x%08x, mismatching dwords %u/%u then %u/%u -> %s\n",
          data[0], bad1, BUF_DWORDS, bad2, BUF_DWORDS,
          !bad1 ? "FILLED" : !bad2 ? "FILLED ONLY ON THE SECOND READ"
                                   : "NOT FILLED");

   printf("VERDICT: fence=%s fill=%s\n", fence_word, fill_word);

   /* Tearing down while the submission is still pending is invalid usage, and in
    * venus vkDestroyDevice can block on the stalled ring -- which would cost the
    * wrapper's timeout and, before stdout was line-buffered, the whole log. Leave
    * the objects to process exit in that case. */
   if (signalled) {
      vkDestroyFence(dev, fence, NULL);
      vkDestroyCommandPool(dev, pool, NULL);
      vkUnmapMemory(dev, mem);
      vkDestroyBuffer(dev, buf, NULL);
      vkFreeMemory(dev, mem, NULL);
      vkDestroyDevice(dev, NULL);
      vkDestroyInstance(inst, NULL);
   } else {
      printf("note: skipping teardown, the submission is still outstanding\n");
   }
   free(qfs);
   free(pds);
   return signalled && !bad2 ? 0 : 2;
}
