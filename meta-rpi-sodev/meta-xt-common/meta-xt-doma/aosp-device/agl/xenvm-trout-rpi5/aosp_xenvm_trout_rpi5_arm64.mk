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
# case on purpose; its comment says why.) The LOCAL_* block below is the exact
# opposite and has to come BEFORE, for a reason worth spelling out because it is easy
# to get backwards:
#
#   $(call inherit-product) does not include anything at the point it appears. It only
#   pushes an $(INHERIT_TAG)<path> marker onto every product variable
#   (build/make/core/product.mk:532-546); the real include happens later in
#   build/make/core/node_fns.mk:183-207, where _import-node does `include <parent>` at
#   :190 and only then recurses into that parent's own inherits at :201. Evaluation
#   order is therefore leaf -> epam -> trout -> cuttlefish. Anything a parent guards
#   with ?= or ifndef can be pre-empted by assigning it here, above the inherit.
#
#   LOCAL_* audio variables are also plain global Make variables, not entries in
#   _product_var_list, so clear-var-list in node_fns.mk never resets them and the value
#   set here survives all the way into trout's file.

# ---------------------------------------------------------------------------
# Audio policy: give Bluetooth a module that actually exists.
#
# device/google/trout/aosp_trout_common.mk:44 wraps its copy list in
# `ifndef LOCAL_AUDIO_PRODUCT_COPY_FILES`, so defining it here replaces trout's
# list wholesale. Four differences from trout's five entries:
#
#   * audio_policy_configuration.xml comes from this device dir instead of
#     device/google/trout/product_files/. It is a fork whose header documents both
#     changes; the short version is that trout includes
#     a2dp_audio_policy_configuration.xml, whose module is named "a2dp", and
#     audio.a2dp.default does not exist anywhere in AOSP 17. The implementation is
#     audio.bluetooth.default now and its module name is "bluetooth". Left alone,
#     Bluetooth pairs and connects and media routes "successfully" while nothing
#     comes out of the speaker.
#
#   * a2dp_audio_policy_configuration.xml is dropped and
#     bluetooth_audio_policy_configuration.xml (also a local fork, so the SCO/HFP
#     ports can be added in one place) is copied instead. The non-_7_0 variant is
#     REQUIRED: the top-level document is version="1.0" and lists samplingRates
#     comma-separated, while the _7_0 files use spaces.
#
#   * The three XIncludes trout references but never ships
#     (r_submix_audio_policy_configuration.xml, audio_policy_volumes.xml,
#     default_volume_tables.xml) ARE SHIPPED HERE.
#
#     The bug they caused: Serializer.cpp:869-871 only ALOGEs a failed XInclude and
#     carries on, and EngineBase.cpp:133-142 then fell back to gDefaultVolumeGroups
#     ("No legacy volume group found, using default music group"), because
#     parseLegacyVolumes() reads the <volumes> section of this very file
#     (EngineConfig.cpp:859-867). So the guest ran with ONE volume group and no
#     r_submix module, while audio.r_submix.default.so was installed all along and
#     merely absent from the policy.
#
#     THIS CHANGES AUDIO BEHAVIOUR ON PURPOSE. The guest gains the real legacy
#     volume curves in place of the single fallback group, and r_submix becomes
#     reachable. The check that confirms it on the board: the media volume slider
#     still behaves on the HDMI bus outputs and "No legacy volume group found" no
#     longer appears; `dumpsys audio` before and after is the comparison.
#
#     All three come from frameworks/av/services/audiopolicy/config/, i.e. exactly
#     the files the forked XML's xi:includes already name -- no fork needed.
#
#   * car_audio_configuration.xml, android.hardware.broadcastradio.xml and
#     usb_audio_policy_configuration.xml are unchanged from trout, and are
#     restated because defining the variable replaces the whole list.
#
# The two forked XMLs stay in this board's own directory: their contents differ per
# board, unlike the shared files named further down.
LOCAL_AUDIO_PRODUCT_COPY_FILES := \
    device/agl/xenvm-trout-rpi5/audio/audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_configuration.xml \
    device/agl/xenvm-trout-rpi5/audio/bluetooth_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/bluetooth_audio_policy_configuration.xml \
    device/google/trout/product_files/vendor/etc/car_audio_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/car_audio_configuration.xml \
    frameworks/native/data/etc/android.hardware.broadcastradio.xml:system/etc/permissions/android.hardware.broadcastradio.xml \
    frameworks/av/services/audiopolicy/config/usb_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/usb_audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/r_submix_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/r_submix_audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/audio_policy_volumes.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_volumes.xml \
    frameworks/av/services/audiopolicy/config/default_volume_tables.xml:$(TARGET_COPY_OUT_VENDOR)/etc/default_volume_tables.xml

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

# Settings.Global defaults for a fresh userdata: window/transition animations off (the
# device model, not the GPU, pays for them). The overlay file carries the measurements
# and the runtime equivalents for an existing /data.
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

# ---------------------------------------------------------------------------
# Bluetooth audio (A2DP). The HCI transport is separate and lives in DomD; this is
# only the path from AudioFlinger to the Bluetooth stack, and without it the HAL can
# be perfect and there will still be no sound.
#
# AOSP 17 needs BOTH halves, in the same process, and this image had NEITHER:
#
#   audio.bluetooth.default            the HW module AudioFlinger loads from
#                                      /vendor/lib64/hw/. Module name "bluetooth",
#                                      which is what the forked policy XML above
#                                      declares.
#   android.hardware.bluetooth.audio-impl
#                                      the AIDL IBluetoothAudioProviderFactory the
#                                      Bluetooth stack talks to. It is dlopened by
#                                      the HIDL audio HAL service we already ship:
#                                      hardware/interfaces/audio/common/all-versions/
#                                      default/service/service.cpp:136-145 lists it
#                                      in optionalInterfaceSharedLibs. So staying on
#                                      the HIDL audio HAL costs nothing here.
#
# libbluetooth_audio_session{,_aidl} are the in-process glue between the two and come
# in automatically as shared_libs; no explicit entry needed.
#
# No SELinux work: plat_service_contexts already labels
# android.hardware.bluetooth.audio.IBluetoothAudioProviderFactory/default as
# hal_audio_service, and system/sepolicy/private/bluetooth.te already grants
# `find` on it plus hal_client_domain(bluetooth, hal_audio). No VINTF work either:
# hardware/interfaces/bluetooth/audio/aidl/default/Android.bp declares
# vintf_fragments, so the manifest fragment installs itself.
#
# audio.bluetooth.default carries visibility: ["//device/generic/goldfish/hals/audio"],
# which does NOT block this. Soong visibility is only enforced on module DEPENDENCIES
# (build/soong/android/visibility.go:552, "depends on %s which is not visible"), and
# PRODUCT_PACKAGES is a Make-level install request. yukawa, hikey and dragonboard all
# install it exactly like this.
#
# Reference product for the whole shape (HIDL primary HAL + Bluetooth audio):
# device/amlogic/yukawa/device.mk:163-174.
PRODUCT_PACKAGES += \
    android.hardware.bluetooth.audio-impl \
    audio.bluetooth.default

# ---------------------------------------------------------------------------
# HFP: hand SCO to the audio framework and pick the software data path.
#
# These two properties are the last piece of the HFP work and MUST come after the code
# and policy changes, not before. Those are, in order:
#
#   1. bta_hf_client_sco.cc asks for the HCI data path
#   2. bta/hf_client implements the software data path
#   3. audio_bluetooth_hw maps SCO devices to HFP_SOFTWARE_*
#   4. the forked bluetooth_audio_policy_configuration.xml above declares the SCO ports
#   5. these properties                                                        <- here
#
# Setting them earlier would have left HFP with neither the legacy
# setParameters("hfp_enable") route nor the new session route.
#
# bluetooth.sco.managed_by_audio
#   BluetoothProperties.sysprop calls it "Set by vendors overlay, read at
#   Bluetooth initialization". AudioDeviceBroker.java:225-226 ANDs it with the
#   android.media.audio sco_managed_by_audio aconfig flag; both that flag and
#   amsco_available_api are ENABLED in trunk_staging (checked with `aconfig
#   dump-cache` on all_aconfig_declarations.pb), so this property is the only
#   remaining switch. It is what makes AudioService own SCO activation and
#   routing instead of emitting setParameters("hfp_enable=...").
#
# bluetooth.hfp.software_datapath.enabled
#   Read natively with osi_property_get_bool by both the AG
#   (bta_ag_init_hfp_client_interface() in bta_ag_sco.cc) and, with the HF
#   role's software data path, by bta_hf_client_sco.cc as well. Selects
#   software over offload.
#
# WHY PRODUCT_VENDOR_PROPERTIES. The sysprop file names the vendor overlay as
# the setter, and read-only properties are readable from every process
# regardless of partition, so both the BT apex (native) and system_server
# (Java) see them. This is NOT the vendor.ser.bt-uart situation: neither key is
# assigned anywhere else in the tree (checked across device/,
# packages/services/Car/ and build/), so there is no duplicate-mandatory
# collision to work around -- post_process_props.py:127-130 only errors on a
# repeated mandatory assignment of the SAME key.
#
# EFFECT ON THE AG ROLE, which is off on this product. NOT because a parent mk
# disables it -- this product does NOT inherit
# device/google_car/common/post_google_car.mk. bluetooth.profile.hfp.ag.enabled is
# simply UNSET (verified in the built system/product/vendor build.prop), and
# HeadsetService.java:290 reads it as
# BluetoothProperties.isProfileHfpAgEnabled().orElse(false), so it defaults to
# false. AG reads the same software_datapath property, but
# bta_ag_init_hfp_client_interface() is gated on bta_ag_is_sco_managed_by_audio(), a
# value pushed down from Java by HeadsetService, which does not run here. So there is
# no contention for the HfpClientInterface singleton; the HF client code logs and
# bails if it ever loses that race.
PRODUCT_VENDOR_PROPERTIES += \
    bluetooth.sco.managed_by_audio=true \
    bluetooth.hfp.software_datapath.enabled=true

# Bluetooth off on a fresh userdata. A runtime overlay, not the one above: Car's own RRO
# sets def_bluetooth_on=true and outranks any build-time overlay. The ordering that makes
# this one win is in its Android.bp (device/agl/doma-common/DomaSettingsProviderRRO).
PRODUCT_PACKAGES += DomaSettingsProviderRRO

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
