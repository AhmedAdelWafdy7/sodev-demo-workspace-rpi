// SPDX-License-Identifier: Apache-2.0
/*
 * Where does venus' fence-feedback write actually land?
 *
 * vk-fence-test showed, 3/3 on the board, that a GPU fill of a 4 KiB host-visible
 * buffer comes back with 1023 of 1024 dwords correct and dword 0 holding
 * VK_SUCCESS -- a 4-byte value only venus' feedback fill writes -- while venus'
 * own poll of that slot never sees it. Two readings fit:
 *
 *   (a) the host writes the slot at the POOL BASE instead of at the slot's offset
 *       within venus' 16 MiB suballocation pool, and the test buffer happened to
 *       be the allocation at offset 0;
 *   (b) the write is where it belongs and the TEST BUFFER was bound at the wrong
 *       offset -- the guest's own view being self-consistent, so its fill looks
 *       correct while overlapping the slot.
 *
 * Both are a host/guest disagreement about a suballocation's offset, but they
 * point at different code, so this tells them apart: allocate THREE buffers with
 * distinct non-zero sentinels, fill only the middle one, and then scan all three.
 * Whichever buffer the stray VK_SUCCESS appears in, and at which offset, says
 * which reading is right -- and if it appears in none of them, the write went
 * somewhere outside these allocations, which rules out both and is equally
 * informative.
 *
 * The sentinels are non-zero on purpose: VK_SUCCESS is 0, so a zeroed buffer
 * could not be told apart from one that had been written.
 *
 * Exit status -- THREE outcomes, not two, because "the environment is not set up"
 * and "the defect reproduced" must not look alike to a wrapper script:
 *   0 = the fence signalled; read the `layout:` and `reading:` lines for where the
 *       write landed. A 0 here is not "nothing to see" -- it is the measurement.
 *   1 = SETUP/API failure: no physical device, no HOST_VISIBLE|HOST_COHERENT
 *       memory type, or an API error. Nothing was measured.
 *   2 = the fence did not signal, so the probe could not read a completed write.
 * (The same convention in vk-fence-test and vk-gl-import-test.)
 */
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vulkan/vulkan.h>

#define CHECK(expr)                                                            \
   do {                                                                        \
      VkResult _r = (expr);                                                    \
      if (_r != VK_SUCCESS) {                                                  \
         printf("FAIL %s = %d\n", #expr, _r);                                  \
         printf("VERDICT: probe=ERROR at=%s\n", #expr);                        \
         return 1;                                                            \
      }                                                                        \
   } while (0)

#define BUF_SIZE   4096
#define DWORDS     (BUF_SIZE / 4)
#define NBUF       3
#define FILL       0x5a5aa5a5u
/* Distinct, non-zero, and not the fill: each buffer's untouched state is
 * recognisable and cannot be confused with a VK_SUCCESS (0) write. */
static const uint32_t SENTINEL[NBUF] = { 0xdec0d000u, 0xdec0d111u, 0xdec0d222u };

struct buf {
   VkBuffer buffer;
   VkDeviceMemory mem;
   volatile uint32_t *map;
};

static double
now_s(void)
{
   struct timespec ts;
   clock_gettime(CLOCK_MONOTONIC, &ts);
   return ts.tv_sec + ts.tv_nsec / 1e9;
}

int
main(int argc, char **argv)
{
   setvbuf(stdout, NULL, _IOLBF, 0);
   const double budget = argc > 1 ? atof(argv[1]) : 4.0;

   const VkApplicationInfo app = {
      .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .pApplicationName = "vk-suballoc-probe",
      .apiVersion = VK_API_VERSION_1_1,
   };
   const VkInstanceCreateInfo ici = {
      .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
      .pApplicationInfo = &app,
   };
   VkInstance inst;
   CHECK(vkCreateInstance(&ici, NULL, &inst));

   uint32_t n = 0;
   CHECK(vkEnumeratePhysicalDevices(inst, &n, NULL));
   if (!n) {
      printf("FAIL no physical device\nVERDICT: probe=ERROR\n");
      return 1;
   }
   VkPhysicalDevice *pds = calloc(n, sizeof(*pds));
   CHECK(vkEnumeratePhysicalDevices(inst, &n, pds));
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
   printf("device: %s\n", props.deviceName);

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
   };
   VkDevice dev;
   CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
   VkQueue queue;
   vkGetDeviceQueue(dev, 0, 0, &queue);

   VkPhysicalDeviceMemoryProperties mp;
   vkGetPhysicalDeviceMemoryProperties(pd, &mp);
   const VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                      VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;

   struct buf b[NBUF];
   for (int i = 0; i < NBUF; i++) {
      const VkBufferCreateInfo bci = {
         .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
         .size = BUF_SIZE,
         .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
         .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
      };
      CHECK(vkCreateBuffer(dev, &bci, NULL, &b[i].buffer));
      VkMemoryRequirements mr;
      vkGetBufferMemoryRequirements(dev, b[i].buffer, &mr);
      uint32_t mt = UINT32_MAX;
      for (uint32_t k = 0; k < mp.memoryTypeCount; k++)
         if ((mr.memoryTypeBits & (1u << k)) &&
             (mp.memoryTypes[k].propertyFlags & want) == want) {
            mt = k;
            break;
         }
      if (mt == UINT32_MAX) {
         printf("FAIL no HOST_VISIBLE|HOST_COHERENT type\nVERDICT: probe=ERROR\n");
         return 1;
      }
      const VkMemoryAllocateInfo mai = {
         .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
         .allocationSize = mr.size,
         .memoryTypeIndex = mt,
      };
      CHECK(vkAllocateMemory(dev, &mai, NULL, &b[i].mem));
      CHECK(vkBindBufferMemory(dev, b[i].buffer, b[i].mem, 0));
      CHECK(vkMapMemory(dev, b[i].mem, 0, VK_WHOLE_SIZE, 0, (void **)&b[i].map));
      for (unsigned d = 0; d < DWORDS; d++)
         b[i].map[d] = SENTINEL[i];
      /* The mapped addresses show how the three sit relative to each other, which
       * is as close as a guest gets to seeing the pool's layout. */
      printf("buf%d: sentinel 0x%08x, mapped at %p%s\n", i, SENTINEL[i],
             (void *)b[i].map,
             i ? "" : "   (allocated first)");
   }
   for (int i = 1; i < NBUF; i++) {
      long long delta = (char *)b[i].map - (char *)b[0].map;
      printf("      buf%d is %+lld bytes from buf0%s\n", i, delta,
             (delta == BUF_SIZE * i) ? "  (contiguous -> same pool)" : "");
   }

   /* Fill ONLY the middle buffer. */
   const int TARGET = 1;
   const VkCommandPoolCreateInfo cpci = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .queueFamilyIndex = 0,
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
   vkCmdFillBuffer(cmd, b[TARGET].buffer, 0, BUF_SIZE, FILL);
   const VkBufferMemoryBarrier bmb = {
      .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
      .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
      .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .buffer = b[TARGET].buffer,
      .offset = 0,
      .size = BUF_SIZE,
   };
   vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT,
                        VK_PIPELINE_STAGE_HOST_BIT, 0, 0, NULL, 1, &bmb, 0, NULL);
   CHECK(vkEndCommandBuffer(cmd));

   const VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
   VkFence fence;
   CHECK(vkCreateFence(dev, &fci, NULL, &fence));
   const VkSubmitInfo si = {
      .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
      .commandBufferCount = 1,
      .pCommandBuffers = &cmd,
   };
   const double t0 = now_s();
   CHECK(vkQueueSubmit(queue, 1, &si, fence));
   const VkResult wr =
      vkWaitForFences(dev, 1, &fence, VK_TRUE, (uint64_t)(budget * 1e9));
   printf("fence after %.2fs: %s\n", now_s() - t0,
          wr == VK_SUCCESS ? "SIGNALLED" : wr == VK_TIMEOUT ? "TIMEOUT" : "ERROR");
   /* Give a late write time to land, as vk-fence-test does. */
   nanosleep(&(struct timespec){ .tv_sec = 1 }, NULL);

   /* Scan every buffer for anything that is not what it should hold. */
   int stray_total = 0;
   for (int i = 0; i < NBUF; i++) {
      const uint32_t expect = (i == TARGET) ? FILL : SENTINEL[i];
      unsigned bad = 0, shown = 0;
      for (unsigned d = 0; d < DWORDS; d++) {
         if (b[i].map[d] == expect)
            continue;
         bad++;
         if (shown < 6) {
            printf("  buf%d dword %u (offset %u) = 0x%08x  expected 0x%08x%s\n",
                   i, d, d * 4, b[i].map[d], expect,
                   b[i].map[d] == 0 ? "   <== VK_SUCCESS"
                   : b[i].map[d] == 1 ? "   <== VK_NOT_READY" : "");
            shown++;
         }
      }
      if (!bad)
         printf("  buf%d: intact (%s)\n", i,
                i == TARGET ? "filled as asked" : "sentinel untouched");
      else
         printf("  buf%d: %u of %u dwords unexpected\n", i, bad, DWORDS);
      if (i != TARGET)
         stray_total += bad;
   }

   const uint32_t tgt0 = b[TARGET].map[0];
   printf("VERDICT: probe fence=%s target_dword0=0x%08x stray_in_decoys=%d\n",
          wr == VK_SUCCESS ? "ok" : "STUCK", tgt0, stray_total);
   /* The mapped-address pattern is itself the tell for whether venus suballocated:
    * regular ascending spacing means sub-ranges of one pool, irregular spacing means
    * each allocation got its own memory (which is what VN_PERF=no_memory_suballoc
    * gives, and what a renderer reporting has_guest_vram gives -- on such a host this
    * probe cannot exercise the pool at all, so a pass there proves nothing). */
   const long long d1 = (char *)b[1].map - (char *)b[0].map;
   const long long d2 = (char *)b[2].map - (char *)b[0].map;
   const bool pooled = d1 > 0 && d2 == 2 * d1;
   printf("layout: %s\n",
          pooled ? "regular ascending spacing -- suballocated from one pool, so this "
                   "run did exercise it"
                 : "irregular spacing -- NOT suballocated, so this run says nothing "
                   "about the pool");
   printf("reading: %s\n",
          (wr == VK_SUCCESS && !stray_total && tgt0 == FILL)
             ? "clean pass: the fill went where it was asked and nothing else moved"
          : stray_total ? "the fill and/or the feedback write landed in a buffer that "
                          "was not the target -- compare the offsets with the layout above"
          : tgt0 == 0 ? "the stray write is in the TARGET's dword 0 even with a decoy "
                        "allocated first -- it tracks this buffer, not the pool base"
                      : "no stray write in these buffers: it landed outside them");

   free(pds);
   return wr == VK_SUCCESS ? 0 : 2;
}
