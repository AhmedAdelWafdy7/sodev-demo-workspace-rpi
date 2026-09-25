SUMMARY = "Xen runtime cfg for the DomA (AAOS) guest (xl create)"
DESCRIPTION = "\
    /etc/xen/doma.cfg + doma.dtb + xl-create-doma.service, plus the \
    DomA-augmented /etc/xen/domd.cfg (adds xvdc=p4 = the AAOS super.img to the \
    DomD config). DomA is created before DomU so the DomD vhost_xen module \
    latches the correct guest domid. Boot order is encoded in the unit files. \
    "

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://doma.cfg \
    file://domd.cfg \
    file://doma.dts \
    file://xl-create-doma.service \
    file://doma-devmodel-sweep.sh \
    "

S = "${UNPACKDIR}"

inherit systemd

DEPENDS = "dtc-native"

SYSTEMD_SERVICE:${PN} = "xl-create-doma.service"
SYSTEMD_AUTO_ENABLE = "enable"

# The unit's ExecStart/ExecStartPre chain needs `xl` and the xenstore CLI; the sweep
# script additionally uses awk and grep, which busybox provides.
RDEPENDS:${PN} = "xen-tools-xl xen-tools-xenstore"

# Which Raspberry Pi 5 SKU this image is for. Set from the moulin BOARD_RAM
# parameter through the domd builder's conf: meta-xt-doma is in that builder's
# layers, and doma.cfg ships in the DomD image because DomD runs the toolstack.
# The default matches moulin's own default so a standalone bitbake still works.
BOARD_RAM ??= "16g"

# Board layers whose SKUs are not the Pi 5's 16g/8g set this to DomA's size in MiB
# and the BOARD_RAM map in do_install is not consulted. Empty means "use the map".
DOMA_MEM_MiB ??= ""

# [Venus] virtio-gpu-gl device-model options, from the moulin GPU parameter (see
# do_install). Defaulted for the same reason BOARD_RAM is defaulted a few lines above:
# a standalone bitbake outside moulin must still install a working config. The default
# is the pre-Venus content even though the product default is GPU=vulkan, because a
# standalone build cannot know which device model is installed and `venus=true` on a
# qemu without the property is a config qemu REJECTS outright; the empty string works
# on either. moulin always sets the value explicitly.
XT_VENUS_GPU_OPTS ??= ""
# [Venus] Device-model environment for the Venus lane's memory behaviour on a
# shared-memory guest. Both go into doma.cfg qemu_envs next to VIRGL_EXTERNAL_GBM,
# under the same gate (see the substitution in do_install). Measured on the RPi4
# 4g SKU with AAOS HWUI on Vulkan, 2026-09-12/13:
#  - V3DV_MAX_BO_CACHE_SIZE (MiB, Mesa v3dv, default 64): freed GEM BOs each render
#    server keeps for reuse. Nine Venus render servers retained ~0.5 GiB of DomD
#    memory that way; 8 is enough for reuse.
#  - VKR_DEVICE_HEAP_MIB (virglrenderer 0021, inert when unset): the device-local
#    heap size vkr advertises to the guest, forced to this value. v3dv reports a
#    percentage of DomD's system RAM (645 MiB on a 1408 MiB DomD) and the guest's
#    Skia/VMA sizes its block pool as heap/8 for heaps of 1 GiB or less -- every
#    block a fully populated v3d BO in DomD -- so HWUI RenderThreads allocated
#    96 MiB blocks (and, with an earlier clamp-only variant at 512 MiB, still 64) by the
#    handful and DomD fell into a memory-reclaim livelock (device model stalled,
#    guest soft-locked). Above 1 GiB VMA switches to the 4 MiB block size Skia asks
#    for and large images become dedicated allocations of their real size; 1088
#    is the smallest round value above that threshold. With it the cold-start and
#    screen-transition stresses that stalled DomD pass with DomD MemAvailable never
#    below ~460 MiB and no guest allocation of 64 MiB or more.
XT_VENUS_V3DV_BO_CACHE_MIB ??= "8"
XT_VENUS_VKR_DEVICE_HEAP_MIB ??= "1088"
# [qemu 10] The qemu version the guests' device model is built from. It comes from
# PREFERRED_VERSION_qemu, which the moulin conf sets per lane: 10.0.2 in the
# default GPU=vulkan lane (meta-xt-qemu/qemu_10.0.2.bb, docs/VULKAN-VENUS.md),
# 7.0.0 for --gpu=gl -- which is the yaml's base value, left standing.
#
# The '7.0.0' fallback below is deliberately the OLDER of the two, because the
# 7.0.0-only syntax is the conservative choice: every qemu in this tree parses
# the config it produces, whereas the 10.x form makes a 7.0.0 device model exit
# on an unknown property. It is not a safe default in general, though: a build
# that leaves PREFERRED_VERSION_qemu unset gets oe-core's qemu
# (10.2.0 at the time of writing) while this fallback still emits the 7.0.0-only
# syntax, and that device model exits on it. Such a build must set
# XT_DM_QEMU_VERSION itself. Inside moulin the variable is always set, so the
# fallback only ever applies to a bare `bitbake` in this tree's own conf.
XT_DM_QEMU_VERSION ??= "${@d.getVar('PREFERRED_VERSION_qemu') or '7.0.0'}"


do_compile() {
    dtc -I dts -O dtb -o ${WORKDIR}/doma.dtb ${UNPACKDIR}/doma.dts
}

do_install() {
    install -d ${D}${sysconfdir}/xen
    install -m 0644 ${UNPACKDIR}/doma.cfg ${D}${sysconfdir}/xen/doma.cfg
    install -m 0644 ${UNPACKDIR}/domd.cfg ${D}${sysconfdir}/xen/domd.cfg

    # DomA's size is board-dependent. On the 8 GB SKU the four domains have to fit
    # 7680 MiB, and DomD cannot absorb the whole reduction alone: DomD 2048 was
    # measured to leave the DomA device model unable to serve a 4 GiB guest (AAOS
    # crash-looped in binder while DomD itself still had 1.3 GiB free and was never
    # OOM-killed). 3072/3072 keeps the same total and boots all four domains. The
    # measurement and its history are in doma.cfg next to this value.
    # A board whose SKUs are not 16g/8g sets DOMA_MEM_MiB and bypasses the map
    # entirely. meta-xt-rpi4 does: the Raspberry Pi 4 SKUs are 8g and 4g, and its
    # 8 GiB budget puts DomA at a different size than the Pi 5's, so neither the
    # sizes nor the SKU names carry over. The map below stays literal because
    # tools/check-memory-map.py cross-checks these numbers against its own budget
    # table for the Pi 5.
    if [ -n "${DOMA_MEM_MiB}" ]; then
        doma_mem="${DOMA_MEM_MiB}"
    else
        case "${BOARD_RAM}" in
            16g) doma_mem=4096 ;;
            8g)  doma_mem=3072 ;;
            *)   bbfatal "BOARD_RAM must be 8g or 16g (got '${BOARD_RAM}'), or the board layer must set DOMA_MEM_MiB" ;;
        esac
    fi
    # Fail loudly rather than ship the placeholder: `xl create` rejects a
    # non-numeric `memory`, so DomA would simply never start -- and the same
    # applies if a future edit renames the token.
    if ! grep -q '^memory = DOMA_MEM_PLACEHOLDER$' ${D}${sysconfdir}/xen/doma.cfg; then
        bbfatal "DOMA_MEM_PLACEHOLDER not found in doma.cfg"
    fi
    # $doma_mem, not ${doma_mem}: inside a bitbake shell function ${...} is bitbake's
    # own expansion, and doma_mem is a shell local. It happens to survive today only
    # because bitbake leaves unknown names untouched -- a bitbake variable of that
    # name appearing later would silently substitute the wrong value.
    sed -i "s/^memory = DOMA_MEM_PLACEHOLDER\$/memory = $doma_mem/" \
        ${D}${sysconfdir}/xen/doma.cfg

    # [Venus] Substitute the virtio-gpu-gl device-model options. XT_VENUS_GPU_OPTS
    # comes from the moulin GPU parameter through the domd component conf:
    # ",hostmem=256M,blob=true,venus=true" for the default Vulkan lane, "" for --gpu=gl
    # (docs/VULKAN-VENUS.md). With --gpu=gl the token is replaced with nothing,
    # so that lane's installed file carries none of the Venus options.
    #
    # Fail loudly rather than ship the placeholder: qemu exits on an unknown
    # -device property, so the guest's device model would never start -- and the
    # same applies if a future edit renames the token.
    if ! grep -q 'virtio-gpu-gl-pci.*XT_VENUS_GPU_OPTS_PLACEHOLDER' ${D}${sysconfdir}/xen/doma.cfg; then
        bbfatal "XT_VENUS_GPU_OPTS_PLACEHOLDER not found in doma.cfg"
    fi
    # The value contains ',' and '=' but no '/', so '/' stays usable as the sed
    # delimiter. Deleting the comment block that documents the token as well: it
    # explains a build-time mechanism and has no meaning in the installed file.
    sed -i -e '/^    # XT_VENUS_GPU_OPTS_PLACEHOLDER is SUBSTITUTED AT BUILD TIME/,/^    # See docs\/VULKAN-VENUS.md.$/d' \
           -e "s/XT_VENUS_GPU_OPTS_PLACEHOLDER/${XT_VENUS_GPU_OPTS}/" \
        ${D}${sysconfdir}/xen/doma.cfg

    # [Venus] Substitute the qemu_envs entries: the one that switches on
    # virglrenderer's global gbm, and the two memory knobs next to it. Same lane as
    # XT_VENUS_GPU_OPTS -- keyed on it rather than on a second
    # variable so the two can never disagree: pinned blob memory without the export
    # path (or the reverse) is not a configuration anyone wants.
    #
    # This is a SEPARATE token from the device-model options because it lives in
    # qemu_envs, not in device_model_args, and because the non-Venus lane must DELETE
    # the line rather than empty it: `''` would be a valid but useless env entry, and
    # bare whitespace inside the list is not valid Python for xl's config parser.
    if ! grep -q '^    XT_VENUS_QEMU_ENV_PLACEHOLDER$' ${D}${sysconfdir}/xen/doma.cfg; then
        bbfatal "XT_VENUS_QEMU_ENV_PLACEHOLDER not found in doma.cfg"
    fi
    if [ -n "${XT_VENUS_GPU_OPTS}" ]; then
        venus_env="    'VIRGL_EXTERNAL_GBM=1', 'V3DV_MAX_BO_CACHE_SIZE=${XT_VENUS_V3DV_BO_CACHE_MIB}', 'VKR_DEVICE_HEAP_MIB=${XT_VENUS_VKR_DEVICE_HEAP_MIB}',"
    else
        venus_env=""
    fi
    # Delete the comment block documenting the token in both lanes -- it explains a
    # build-time mechanism and has no meaning in the installed file.
    sed -i -e '/^    # XT_VENUS_QEMU_ENV_PLACEHOLDER is SUBSTITUTED AT BUILD TIME/,/^    # See docs\/VULKAN-VENUS.md.$/d' \
        ${D}${sysconfdir}/xen/doma.cfg
    if [ -n "$venus_env" ]; then
        sed -i -e "s|^    XT_VENUS_QEMU_ENV_PLACEHOLDER$|$venus_env|" \
            ${D}${sysconfdir}/xen/doma.cfg
    else
        sed -i -e '/^    XT_VENUS_QEMU_ENV_PLACEHOLDER$/d' \
            ${D}${sysconfdir}/xen/doma.cfg
    fi

    # [qemu 10] Device-model argument fixups. Two of the options in doma.cfg are
    # 7.0.0-xt-only and qemu 10 EXITS on either one -- both measured on RPi5:
    #   virtio-snd-pci        -> "'virtio-snd-pci' is not a valid device model name"
    #                            (upstream calls it virtio-sound-pci, alias virtio-sound)
    #   virtio-blk-pci,scsi=  -> "Property 'virtio-blk-pci.scsi' not found"
    #                            (the property was removed upstream)
    # `-vga std` only warns there ("this machine type does not use that option";
    # the xenpvh machine creates no VGA device at all), and is dropped with them so
    # the emitted config has no dead options for that device model.
    #
    # Keyed on the device model's version, not on the GPU parameter: the incompatibility
    # belongs to qemu 10, so a later qemu bump outside the Venus lane is covered
    # too, and this step leaves the 7.0.0 (--gpu=gl) lane untouched (the case
    # does nothing there).
    case "${XT_DM_QEMU_VERSION}" in
    7.*)
        ;;
    *)
        sed -i -e "s/'virtio-snd-pci,/'virtio-sound-pci,/" \
               -e "s/'virtio-blk-pci,scsi=off,/'virtio-blk-pci,/" \
               -e "/^    '-vga', 'std',$/d" \
            ${D}${sysconfdir}/xen/doma.cfg
        # Fail loudly rather than ship a config the device model will reject.
        if grep -qE "virtio-snd-pci|virtio-blk-pci,scsi=|'-vga'" ${D}${sysconfdir}/xen/doma.cfg; then
            bbfatal "qemu ${XT_DM_QEMU_VERSION} device-model incompatibility left in doma.cfg"
        fi
        ;;
    esac

    install -d ${D}/usr/lib/xen/boot
    install -m 0644 ${WORKDIR}/doma.dtb ${D}/usr/lib/xen/boot/doma.dtb

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/xl-create-doma.service ${D}${systemd_system_unitdir}/xl-create-doma.service

    # ExecStartPre of xl-create-doma.service. A script rather than an inline Exec
    # line because the awk field reference needs a backslash-escaped `$`, which
    # systemd rejects with "Ignoring unknown escape sequences".
    install -d ${D}${libexecdir}
    install -m 0755 ${UNPACKDIR}/doma-devmodel-sweep.sh ${D}${libexecdir}/doma-devmodel-sweep
}

# doma.cfg now depends on BOARD_RAM, so switching SKUs must not reuse a doma.cfg
# from sstate that still carries the other board's `memory` value. The same reason
# BOARD_RAM is in xt-rpi-u-boot-scr's do_compile[vardeps].
do_install[vardeps] += "BOARD_RAM"
# Same reason, for the board-layer override that bypasses the BOARD_RAM map.
do_install[vardeps] += "DOMA_MEM_MiB"
# Same reason again, for the Venus device-model options substituted into doma.cfg.
do_install[vardeps] += "XT_VENUS_GPU_OPTS"
# Same reason for the two memory knobs substituted into the same qemu_envs line.
do_install[vardeps] += "XT_VENUS_VKR_DEVICE_HEAP_MIB XT_VENUS_V3DV_BO_CACHE_MIB"
# Same reason for the device-model version that selects the argument fixups.
do_install[vardeps] += "XT_DM_QEMU_VERSION"

FILES:${PN} = " \
    ${sysconfdir}/xen/doma.cfg \
    ${sysconfdir}/xen/domd.cfg \
    /usr/lib/xen/boot/doma.dtb \
    ${systemd_system_unitdir}/xl-create-doma.service \
    ${libexecdir}/doma-devmodel-sweep \
    "
