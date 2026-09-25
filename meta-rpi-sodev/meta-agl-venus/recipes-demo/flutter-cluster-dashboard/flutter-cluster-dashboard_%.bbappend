# Switch the AGL cluster onto the Vulkan embedder, as a SEPARATE PACKAGE.
#
# flutter-auto-vulkan (this layer's second embedder recipe) only puts a binary in the
# rootfs; nothing runs it, because meta-agl-demo's flutter-cluster-dashboard.service
# hard-codes ExecStart=/usr/bin/flutter-auto. The systemd drop-in installed here
# replaces that ExecStart with the Vulkan binary plus --enable-impeller.
#
# Why a package of its own rather than an edit of the service file: build.sh's
# --gpu=vulkan (the default) adds flutter-cluster-dashboard-conf-vulkan to
# IMAGE_INSTALL and --gpu=gl does not, so the drop-in reaches that image and no
# other image this AGL build produces. (The base package's task hashes still
# differ between the lanes: --gpu=gl takes this layer, and with it this append,
# out of the build.) Same shape as the recipe's own -conf-kvm package, which
# installs kvm.conf into the same .service.d directory.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://vulkan.conf"

do_install:append() {
    install -D -m 0644 ${WORKDIR}/vulkan.conf \
        ${D}${systemd_system_unitdir}/${BPN}.service.d/vulkan.conf
}

PACKAGE_BEFORE_PN += "${PN}-conf-vulkan"
FILES:${PN}-conf-vulkan += "${systemd_system_unitdir}/flutter-cluster-dashboard.service.d/vulkan.conf"
# flutter-auto-vulkan is what the drop-in's ExecStart points at, so the package that
# carries the drop-in is what must pull the binary in.
RDEPENDS:${PN}-conf-vulkan = "${PN} flutter-auto-vulkan"
