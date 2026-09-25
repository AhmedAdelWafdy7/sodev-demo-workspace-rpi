# SPDX-License-Identifier: Apache-2.0
#
# Raspberry Pi 5 variant of aosp_xenvm_trout_arm64.
#
# DomA is a virtio guest, so almost nothing here is board-specific and the Raspberry
# Pi 4 variant is deliberately close to this file. Diff the two when changing either;
# the differences that should exist are chiefly the names, the CPU variant (which
# lives in the BoardConfig), the paths to the board's own files, and whatever each
# board's hardware lanes need on their own.
#
# The guest is the upstream product plus what this file adds below. The
# identity is this variant's own, so that it gets its own PRODUCT_DEVICE (and
# therefore its own BoardConfig.mk and its own out/target/product/ tree); the
# board config is xenvm_trout_rpi5_arm64/BoardConfig.mk.
#
# The inherit has to come first: the upstream makefile ends with its own
# PRODUCT_NAME / PRODUCT_DEVICE / PRODUCT_MODEL assignments, so ours have to be
# written after it to win.
$(call inherit-product, device/epam/aosp-xenvm-trout/aosp_xenvm_trout_arm64.mk)

# WHY THIS PRODUCT HAS ITS OWN PRODUCT_DEVICE.
#
# DomA features need variables only a BoardConfig.mk can set, and a product
# makefile cannot set them: BOARD_VENDOR_SEPOLICY_DIRS for the shadow-AP policy
# among them.
#
# Having a BoardConfig.mk of our own requires a PRODUCT_DEVICE of our own:
# build/make/core/board_config.mk makes two BoardConfig.mk files found for one device
# name a hard error, so the upstream device name cannot carry a second one. Its
# output tree is therefore out/target/product/xenvm_trout_rpi5_arm64.
PRODUCT_NAME := aosp_xenvm_trout_rpi5_arm64
PRODUCT_DEVICE := xenvm_trout_rpi5_arm64
PRODUCT_MODEL := xenvm arm64 trout (Raspberry Pi 5)

# Start the interface rename that minradio's data call depends on. cuttlefish already
# ships the service and a trigger for it, but trout sets ro.vendor.disable_rename_eth0
# so that trigger never fires; overriding that is deliberate and argued in the .rc.
# Without this, AAOS never finishes a data call and retries setupDataCall at 7-13 Hz --
# measured on the Raspberry Pi 4 at 186 % of a physical core for 1 h 42 m with nothing
# on screen. The whole argument, the measurements and the boot timings that decide the
# trigger are in the .rc itself; read that before touching this line. Same shape as
# trout's own virtwifi.rc entry in device/google/trout/aosp_trout_arm64.mk.
#
# The Raspberry Pi 4 device carries the same file in its own repository: the fix is a
# property of minradio and trout, not of either board. This board ships all
# three ingredients, verified in its own build output: vendor/apex carries
# com.android.hardware.radio.minradio.virtual.apex, vendor/etc/init/init.cutf_cvm.rc
# carries the rename_eth0 service, and vendor/build.prop has
# ro.vendor.disable_rename_eth0=true.
PRODUCT_COPY_FILES += \
    device/agl/common/init.xenvm-buried-eth0.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.xenvm-buried-eth0.rc

# Settings.Global defaults for a fresh userdata: Bluetooth off (no transport in this
# guest, and com.android.bluetooth crash-loops without one) and window/transition
# animations off (the device model, not the GPU, pays for them). The overlay file
# carries the measurements and the runtime equivalents for an existing /data.
DEVICE_PACKAGE_OVERLAYS += device/agl/common/overlay
