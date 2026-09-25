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
# The inherit has to come first for PRODUCT_* : the upstream makefile ends with its own
# PRODUCT_NAME / PRODUCT_DEVICE / PRODUCT_MODEL assignments, so ours have to be written
# after it to win. (The one PRODUCT_COPY_FILES line above the inherit is the opposite
# case on purpose; its comment says why.) The block below is the exact opposite and has
# to come BEFORE, for a reason worth spelling out because it is easy to get backwards:
#
#   $(call inherit-product) does not include anything at the point it appears. It only
#   pushes an $(INHERIT_TAG)<path> marker onto every product variable
#   (build/make/core/product.mk:532-546); the real include happens later in
#   build/make/core/node_fns.mk:183-207, where _import-node does `include <parent>` at
#   :190 and only then recurses into that parent's own inherits at :201. Evaluation
#   order is therefore leaf -> epam -> trout -> cuttlefish. Anything a parent guards
#   with ?= or ifndef can be pre-empted by assigning it here, above the inherit.

# ---------------------------------------------------------------------------
# Vulkan: stop the APEX driver path, so the loader can see a Venus ICD.
#
# Above the inherit on purpose. cuttlefish's shared/device.mk and trout's
# aosp_trout_common.mk both write TARGET_VULKAN_SUPPORT ?= true, and evaluation
# order is leaf -> epam -> trout -> cuttlefish (see the note at the top of this
# file), so assigning it here pre-empts both.
#
# com.google.cf.vulkan's own .rc sets ro.vulkan.apex, and
# frameworks/native/vulkan/libvulkan/driver.cpp resolves that APEX's exported
# linker namespace and searches ONLY it -- so an ICD at
# /vendor/lib64/hw/vulkan.virtio.so cannot be found while the APEX is
# installed. Dropping the APEX is the smaller of the two ways out; the other is
# to ship the Venus ICD inside a vendor APEX with everything it links against.
#
# The guard is narrow, and the scope is measured rather than assumed:
# `grep -rn TARGET_VULKAN_SUPPORT device/google/trout device/google/cuttlefish
# device/epam` finds two `ifeq` sites in the whole tree, both in cuttlefish --
# shared/graphics/device_vendor.mk (the APEX) and shared/swiftshader/
# device_vendor.mk (execmem plus the use_vulkan_pastel soong config). trout only
# assigns the variable, and epam does not mention it. So the minigbm gralloc
# and both hwcomposer APEXes are outside it and keep working.
#
# The android.hardware.vulkan.* feature XMLs the dropped APEX carried are NOT
# re-declared: level-1/version-1_3/compute-0 describe gfxstream, not Venus over
# V3D. RenderEngine and HWUI reach the loader directly and do not read them.
TARGET_VULKAN_SUPPORT := false

# ABOVE the inherit, on purpose: for one destination the first PRODUCT_COPY_FILES entry
# wins (build/make/core/Makefile:139-156), and inherit-product puts the parent's entries
# where the inherit line is (product.mk:539-540), so a line below it would be dropped
# silently. This replaces trout's virtwifi.rc, which enabled Wi-Fi at every boot; see
# the file.
PRODUCT_COPY_FILES += \
    device/agl/xenvm-trout-rpi5/xenvm_trout_rpi5_arm64/virtwifi.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/virtwifi.rc

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

# Shadow-AP Wi-Fi: simulated radios in this guest beaconing the SSIDs DomD really
# sees, so the Settings Wi-Fi screen lists real access points instead of virt_wifi's
# single synthetic "VirtWifi".
#
# IT STARTS AUTOMATICALLY at sys.boot_completed (measured on the board,
# 2026-08-29), and the product ships no rc that starts virt_wifi: the two must
# never both own wlan0. The RPi4 product does the same. No hand-typed command is
# needed to bring the Wi-Fi path up.
#
# WHY NOT SHIPPING THE virt_wifi rc IS NOT MERELY TIDY. Such an rc runs
# `setup_wifi --interface=eth1` at `on boot`, which renames eth1 to buried_eth1 with
# SIOCSIFNAME. Dropping the upper virt_wifi link does NOT undo that rename, so
# doma-shadow-ap finds no eth1, logs "WARNING: eth1 absent; not enslaving", and
# br-shadow comes up with NO UPLINK -- the station associates and never gets a DHCP
# lease, with nothing in the log pointing at the cause. doma-shadow-ap.sh also
# renames it back (its step 1), so both halves of that failure are closed.
#
# The service is declared `disabled`; the only thing that starts it is
# `on property:sys.boot_completed=1` in the rc. The script reads
# persist.vendor.doma.shadow_ap (default true) at its TOP, and when it is not true it
# execs setup_wifi --interface=eth1 instead, handing wlan0 back to virt_wifi. So the
# risky part -- hostapd and the Wi-Fi HAL coexisting in one guest -- is recovered from
# on hardware with
#     setprop persist.vendor.doma.shadow_ap false && reboot
# rather than with an SD rewrite. setup_wifi itself lives in the com.google.cf.wifi
# apex, so not shipping the rc does not remove the fallback.
#
# THE SCAN RELAY. doma-shadow-ap only beacons what is in
# /data/vendor/wifi/shadow/aps.conf, and with nothing keeping that file current it
# stays at the seeded doma-shadow-aps.conf below, so the AAOS Wi-Fi screen lists a
# fixed set of SSIDs regardless of what DomD can see. doma-wifi-relay consumes the
# DomD agent's scan feed on /dev/hvc4 and the companion app's PSK drop-box, and keeps
# aps.conf in sync with the current scan. init.xenvm-hwsim.rc declares it `disabled`
# and starts it at sys.boot_completed; it follows the Settings Wi-Fi toggle, and
#     setprop persist.vendor.doma.wifi_relay false
# turns it off.
#
# These four are board-specific and stay in this board's own directory.
PRODUCT_COPY_FILES += \
    device/agl/xenvm-trout-rpi5/xenvm_trout_rpi5_arm64/init.xenvm-hwsim.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.xenvm-hwsim.rc \
    device/agl/xenvm-trout-rpi5/xenvm_trout_rpi5_arm64/doma-shadow-ap.sh:$(TARGET_COPY_OUT_VENDOR)/bin/doma-shadow-ap \
    device/agl/xenvm-trout-rpi5/xenvm_trout_rpi5_arm64/doma-shadow-aps.conf:$(TARGET_COPY_OUT_VENDOR)/etc/doma-shadow-aps.conf \
    device/agl/xenvm-trout-rpi5/xenvm_trout_rpi5_arm64/doma-wifi-relay.sh:$(TARGET_COPY_OUT_VENDOR)/bin/doma-wifi-relay

# The DomA half of the relay, built from device/agl/doma-common/DomaWifiRelay.
# The RPi4 product builds its own copy from device/sodev/xenvm-cf; the two
# copies are kept identical by hand. It is the only component that can learn the
# passphrase the user typed. NETWORK_SETTINGS is signature-level, but
# READ_WIFI_CREDENTIAL is signature|privileged, so the module ships a privapp
# allowlist entry (its Android.bp). It installs to /system_ext/priv-app, not
# /vendor: soong rejects platform_apis on a vendor module. It reads the same
# persist.vendor.doma.wifi_relay property and the same Settings Wi-Fi toggle as
# the shell daemon: `false` stops both.
PRODUCT_PACKAGES += \
    DomaWifiRelay

# WHY doma-shadow-aps.conf IS SHIPPED AT ALL.
# doma-shadow-ap dies with "$APS is empty" if /data/vendor/wifi/shadow/aps.conf
# has no content, and /data is empty on a first boot, so on a freshly flashed
# card the AAOS Wi-Fi screen would list nothing and there would be nothing to
# select. The script merges this file into aps.conf on every boot, adding only
# the SSIDs aps.conf lacks, so a row the relay or the user has written is never
# overwritten.
#
# IT CARRIES ONE PLACEHOLDER ROW, EXAMPLE-SSID, AND NO REAL PASSPHRASE: this
# file is in the source tree and in the vendor image. A real AP's passphrase is
# typed on the Wi-Fi screen and reaches the shadow AP through DomaWifiRelay; the
# file's own header says how, and why a shadow AP cannot learn it any other way.

# wificond. WifiNative talks to it over binder to do the nl80211 setup of wlan0, so
# without it enabling Wi-Fi fails at exactly one line -- "Failed to setup iface in
# nl80211=wlan0" -- and the vendor HAL then tears the interface straight back down.
#
# It is missing from the inherited set for a subtle reason worth writing down: that set
# DOES include wificond_compat_symlink_module, which installs
# /system/bin/wificond -> /system/system_ext/bin/wificond, but it does NOT include
# wificond itself. The result is a DANGLING SYMLINK and no wificond.rc anywhere in
# /system, so `start wificond` answers "Could not find 'wificond'". Verified on the
# running guest and in the build: product_packages.txt lists only
# wificond_compat_symlink_module, while all_modules.txt has wificond -- buildable,
# just never selected.
#
# Measured on hardware before adding this (logcat, DomA):
#   android.hardware.wifi-service: Adding interface handle for wlan0
#   android.hardware.wifi-service: Configured chip in mode 3      <- vendor HAL is fine
#   WifiNative: Failed to setup iface in nl80211=wlan0            <- wificond missing
#   WifiVendorHal: onIfaceRemoved 0, name: wlan0
#   WifiActiveModeWarden: ClientModeManager start failed!
PRODUCT_PACKAGES += wificond

# Render with Vulkan (Venus) by default: SurfaceFlinger's RenderEngine and HWUI in every
# app. Both are debug.* properties, which is the only switch either has -- SurfaceFlinger
# reads debug.renderengine.backend in chooseRenderEngineType() and has no ro.* variant;
# HWUI reads debug.hwui.renderer (Properties::peekRenderPipelineType) ahead of
# ro.hwui.use_vulkan. A vendor build.prop is allowed to carry debug.* (cuttlefish does the
# same for debug.sf.vsync_reactor_ignore_present_fences), and the alternative -- a
# hand-written /data/local.prop -- is lost by a factory reset or a fresh userdata.
#
# These two lines only make sense together with the DomD-side device model this series
# adds (virglrenderer 0017/0018/0021 and VKR_DEVICE_HEAP_MIB); without it the Vulkan
# path is not safe to switch on.
#
# The measurement behind choosing Vulkan over the GL default was taken on the RPi4 4 GiB
# board (2026-09-13: Settings cold start 18.8-24.0 s on Vulkan against 34.5-44.2 s on GL,
# and the GL runs fell into a VHAL/SystemUI crash cascade the Vulkan runs did not).
# NOT re-measured on a Raspberry Pi 5: the guest is the same virtio VM on both boards and
# the Venus path is board-independent, but this default is being set for rpi5 on the rpi4
# result. docs/VULKAN-VENUS.md records what was and was not verified on which board.
PRODUCT_VENDOR_PROPERTIES += \
    debug.renderengine.backend=skiavkthreaded \
    debug.hwui.renderer=skiavk
# Install the ICD. BOARD_MESA3D_VULKAN_DRIVERS only DEFINES the module --
# Mesa's android/Android.mk expands it to vulkan.virtio with an install path of
# /vendor/lib64/hw/vulkan.virtio.so -- and a module no product asks for is never
# installed. The gap is silent: measured on an rpi4 build with the board config
# alone, meson produced libvulkan_virtio.so and module-info.json listed
# vulkan.virtio with the right path, while /vendor/lib64/hw/ had no vulkan.*.so.
PRODUCT_PACKAGES += \
    vulkan.virtio

# ro.hardware.vulkan is the other half of the pair above, and without it the two
# properties above ask for a Vulkan backend the loader will never find one for:
# empty means the loader looks for no driver at all. BOARD_MESA3D_VULKAN_DRIVERS
# in this device's BoardConfig.mk builds the ICD this names.
PRODUCT_VENDOR_PROPERTIES += \
    ro.hardware.vulkan=virtio
