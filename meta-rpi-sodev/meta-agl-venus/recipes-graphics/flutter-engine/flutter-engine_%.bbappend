# Impeller's Vulkan backend leaks its thread-local command-pool and descriptor-pool caches
# on the embedder path, which is the path this image uses (ivi-homescreen installs no
# FlutterCompositor and returns a plain FlutterRendererConfig with .type = kVulkan, so the
# engine takes GPUSurfaceVulkanImpeller -> RenderToTarget(ContentContext&, ...)).
#
# Why this matters here and not on a phone: the leak is cheap in the guest (pool handles)
# and expensive on the host (their backing store). Measured on the RPi5 with the AGL cluster
# in a DomU over Venus, the host renderer grew 24-37 MiB/s with no plateau -- descriptor
# pools 0 -> 1540 in 30 s -- and freeing that set when the client exited livelocked DomD's
# V3D GEM-free path badly enough to starve RCU and take the domain unreachable.
#
# Upstream fixed the same leak for this path in flutter/flutter PR #182265, in
# GPUSurfaceVulkanImpeller::AcquireFrame, which 3.32.5 predates; the patch here
# makes the same call from RenderToTarget's cleanup closure instead. Upstream
# issue flutter/flutter#183267 documents the same omission on a third path. See
# docs/VULKAN-VENUS.md section 7a for the census that named it.
#
# Unconditional (`+=`) rather than a version-specific override on purpose: the
# omission is in 3.32.5, so if this layer is ever used with a newer engine
# do_patch should fail loudly rather than silently drop the fix.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://0001-impeller-trim-thread-local-pool-caches-in-RenderToTarget.patch"

# ADOPTED 2026-09-04: drop the onscreen swapchain from 4x MSAA to 1x. The patch below IS
# applied.
#
# What was weighed. On a tile-based GPU 4x multisampling quarters the tile size,
# so it is a tile-COUNT cost, not a resolve-bandwidth cost -- and the
# Skia/OpenGL embedder it was compared against is also 4x (meta-flutter's
# flutter-auto enables egl-multisample = EGL_SAMPLES 4), so section 7c's "same
# GPU time as Skia/GL" was 4x against 4x. The cost of dropping it is geometric
# edge antialiasing, which on a gauge cluster means the arcs and needles --
# quantified below.
#
# Measured on mesa 26.2.2 / fresh DomU / 40 s window:
#   application GPU   32.6 % -> 28.4 %      (-13 %)
#   total V3D render  77.0 % -> 72.2 %      (-5 points)
#   render-server GEM 134,544 -> 76,728 KiB (-57 MB; the two 4x targets, and the proof the
#                                            1x path is really active)
#   fps median        60.0 -> 60.0 (ceiling), fps min 36 -> 24  <- NOT an improvement
#   gl-skia control   unchanged
# Visual cost, measured on the arc of the left gauge: stair-stepping on the curved edge and
# on the thin radial ticks; text unaffected. Edge pixels in intermediate shades 46.9 % ->
# 41.5 %, mean gradient 72.0 -> 96.5 (34 % harder). engine 3.32.5 has no mitigation --
# --impeller-use-sdfs arrives in 3.44.
#
# And it is not an Impeller setting but a product MSAA policy: the Skia/GL embedder is also 4x
# (meta-flutter's flutter-auto enables egl-multisample = EGL_SAMPLES 4), so adopting 1x here
# without doing the same there would be inconsistent.
#
# THE DECIDING MEASUREMENT. The numbers above were measured with an idle GPU, where the cluster
# sits at the 60 fps ceiling either way and 1x could only show up as lower GPU time. The
# deciding measurement added DomA compositing with Vulkan (SkiaVk) as a steady second load
# -- the configuration this product actually targets -- four runs, order interleaved
# (measured under concurrent DomA load):
#   fps median        48.5 -> 52.5   (+8.2 %; under contention the headroom becomes frames)
#   total GPU render  88.4 % -> 83.9 %  (-4.5 pt), bin 12.3 % -> 8.3 %
#   render server GEM 134.4 -> 76.0 MB  (-58.4 MB, the same pool DomA's compositing uses)
#   fps min           start-up bound (1-4) in all four runs; the earlier 36 -> 24 did not
#                     reproduce
# The visual cost stands as documented above and was accepted as the product decision.
# recipes-graphics/flutter-auto/flutter-auto_%.bbappend removes egl-multisample
# from the OpenGL embedder this lane installs alongside, so both embedders
# follow one MSAA policy; --gpu=gl, which leaves this layer out, keeps
# meta-flutter's 4x.
SRC_URI += "file://0002-impeller-do-not-request-4x-MSAA-for-the-onscreen-swapchain.patch"
