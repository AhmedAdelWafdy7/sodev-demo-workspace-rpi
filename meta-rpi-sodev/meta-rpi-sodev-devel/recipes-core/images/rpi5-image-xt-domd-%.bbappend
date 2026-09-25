# SPDX-License-Identifier: Apache-2.0
# Opt-in debug/diagnostic additions for the DomD rootfs.
#
# The wildcard matters. bbappends attach by RECIPE FILE NAME, not by `require`
# graph: the shipping image (rpi5-image-xt-domd-v4h) `require`s vc4.bb, but
# `require` is textual inclusion into the v4h parse, and a vc4-named bbappend
# never joins that parse. Measured, not assumed: with the vc4 name,
# `bitbake -e rpi5-image-xt-domd-v4h` showed a bare DEBUG_PACKAGES while the vc4
# image had the additions, so nothing a vc4-named bbappend adds reaches the SD
# image. The `%` matches vc4, v4h and any future variant; each recipe's own parse
# applies it exactly once. (rpi5-image-xt-domd itself is a leaf recipe the
# shipping chain never goes through.)
#
# The layer as a whole is opt-in: the yamls add it to the DomD layer list only for
# ENABLE_DEVEL=yes (build.sh --devel), so that parameter is what turns these on.
# Note that moulin adds layers with `bitbake-layers add-layer`, which only ever
# ADDS -- re-running with --ENABLE_DEVEL no does not remove it from an existing
# build dir. See this layer's README.
# :append, not '='. The base recipe defines DEBUG_PACKAGES itself
# (rpi5-image-xt-domd-vc4.bb: "openssh htop strace tcpdump") and installs it from
# its own IMAGE_INSTALL:append, so a hard assignment here silently REMOVED htop and
# strace from the DomD rootfs whenever this layer was enabled -- the opposite of
# what a diagnostics layer should do -- while duplicating openssh and tcpdump.
# Those two are dropped from the list below for the same reason: the base already
# has them.
DEBUG_PACKAGES:append = " \
    openssh-sftp-server \
    iproute2 \
    iputils \
    ethtool \
    xt-cluster-shm \
    xt-vram-tools \
    xt-venus-check \
"

# The three Venus reproducers are gated where the gate script is not: they link
# against the Vulkan loader, EGL and GLES, and need a Vulkan ICD, which the
# shipping image installs under the same 'venus' feature. In DomD that ICD is
# V3DV itself, not Venus -- DomD has no virtio-gpu -- so here they cannot
# reproduce the guest-side defects they were written for; a guest can, and
# rpi5-image-domu-gfx carries them too.
# (They parse in every lane: 'vulkan' and 'opengl' are in poky's
# DISTRO_FEATURES_DEFAULTS, so the gate is about the ICD, not about parsing.)
DEBUG_PACKAGES:append = "${@bb.utils.contains('DISTRO_FEATURES', 'venus', ' xt-venus-diag', '', d)}"

# xt-venus-check is listed above with the other diagnostics: it is a gate script,
# not part of the Venus runtime. The runtime itself (mesa-vulkan-drivers /
# vulkan-loader / vulkan-tools) is installed by the shipping image recipe under the
# 'venus' DISTRO_FEATURE, so this layer does not need to duplicate it -- and on a
# `--devel --gpu=gl` build the script installs anyway and reports why it cannot
# decide.
# The base recipe already installs ${DEBUG_PACKAGES}; appending it again here would
# just list every package twice.
