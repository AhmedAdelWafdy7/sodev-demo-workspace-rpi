# SPDX-License-Identifier: MIT
# Assisted-by: Claude Code:claude-opus-4-8
# DomA's guest memory on Raspberry Pi 4.
#
# xt-xen-cfg-doma lives in meta-xt-common because DomA's xl configuration is
# board-independent apart from its size, and this port keeps that layer's doma.cfg
# byte-identical. Only the number changes here.
#
# WHY 2560 MiB
# The 8 GiB Pi 4 has to fit four domains into what is left after the boot-time
# carve-outs, and the RPi4 map is not the Pi 5's:
#   Dom0 128 MiB (zephyr) or 256 MiB (linux) of dom0_mem. The linux 256 is NOT
#     one bank and NOT bank[0]'s size: it comes back as 128 MiB at 0x20000000
#     plus 128 MiB at 0x30000000. The Zephyr Dom0 is relinked to 0x20000000,
#     where bank[0] was measured -- see boot.cmd.xen.zephyr-dom0.in.
#   Xen itself 80 MiB, a separate item, measured with `xl info` across three
#     DomD sizes on the 4 GiB board (78/79/80 MiB of frametable + xenheap +
#     image); see boot.cmd.xen.linux-dom0.in.
#   DomD xen,static-mem  384 MiB + 1 GiB + 512 MiB = 1920 MiB, all below 4 GiB
#   gpu_mem=76 for the VideoCore carve-out at the top of the low bank
# 1920 + 256 + 1024 + 2560 + 80 = 5840 MiB of the 8052 MiB usable, which is the
# same arithmetic the BOARD_RAM note in rpi4-sodev.yaml does.
# DomU takes 1024 MiB from the remaining free pool and DomA 2560 MiB. Those two
# numbers are the ones the sending environment booted all four domains with on real
# hardware (2026-08-07); they have NOT been re-measured in this environment.
#
# The 4 GiB SKU cannot host DomA at all: its free pool is 2596 MiB (linux Dom0)
# or 2724 MiB (zephyr Dom0) -- DomD 1024 + Dom0 128..256 + Xen 80 = 1232..1360 of
# 3956 usable, per the BOARD_RAM note in rpi4-sodev.yaml -- which takes DomU
# 1024, and takes DomA 2560 on its own, but not both (3584).
# build.sh refuses `--ram=4g` only when DomU and DomA are asked for TOGETHER; a 4 GiB
# image with DomA alone is allowed, and that is the configuration the Venus lane's
# 2176 below is for.
#
# MECHANISM
# doma.cfg ships as `memory = DOMA_MEM_PLACEHOLDER` and xt-xen-cfg-doma's do_install
# substitutes it, choosing the value from a `case "${BOARD_RAM}"` map over the Pi 5's
# 16g/8g SKUs. Neither the SKU names nor the sizes carry over to this board, so rather
# than sed the substituted result afterwards, this sets the escape hatch that recipe
# provides: a non-empty DOMA_MEM_MiB is used verbatim and the map is not consulted.
# The recipe already has DOMA_MEM_MiB in do_install[vardeps], so switching boards
# cannot reuse a doma.cfg from sstate carrying the other board's value.
# 2176 rather than 2560 in the Venus lane on the 4 GiB SKU: 384 MiB moves to DomD
# for the device model's pinned blob memory. The total is unchanged, the direction
# is chosen because DomD running out kills both guests' device models while DomA at
# 2176 is still 6% above the 2048 MiB AAOS is sized at upstream, and 128 MiB is
# `hostmem`, the hard ceiling on what the device model can pin. DomD's side of the
# transfer is in meta-xt-rpi4's xt-rpi-u-boot-scr bbappend, gated the same way.
# The 8 GiB SKU is untouched: DomD has 1920 MiB there and the delta is noise.
#
# VENUS_LANE is the same one-line idiom meta-xt-rpi4's xt-rpi-u-boot-scr.bbappend
# uses for DomD's side of the same 384 MiB transfer -- deliberately, so the two
# halves cannot drift into two different readings of "is this the Venus lane".
# The vardeps line is belt-and-braces, not the mechanism: bitbake's codeparser
# already tracks `d.getVar('X')` as a reference to X (bitbake/lib/bb/codeparser.py
# `getvars`), and it records `bb.utils.contains('DISTRO_FEATURES', 'venus', ...)`
# as a *contains* dependency, which enters the signature as the single line
# `DISTRO_FEATURES{venus} = Set|Unset` (bitbake/lib/bb/data.py handle_contains) --
# so the feature test is hashed by its ANSWER, not by the whole feature string.
# What must NOT appear in vardeps is raw DISTRO_FEATURES: that hashes the entire
# string and rehashes this task on distro-feature changes that have nothing to do
# with Venus, defeating the contains() tracking.
VENUS_LANE = "${@bb.utils.contains('DISTRO_FEATURES', 'venus', 'yes', 'no', d)}"
DOMA_MEM_MiB:raspberrypi4-64 = "${@'2176' if (d.getVar('BOARD_RAM') == '4g' and d.getVar('VENUS_LANE') == 'yes') else '2560'}"
do_install[vardeps] += "BOARD_RAM VENUS_LANE"
