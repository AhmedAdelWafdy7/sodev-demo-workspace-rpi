# SPDX-License-Identifier: MIT
#
# Raspberry Pi 5 additions to the DomD image. Board-specific software only; the
# base recipe is
# meta-xt-common/meta-xt-driver-domain/recipes-core/images/rpi5-image-xt-domd-v4h.bb.


# ---------------------------------------------------------------------------
# Wi-Fi in DomD.
#
# Why DomD owns the radio and not DomA: the guest's RRO declares the wired vif's
# capabilities without NET_CAPABILITY_NOT_RESTRICTED, so an ordinary app in DomA
# cannot use that interface however it is NATed. The supported way to give AAOS
# an unrestricted network is a wlan0 that WifiService manages, so DomD drives
# the real BCM43455 and NATs for DomA, whose own wlan0 comes from mac80211_hwsim
# behind a shadow AP that re-beacons the SSIDs the agent reports
# (persist.vendor.doma.shadow_ap, default true); a virt_wifi wlan0 on top of the
# vif is the fallback that property switches to. Identical to the Pi 4.
#
# This file supplies the SOFTWARE. The hardware side is in this layer: the boot
# script marks the SDIO controller (/axi/mmc@1100000) xen,passthrough, and
# bcm2712-raspberrypi5-domd-vc4.dts gives DomD the mmc node with its wifi@1
# child, wl_on_reg, the shared gio bank and the sdio2 pin group that TF-A muxes
# over SCMI. That is the zephyr Dom0 flavour: with DOM0_OS=linux the controller
# stays with Dom0, domd-vc4.bb strips those nodes out of DomD's partial DT, and
# the packages below are inert.
#
# No kernel rebuild. bcm2712_defconfig carries CFG80211=m, RFKILL=m, BRCMUTIL=m,
# BRCMFMAC=m and BRCMFMAC_SDIO=y with MMC=y, so every module already exists in
# deploy. They were never packaged because this image installs
# packagegroup-core-boot rather than packagegroup-base, so MACHINE_EXTRA_RRECOMMENDS
# never applies; every kernel-module-* below is named for that reason.
#
# The base recipe excludes the Cypress firmware for all machines, and
# PACKAGE_EXCLUDE is not advisory -- it turns an explicit IMAGE_INSTALL entry into
# a build error -- so the 43455 entry has to come out of both lists. 43456 and
# 43430 stay excluded: neither part is on this board and both are
# licence-restricted.
BAD_RECOMMENDATIONS:remove = "linux-firmware-rpidistro-bcm43455"
PACKAGE_EXCLUDE:remove = "linux-firmware-rpidistro-bcm43455"

# linux-firmware-rpidistro declares LICENSE_FLAGS = "synaptics-killswitch"
# (meta-raspberrypi's docs/ipcompliance.md explains the flag), and this layer
# does not accept it on the user's behalf: bitbake builds the recipe only when
# LICENSE_FLAGS_ACCEPTED names the flag, which build.sh
# --accept-synaptics-killswitch arranges. As meta-raspberrypi does by only
# recommending the package from the machine configuration, the image installs
# the firmware only then; otherwise it builds without Wi-Fi firmware, and DomD
# brings up no wlan0. The flag may be named alone or as
# synaptics-killswitch_<pn>, the two forms bitbake accepts.
DOMD_WIFI_FW = "${@'linux-firmware-rpidistro-bcm43455' \
    if bb.utils.filter('LICENSE_FLAGS_ACCEPTED', \
    'synaptics-killswitch synaptics-killswitch_linux-firmware-rpidistro', d) \
    else ''}"

# linux-firmware-rpidistro-bcm43455, not linux-firmware-bcm43455: the rpidistro
# recipe RCONFLICTS/RREPLACES the poky one and its do_install wildcard is what
# brings the NVRAM blob along with the .bin and .clm_blob. Measured on the built
# rpm, it ships brcmfmac43455-sdio.raspberrypi,5-model-b.{bin,clm_blob,txt} -- the
# same package serves both boards, each with its own suffix.
#
# The brcmfmac-{bca,cyw,wcc} split modules are all installed. 6.18 moved the
# per-vendor firmware-interface code out of brcmfmac.ko into these three, and
# which one the chip needs follows the SDIO device ID it reports: brcmfmac's
# bcmsdh.c maps the BCM4345 ID (0x4345) to cyw and the BCM43455 ID (0xa9bf) to
# wcc. All three are a few KiB, cheaper to ship than to be wrong about at
# runtime.
#
# wireless-regdb-static, not wireless-regdb, carries /lib/firmware/regulatory.db
# and .p7s, which is where cfg80211 loads regulatory data from. Without it the
# radio is clamped to the world-roaming channel set.
DOMD_WIFI_PACKAGES = ""
DOMD_WIFI_PACKAGES:raspberrypi5 = " \
    kernel-module-cfg80211 \
    kernel-module-rfkill \
    kernel-module-brcmutil \
    kernel-module-brcmfmac \
    kernel-module-brcmfmac-cyw \
    kernel-module-brcmfmac-bca \
    kernel-module-brcmfmac-wcc \
    kernel-module-xt-masquerade \
    kernel-module-xt-conntrack \
    ${DOMD_WIFI_FW} \
    wireless-regdb-static \
    wpa-supplicant \
    iw \
    "
IMAGE_INSTALL:append = " ${DOMD_WIFI_PACKAGES}"

# ---------------------------------------------------------------------------
# brcmfmac firmware: the GENERIC file names have to exist in a dom0less guest.
#
# linux-firmware-rpidistro-bcm43455 ships only board-suffixed symlinks,
# brcmfmac43455-sdio.raspberrypi,5-model-b.{bin,clm_blob,txt}, and
# brcmf_fw_alloc_request() builds that suffix from the DT ROOT node compatible. A
# dom0less guest has none -- /proc/device-tree/compatible in DomD is empty, the
# same property that makes of_have_populated_dt() false and costs this guest its
# regulator dummies -- so brcmfmac skips the board-specific name entirely and asks
# for the plain brcm/brcmfmac43455-sdio.bin, which the package does not contain.
#
# Measured before this fix, with the SDIO bus otherwise fully working (card
# enumerated, F1 signature read back 0x15264345 = BCM4345/6):
#   brcmfmac mmc1:0001:1: Direct firmware load for brcm/brcmfmac43455-sdio.bin
#                         failed with error -2
#   brcmfmac: brcmf_sdio_htclk: HT Avail timeout (1000000): clkctl 0x50
# and no wlan0. After it: "Firmware: BCM4345/6 wl0: ... version 7.45.265" and a
# wlan0 that scans 16 real APs.
#
# Point the generic names at the same targets the board-suffixed symlinks use.
# The .txt NVRAM already exists under the generic name, so only .bin and
# .clm_blob are created, with relative targets so they stay correct inside the
# image.
#
# DomD's wifi@1 node carries brcm,board-type as well, which brcmfmac reads
# before the root compatible, so with it the board-suffixed names resolve
# directly; that property alone is what the Pi 4 uses. Which of the two this
# board needs has not been told apart on the board: the firmware load was
# measured working here with both in place, so both stay.
brcmfmac_generic_fw_names() {
    d=${IMAGE_ROOTFS}/lib/firmware/brcm
    if [ ! -e $d/brcmfmac43455-sdio.raspberrypi,5-model-b.bin ]; then
        bbfatal "brcmfmac_generic_fw_names: board-suffixed 43455 firmware missing from the rootfs"
    fi
    ln -sfn ../cypress/cyfmac43455-sdio-standard.bin $d/brcmfmac43455-sdio.bin
    ln -sfn ../cypress/cyfmac43455-sdio.clm_blob     $d/brcmfmac43455-sdio.clm_blob
    for f in brcmfmac43455-sdio.bin brcmfmac43455-sdio.clm_blob brcmfmac43455-sdio.txt; do
        [ -e $d/$f ] || bbfatal "brcmfmac_generic_fw_names: $f still missing"
    done
}
# Only with the firmware installed; without it there is nothing to link.
ROOTFS_POSTPROCESS_COMMAND:append:raspberrypi5 = \
    "${@' brcmfmac_generic_fw_names;' if d.getVar('DOMD_WIFI_FW') else ''}"
