# SPDX-License-Identifier: Apache-2.0
DESCRIPTION = "DomU graphics image with Wayland + Mesa (virgl) + SDL2 OpenGL ES \
for VirtIO-GPU based rendering. Bundled as initramfs to keep dom0less boot flow."

LICENSE = "Apache-2.0"

IMAGE_FEATURES = "empty-root-password allow-empty-password allow-root-login post-install-logging"
IMAGE_LINGUAS = ""
IMAGE_FSTYPES = "${INITRAMFS_FSTYPES}"

IMAGE_INSTALL = " \
    packagegroup-core-boot \
    base-files \
    busybox \
    udev \
    kmod \
    weston \
    weston-init \
    weston-examples \
    wayland \
    wayland-protocols \
    mesa \
    mesa-megadriver \
    libgles2-mesa \
    libegl-mesa \
    libsdl2 \
    sdl2-demo \
    evtest \
    libinput \
    openssh \
    openssh-sshd \
    openssh-sftp-server \
    domu-network \
    ${VENUS_GUEST_PACKAGES} \
    ${CORE_IMAGE_EXTRA_INSTALL} \
"

#
# [Venus] Guest-side Vulkan runtime, installed only in the Vulkan lane
# (GPU=vulkan -> 'venus' in DISTRO_FEATURES). See docs/VULKAN-VENUS.md.
#   - mesa-vulkan-drivers : in a GUEST this package carries the Venus ICD,
#     libvulkan_virtio.so -- oe-core's mesa.bb adds the 'virtio' PACKAGECONFIG
#     whenever opengl or vulkan is in DISTRO_FEATURES, and VULKAN_DRIVERS then
#     gains virtio. (In DomD the same package name carries V3DV instead, because
#     meta-raspberrypi adds 'broadcom' for the rpi override.)
#   - vulkan-loader : what the guest application loads the ICD through.
#   - vulkan-tools : vulkaninfo, for `vulkaninfo --summary` inside the guest.
#     No vkcube: oe-core builds this recipe with -DBUILD_CUBE=OFF.
#   - xt-venus-diag : vk-fence-test, vk-gl-import-test and vk-suballoc-probe --
#     three headless reproducers for the two guest-side defects in section 7a
#     (one per defect, plus the probe that narrows down defect A). They are what
#     tells a Venus failure in the guest apart from a compositor or a WSI
#     problem, and none of them needs a compositor to run.
# The guest kernel needs no change -- DomU's kernel here is linux-virtio-armv8
# (6.8.0-rc1, NOT the DomD linux-raspberrypi 6.18), whose defconfig already has
# CONFIG_DRM_VIRTIO_GPU=y, and 6.8 has the blob/context-init parameters Venus
# needs. udmabuf is a HOST requirement, not a guest one.
#
# This covers the in-tree DomU DEBUG image only. The AGL cluster rootfs that
# ships on SD p3 is built by build.sh from the AGL manifest, on poky scarthgap,
# and needs four conf lines and a layer rather than these packages: AGL's
# DISTRO_FEATURES has no 'vulkan' (poky-agl.conf:50) so the loader/tools are
# skipped, and scarthgap's mesa recipe never puts 'virtio' in VULKAN_DRIVERS so
# no libvulkan_virtio.so is built at all. docs/VULKAN-VENUS.md section 5 has the
# four conf lines and the sources.
VENUS_GUEST_PACKAGES = "${@bb.utils.contains('DISTRO_FEATURES', 'venus', 'mesa-vulkan-drivers vulkan-loader vulkan-tools xt-venus-diag', '', d)}"

inherit core-image

BAD_RECOMMENDATIONS += "busybox-syslog"

IMAGE_ROOTFS_SIZE ?= "524288"
IMAGE_ROOTFS_EXTRA_SPACE = "262144"

# Wayland + Mesa + SDL2 stack pushes initramfs above the 128 MiB default.
# Cap at 1 GiB to fit the Wayland graphics stack.
INITRAMFS_MAXSIZE = "1048576"
