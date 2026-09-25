# DIAGNOSTIC hypervisor patch, kept out of the product layers.
#
# 4.22-0009-arm-ioreq-make-the-injected-abort-paths-loud.patch turns the prints on
# Xen's guest-abort injection paths from gdprintk (compiled out on a debug=n build)
# into gprintk, and adds one at "no ioreq server claims this gpa" and one at
# "server disabled". With it, a guest that dies on ESR 0x96000000 (ISS=0) names the
# path it took in `xl dmesg` -- which is how the RPi4 DomA MMIO abort was traced
# while the device model provably had the ioreq range registered.
#
# WHY IT LIVES HERE. A shipping hypervisor is a release build and must stay one, so
# this patch is in this opt-in layer rather than in a product layer: no default
# build references meta-rpi-sodev-devel (see this layer's
# README and build.sh --devel), so the patch is applied only when someone asks for
# the diagnostics on purpose.
#
# Deliberately NOT gated on the venus DISTRO_FEATURE: an injected abort is not a
# Venus-specific failure, and this layer being opt-in is already the switch.
#
# Note for whoever reads the file names: this is NOT the same patch as
# meta-xt-common/meta-xt-dom0-linux/recipes-extended/xen-tools/files/
# 4.22-0009-libxl-arm-give-a-virtio-pci-host-a-256M-prefetchable-.patch,
# which is a product patch on the toolstack. The numbers collide because the two
# series are numbered independently.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://4.22-0009-arm-ioreq-make-the-injected-abort-paths-loud.patch"
