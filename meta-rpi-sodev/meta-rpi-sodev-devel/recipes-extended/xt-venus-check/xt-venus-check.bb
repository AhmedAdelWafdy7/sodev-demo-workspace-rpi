# SPDX-License-Identifier: Apache-2.0
SUMMARY = "Vulkan/Venus feasibility gate for the RPi4/RPi5 disaggregated cockpit"
DESCRIPTION = "sodev-venus-gate.sh: runs the phase 0-3 checks of \
docs/VULKAN-VENUS.md on DomD and prints one PASS/FAIL verdict -- whether the \
host V3DV meets the Venus (virtio-gpu Vulkan passthrough) requirements, and so \
whether the DomU(AGL-IC)/DomA(AAOS) Vulkan integration is worth starting."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

SRC_URI = " \
    file://sodev-venus-gate.sh \
"

S = "${UNPACKDIR}"

# The gate READS the Vulkan runtime rather than shipping it: mesa-vulkan-drivers
# (the V3DV ICD), vulkan-loader and vulkan-tools are installed into the DomD image
# by rpi5-image-xt-domd-vc4.bb, gated on the 'venus' DISTRO_FEATURE. They are
# deliberately NOT RDEPENDS here, so that a `--gpu=gl --devel` build can still
# install this package and have the script report INCONCLUSIVE with the reason,
# instead of dragging a Vulkan stack into an image that has no use for it.
#
# What is depended on is what the script cannot work without at all: bash (the
# script is #!/bin/bash and uses [[-free but bash-specific constructs) and
# coreutils (mktemp, timeout, and the fractional `sleep 0.5` busybox may not have).
#
# weston-examples, not weston: phase 3's preferred path runs
# weston-simple-dmabuf-vulkan as a CLIENT against the compositor that is already
# up, and that binary ships in weston-examples -- verified in pkgdata, where the
# weston package itself carries only weston-simple-im. Depending on `weston` would
# have named the wrong package for the one check that needs a specific binary. The
# compositor is not an RDEPENDS at all: if it is not running the script says so
# and reports INCONCLUSIVE, which is the correct answer on a host that is not DomD.
RDEPENDS:${PN} = " \
    bash \
    coreutils \
    weston-examples \
"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/sodev-venus-gate.sh ${D}${bindir}/sodev-venus-gate.sh
}

FILES:${PN} = " \
    ${bindir}/sodev-venus-gate.sh \
"
