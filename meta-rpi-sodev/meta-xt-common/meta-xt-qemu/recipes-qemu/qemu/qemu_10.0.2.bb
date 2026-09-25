# The Venus-capable qemu for this board, and the device model a plain build gets:
# GPU=vulkan is the default lane and appends PREFERRED_VERSION_qemu = "10.0.2" to
# the domd conf. The yaml's base value for that variable is still 7.0.0, which is
# what `--gpu=gl` leaves standing. virtio-gpu-gl grew the `venus=` property in
# QEMU 9.2.0, so the vendored 7.0.0 fork cannot carry Venus at all -- see
# docs/VULKAN-VENUS.md.
#
# Source: the SAME xen-troops fork as qemu_7.0.0.bb, on its v10.0.2-xt branch.
# The fork maintains post-9.2 branches (v10.0.2-xt and v11.0.2-xt), so the Xen ARM
# device-model work does not have to be given up to get Venus.
#
# Venus support confirmed present at this SRCREV, in the fork's own sources:
#   hw/display/virtio-gpu-gl.c   DEFINE_PROP_BIT("venus", ... VIRTIO_GPU_FLAG_VENUS_ENABLED)
#   hw/display/virtio-gpu.c      rejects venus unless BOTH blob and hostmem are set,
#                                and unless VIRGL_VERSION_MAJOR >= 1 (oe-core ships
#                                virglrenderer 1.2.0, so that holds)
# -- which is why the device-model option string is hostmem= + blob=true + venus=true
# and not venus=true alone.
#
# Recipe body: oe-core's qemu 10.2.0 recipe, reached through BBPATH, rather than a
# second ~250-line vendored copy of qemu.inc. What it changes is the fetch, the
# license checksums (the two tags' license files differ) and a handful of
# packaging options -- do_configure:prepend, --disable-guest-agent,
# SYSTEMD_SERVICE and pulseaudio -- all of them below.
# This is the same cross-layer `require` used elsewhere in this
# tree (rpi5-image-xt-domd-vc4.bb requires recipes-core/images/rpi5-image-minimal-domd.bb).
#
# Three things to know before debugging a failure here:
#
#   1. RECIPE/SOURCE SKEW. The recipe body is 10.2.0's, the sources are 10.0.2's.
#      Two consequences, both checked against the real qemu trees rather than
#      assumed:
#        - configure options: the ONLY options that differ between the two tags are
#          igvm/mshv/passt/valgrind/gdb (added in 10.2.0) and avx2/avx512bw (removed
#          in 10.2.0), and the recipe body passes none of them. Every flag it does
#          pass -- the ten directory options, --with-suffix, --disable-strip,
#          --disable-werror, --disable-download, --disable-docs, --disable-af-xdp,
#          --host-cc, --extra-c/ldflags, --target-list, and the PACKAGECONFIG
#          --enable/--disable set -- is accepted by v10.0.2's configure +
#          scripts/meson-buildoptions.sh. So the skew does NOT break configure.
#          (If a future SRCREV moves further, v11.0.2-xt is the other fork branch:
#          11.0.2 > 10.2.0 makes the body older than the sources, which qemu's
#          configure tolerates.)
#        - the license files DO differ, which is why LIC_FILES_CHKSUM is overridden
#          below rather than inherited.
#
#   2. qemu.inc NAME COLLISION. oe-core's qemu_10.2.0.bb does `require qemu.inc`,
#      and this layer ships a qemu.inc of its own (the 7.0.0 one) with that exact
#      name. bitbake resolves a relative require against the requiring file's own
#      directory first, so oe-core's copy is the one that must win. If a failure
#      shows 7.0.0-era configure flags (--with-git=/bin/false, --with-suffix,
#      --disable-strip) being handed to qemu 10's meson, this is why.
#
#   3. THE SIX 7.0.0-ONLY PATCHES. The device-model patches in
#      meta-xt-driver-domain's qemu_%.bbappend are all written against 7.0.0
#      sources and are version-gated off for this recipe. What this recipe carries
#      instead: 0118 is 0111 rebased (virtio-tablet BTN_TOUCH, DomA touch) and 0120
#      is 0110 rebased (virtio-pci ISR IOREQ range). Of the rest, 0112 is moot (no
#      hw/arm/xen_arm.c and no GUEST_TPM_BASE anywhere in 10.0.2), 0113 is fixed in
#      10.0.2 itself, and 0101/0103 guard a pre-main-loop death that does not
#      reproduce here. That bbappend states the evidence per patch.
require recipes-devtools/qemu/qemu_10.2.0.bb

# '=' not ':append': oe-core's SRC_URI is the release tarball, the patches written
# against that tarball, and three data files that live in oe-core's own qemu/
# directory (powerpc_rom.bin, qemu-guest-agent.init, qemu-guest-agent.udev) which
# FILESPATH -- rooted at THIS recipe's directory -- cannot see. None of it applies
# to a git fetch of the fork. run-ptest is kept because `inherit ptest` expects it
# and this layer's own qemu/ directory provides it (the same copy qemu_7.0.0.bb
# fetches). cross.patch is NOT carried over: it is a 5.2-era configure patch that
# oe-core itself dropped, and it does not apply to qemu 10.
# gitsm, not git: qemu carries submodules, as in qemu_7.0.0.bb's fetch.
SRC_URI = "gitsm://github.com/xen-troops/qemu.git;branch=v10.0.2-xt;protocol=https;name=qemu \
           file://run-ptest \
           ${QEMU_MESON_SUBPROJECTS} \
           "

# MESON SUBPROJECTS -- the one thing a git fetch of qemu >= 9 needs that a release
# tarball does not. Measured, not guessed: with only the gitsm fetch, do_configure
# stops at qemu's own gate
#
#     ERROR: missing subprojects
#     --disable-download specified but subprojects were not checked out.
#
# because oe-core's recipe body passes --disable-download (correctly -- Yocto does
# not fetch during do_configure) and qemu's release tarballs ship
# subprojects/<name>/ already downloaded and patched, while the git tree carries
# only subprojects/<name>.wrap. The gitsm fetch is not the answer: qemu's
# .gitmodules covers roms/* and tests/lcitool only (all of which DID come down
# correctly), never the wrap subprojects.
#
# Three are needed for this configuration, all of them `required: true`:
#   keycodemapdb          ui/meson.build:171 -- generates the keymaps
#   berkeley-softfloat-3  tests/fp/meson.build:38
#   berkeley-testfloat-3  tests/fp/meson.build:42
# The berkeley pair cannot be skipped by disabling tests: tests/meson.build enters
# subdir('fp') whenever CONFIG_TCG is in config_all_accel, and 10.0.2 has no
# meson option to turn tests off.
#
# Revisions are the ones the wrap files pin at this SRCREV, so the result is
# byte-identical to what `meson subprojects download` would produce -- with the
# fetch staying in do_fetch where it belongs.
QEMU_MESON_SUBPROJECTS = " \
    git://gitlab.com/qemu-project/keycodemapdb.git;protocol=https;nobranch=1;name=keycodemapdb;destsuffix=${BP}/subprojects/keycodemapdb \
    git://gitlab.com/qemu-project/berkeley-softfloat-3.git;protocol=https;nobranch=1;name=softfloat;destsuffix=${BP}/subprojects/berkeley-softfloat-3 \
    git://gitlab.com/qemu-project/berkeley-testfloat-3.git;protocol=https;nobranch=1;name=testfloat;destsuffix=${BP}/subprojects/berkeley-testfloat-3 \
"

SRCREV_qemu = "f460a03528d82c819ac449b56783c086d619d604"
# = subprojects/keycodemapdb.wrap @ SRCREV_qemu
SRCREV_keycodemapdb = "f5772a62ec52591ff6870b7e8ef32482371f22c6"
# = subprojects/berkeley-softfloat-3.wrap @ SRCREV_qemu
SRCREV_softfloat = "b64af41c3276f97f0e181920400ee056b9c88037"
# = subprojects/berkeley-testfloat-3.wrap @ SRCREV_qemu
SRCREV_testfloat = "e7af9751d9f9fd3b47911f51a5cfd08af256a9ab"
SRCREV_FORMAT = "qemu_keycodemapdb_softfloat_testfloat"

# The one oe-core patch this recipe DOES need, rebased onto 10.0.2. qemu >= 9's
# configure builds a Python venv with mkvenv.py and then uses the meson inside it,
# ignoring PATH; in a Yocto build the venv creation dies ("found no usable distlib,
# please install it") and the meson that must be used is meson-native from the
# recipe sysroot. oe-core carries this as two patches for its own recipe (0010 +
# 0011); 0011 applies to 10.0.2 unchanged but 0010 does not (10.2.0 factored the
# pwd call into a get_pwd() helper), so the two are folded and rebased here.
#
# This is the only one of oe-core's thirteen patches that is needed: the rest are
# musl fixes, x86/PPC target fixes, reproducibility tweaks or CVE backports for
# code this build does not produce -- and they are written against the 10.2.0
# tarball, so most do not apply to these sources anyway.
SRC_URI:append:class-target = " file://0114-configure-use-the-host-python-and-meson-not-a-venv.patch"

# The ARM Xen machine was renamed between 7.0.0 and this version -- "xenpv" in
# hw/arm/xen_arm.c became "xenpvh" in hw/arm/xen-pvh.c -- while libxl still spawns
# the qemu backend with `-machine xenpv`. Without this the DomU/DomA device model
# never starts: `xl create` fails with "Qdisk backend didn't respond in time" and
# /var/log/xen/qdisk-N.log holds `unsupported machine type: "xenpv"`. Only a
# libxl-created domain shows it: qemu run directly with -M virt never goes
# through libxl.
SRC_URI:append:class-target = " file://0115-hw-arm-accept-xenpv-as-an-alias-for-the-xenpvh-machi.patch"

# On Arm, arch_xen_set_memory() is an empty stub, so a RAM-backed region this
# device model places in the guest's address space is only registered with the
# IOREQ server -- every guest access to it traps here for emulation. For a
# virtio-gpu host-visible blob (Venus) that is fatal, not just slow: a SIMD/FP
# data abort carries no syndrome, Xen has to decode the instruction itself, and
# its decoder handles only general-purpose load/store forms -- so Mesa's first
# memcpy() to the venus ring kills the guest's Vulkan client. 0116 implements the
# hook, putting those pages into the guest's p2m instead (no trap at all).
#
# It needs the matching hypervisor patch (4.22-0007 in xen-common/files) to be
# permitted. Without it the batch fails -- -ESRCH on 4.22, whose
# rcu_lock_remote_domain_by_id() cannot resolve the DOMID_SELF the device model
# passes, and -EPERM on 4.21, whose xsm_map_gmfn_foreign() refuses the direction
# -- and 0116 then WITHDRAWS the window instead of leaving it trapping, so the
# guest's client gets VK_ERROR_MEMORY_MAP_FAILED rather than being killed by an
# undecodable abort. Both halves and the measurements are in
# docs/VULKAN-VENUS.md section 7a.
SRC_URI:append:class-target = " file://0116-hw-arm-share-device-model-RAM-into-the-guest-s-physma.patch"

# 0117: with -display sdl, qemu_egl_display is never set -- only egl-headless, dbus,
# spice and gtk set it. virtio_gpu_virgl_init() installs the v4 get_egl_display callback
# only when qemu_egl_display is non-NULL, so with SDL virglrenderer never reaches
# vrend_winsys_init_external() and vrend's `egl` stays NULL. vrend then imports dma-bufs
# through GL_EXT_memory_object[_fd], which V3D's GL driver does not implement, so the host
# compositor cannot import a guest Vulkan (venus) buffer: PIPE_RESOURCE_SET_TYPE returns
# EINVAL, the compositor's virgl context dies, and every Vulkan client in the guest needs
# MESA_VK_WSI_DEBUG=sw -- a CPU copy per frame, measured at 33 -> 24 fps on the AGL
# instrument cluster plus 0.18 -> 0.57 cores in DomD.
#
# The patch adopts the display SDL already created, the way ui/gtk.c does for GtkGLArea.
# Creating a second EGLDisplay instead does NOT work and was tried: vrend also makes EGL
# fences on it, and eglCreateSyncKHR against a display that does not own the current
# context fails with "Failed to create fence sync object".
SRC_URI:append:class-target = " file://0117-ui-sdl2-adopt-SDL-s-EGLDisplay-so-virglrenderer-can-.patch"

# 0118: DomA touch. Android classifies an ABS_X/ABS_Y device as a touchscreen
# only when it also reports BTN_TOUCH, and virtio-tablet-pci sends BTN_LEFT --
# so the guest gets nothing from a mouse click or a real touch panel. The
# 7.0.0-xt device model gets the fix from meta-xt-driver-domain's 0111, which
# this lane version-gates OFF, and that made guest Vulkan and DomA touch
# mutually exclusive. This is the same fix for 10.0.2, and it is much smaller
# here: upstream already has 'touch' in the InputButton enum and
# [INPUT_BUTTON_TOUCH] = BTN_TOUCH in keymap_button, and because the tablet
# synthesises its EV_KEY bitmap from that whole array
# (virtio_input_extend_config in virtio_tablet_init --
# virtio_tablet_config_v1/v2 declare no EV_KEY at all), the device ALREADY
# advertises BTN_TOUCH. Only the send side was missing.
#
# Applies to both guests, because both use virtio-tablet-pci. That is the same
# situation the 7.0.0 lane ships 0111 in, DomU's AGL compositor included: libinput
# then reads the device as a touchscreen rather than an absolute pointer.
SRC_URI:append:class-target = " file://0118-virtio-input-hid-send-BTN_TOUCH-for-the-tablet-so-An.patch"

# 0119: guest Vulkan vs vhost. Adding the virtio-gpu host-visible blob (0116's
# window) to the guest's address space drives qemu's vhost MemoryListener, and
# vhost_commit() then re-verifies every vring against the rebuilt memory table.
# That check cannot pass under Xen: qemu never maps the whole guest, so the
# RAMBlock behind "xen.ram" has host == NULL and the userspace_addr recorded for
# it is a pseudo-hva equal to the gpa, while vq->desc is a locked map-cache
# pointer -- every ring reads as "relocated" and vhost_commit() abort()s the
# device model. Measured on RPi4 2026-09-07: `adb shell cmd gpu vkjson` in DomA
# killed the dm 3/3 times with "descriptor table relocated for ring 0" /
# "Verify ring failure on region 0", core dump backtrace confirming
# virgl_cmd_resource_map_blob -> memory_region_transaction_commit -> vhost_commit.
#
# Safe because the backend never translates with those addresses: CONFIG_VHOST_XEN=y
# here and the GUEST kernel's vhost-Xen work -- 0004 of the xen_patchset series in
# meta-xt-doma/recipes-kernel/linux/files, not a qemu patch; the fork's qemu tree
# has no vhost-Xen code at all -- redirects core vhost's translate_desc() to
# vhost_xen_map_desc(), which maps by domid. The same module already logs
# "Skip pseudo memory region for Xen grant mappings" for these table entries.
#
# Not Venus-specific -- any post-start memory topology change does it, and it is
# only unreached otherwise because vhost_dev_start() commits before setting
# ->started. Nor is it avoidable from the config side: DomA has three vhost users
# (two vhost-net plus the VHAL's vhost-vsock), and vhost=off on the netdevs just
# moves the abort to the vsock device (region 0 -> region 2, measured).
SRC_URI:append:class-target = " file://0119-vhost-do-not-verify-vring-host-mappings-under-Xen.patch"

# 0120: the RPi4 DomA kernel panics in virtio_pci (vp_interrupt readb of the ISR
# page, vp_notify writew of the notify page) with ESR 0x96000000 -- ISS=0, which
# is Xen's synthesised data abort for an MMIO access no ioreq server covers,
# not a real translation fault (the guest's PTE is valid). Twelve panics across
# three PCI functions, vhost on or off, on GL after hours and on Venus after
# minutes: Venus multiplies the memory-topology commits, and with them the
# per-FlatRange map/unmap churn that leaves a 4 KiB hole in Xen's merged ioreq
# rangeset (map rejects a partial overlap with -EEXIST; qemu discards the rc).
#
# This is the same defect meta-xt-driver-domain's 0110 fixes for the 7.0.0
# device model on RPi5, and that patch is (correctly) PV-gated to 7.x, so it
# never reaches the 10.0.2 device model. 0120 is 0110 re-based onto
# include/hw/xen/xen_native.h (xen_common.h was renamed in qemu 8.2); the code
# is otherwise identical: check the DMOP rc, log it, and on -EEXIST unmap the
# exact span and map it again as one clean range.
SRC_URI:append:class-target = " file://0120-xen-do-not-silently-drop-IOREQ-MMIO-range-registrati.patch"

# 0121: Venus rings/reply shmem are memfd-backed blobs that 0116 shared into the
# guest by frame number with only mlock() holding the pages, and DomD's kernel
# migrates pages freely (compaction, khugepaged). A migrated shared frame leaves
# the guest writing the old page while the render server reads the new one: the
# host decodes an all-zero command chunk, declares the context fatal, and the
# guest ICD aborts in vn_relax -- SurfaceFlinger dies, zygote restarts, the boot
# animation replays. Measured on RPi4 2026-09-12; vm.compact_unevictable_allowed=0
# on DomD stopped it, which is what named the mechanism. 0121 wraps the memfd in a
# udmabuf (a real pin) and hands the dma-buf to the gntdev route 0116 already has.
# If the pin cannot be had (no /dev/udmabuf, an unsealable memfd) it vetoes the
# share rather than falling back to the unpinned route, so the guest gets
# VK_ERROR_MEMORY_MAP_FAILED instead of a ring that corrupts minutes later.
SRC_URI:append:class-target = " file://0121-virtio-gpu-xen-pin-shmem-blobs-through-udmabuf-before-.patch"

# The berkeley wraps carry `patch_directory = <name>`, which is meson's way of
# saying "the build files live in subprojects/packagefiles/<name>, not upstream".
# Nothing in those directories is a patch -- they are a meson.build plus a
# meson_options.txt -- so replicating what meson does on download is a copy.
# keycodemapdb has no patch_directory and needs nothing.
#
# Without this the two subprojects are present but have no meson.build, and
# do_configure fails inside meson instead of inside configure.
do_configure:prepend() {
    for sp in berkeley-softfloat-3 berkeley-testfloat-3; do
        cp -a ${S}/subprojects/packagefiles/$sp/. ${S}/subprojects/$sp/
    done
}

# qemu changed both license files between 10.0.2 and 10.2.0, so the inherited
# LIC_FILES_CHKSUM does not match these sources and do_configure would fail on it.
# Measured at this SRCREV (and identical to upstream's v10.0.2 tag, i.e. the fork
# did not touch them) -- and they happen to be the same values qemu_7.0.0.bb uses,
# because the change landed after 10.0.2:
#     COPYING                 441c28d2cf86e15a37fa47e15a72fbac  (10.2.0: a3b50d8b...)
#     COPYING.LIB endline=24  8c5efda6cf1e1b03dcfd0e6c0d271c7f  (10.2.0: 8a8178c0...)
LIC_FILES_CHKSUM = "file://COPYING;md5=441c28d2cf86e15a37fa47e15a72fbac \
                    file://COPYING.LIB;endline=24;md5=8c5efda6cf1e1b03dcfd0e6c0d271c7f \
                    "

# oe-core's do_install installs the guest-agent init/udev files when qemu-ga was
# built, from ${UNPACKDIR} -- i.e. from the two SRC_URI entries dropped above. The
# guest agent has no role in a device-model-only qemu (the 7.0.0 recipe does not
# build it either), so turn it off rather than vendor the two files.
EXTRA_OECONF:append = " --disable-guest-agent"
# ...and with qemu-ga not built, its systemd unit is not installed either, while
# oe-core's recipe declares it unconditionally. systemd.bbclass turns that into a
# hard do_package error:
#     Didn't find service unit 'qemu-guest-agent.service', specified in
#     SYSTEMD_SERVICE:qemu-guest-agent
# so withdraw the declaration along with the feature. The ${PN}-guest-agent
# package then has no files and OE drops it. (update-rc.d needs no equivalent: it
# has no build-time existence check, and the init script it would register lives
# in the same dropped package.)
SYSTEMD_SERVICE:${PN}-guest-agent = ""

# Same reasoning as the pulsedio drop in this layer's qemu.inc: nothing in these
# images runs pulseaudio (no guest config uses a pulseaudio -audiodev), and
# 'pulseaudio' is in wrynose's DISTRO_FEATURES_DEFAULTS, so the 10.2.0 recipe's
# `bb.utils.filter('DISTRO_FEATURES', 'alsa pulseaudio xen', d)` would otherwise
# add a pulseaudio DEPENDS to the DomD build.
PACKAGECONFIG:remove = "pulseaudio"
