# SPDX-License-Identifier: Apache-2.0
SUMMARY = "Three minimal Venus reproducers for the two guest-side defects this series fixed"
DESCRIPTION = "vk-fence-test, vk-gl-import-test and vk-suballoc-probe: headless, single-purpose \
programs that reproduce the two guest-side failures Venus USED to have on this board \
(docs/VULKAN-VENUS.md section 7a). Both are fixed in-tree -- defect A by \
meta-agl-venus' mesa 0002, defect B by meta-xt-qemu's 0117 -- so these are kept as \
regression detectors: an exit of 2 now names which fix stopped working, instead of \
leaving a guess. vk-suballoc-probe is the one that located defect A. None \
needs a compositor, a window system or a swapchain, so the same binary runs in DomU \
on hardware and in a guest under plain qemu -- which is how both defects were shown \
to be board-specific rather than Mesa- or virglrenderer-version problems."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

SRC_URI = " \
    file://vk-fence-test.c \
    file://vk-gl-import-test.c \
    file://vk-suballoc-probe.c \
"

S = "${UNPACKDIR}"

# vk-fence-test needs only the loader. vk-gl-import-test additionally imports the
# exported dma-buf into a GL context, so it needs EGL and GLES -- which is the
# point of it: the import is the operation that fails.
DEPENDS = "vulkan-headers vulkan-loader virtual/egl virtual/libgles2"

# The ICD is the dependency that matters and the one Yocto cannot infer: shlib
# tracking picks up libvulkan / libEGL / libGLESv2 from the link line by itself,
# but libvulkan_virtio.so is a runtime data file it never sees. An image that
# installed these programs without mesa-vulkan-drivers would get
# "no physical device", which is indistinguishable from a real Venus init failure
# and costs a board session to work out -- so state it.
RDEPENDS:${PN} += "mesa-vulkan-drivers vulkan-loader"

# 'opengl' and 'vulkan' are both in poky's DISTRO_FEATURES_DEFAULTS and neither is
# removed by *-sodev.yaml, so this recipe parses in every lane; the image recipes
# gate the *install* on 'venus', which is a strict subset. Stated because the
# reverse reading -- that only the Venus lane has 'vulkan' -- is wrong and would
# make the gating look redundant.
REQUIRED_DISTRO_FEATURES = "opengl vulkan"
inherit features_check

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} -o vk-fence-test ${UNPACKDIR}/vk-fence-test.c -lvulkan
    ${CC} ${CFLAGS} ${LDFLAGS} -o vk-gl-import-test ${UNPACKDIR}/vk-gl-import-test.c \
        -lvulkan -lEGL -lGLESv2
    ${CC} ${CFLAGS} ${LDFLAGS} -o vk-suballoc-probe ${UNPACKDIR}/vk-suballoc-probe.c -lvulkan
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 vk-fence-test ${D}${bindir}/vk-fence-test
    install -m 0755 vk-gl-import-test ${D}${bindir}/vk-gl-import-test
    install -m 0755 vk-suballoc-probe ${D}${bindir}/vk-suballoc-probe
}

FILES:${PN} = " \
    ${bindir}/vk-fence-test \
    ${bindir}/vk-gl-import-test \
    ${bindir}/vk-suballoc-probe \
"
