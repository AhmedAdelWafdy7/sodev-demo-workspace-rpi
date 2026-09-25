#!/system/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# /vendor/bin/doma-wifi-relay -- the DomA half of the shadow-AP Wi-Fi relay.
#
# WHAT IT CLOSES
# doma-shadow-ap beacons whatever is in /data/vendor/wifi/shadow/aps.conf, and the
# DomD-side agent (domd_wifi_agent.py) already publishes the real scan results and
# already performs the real association on request. Nothing on this side consumed
# either half, so the AP list was static and the passphrase the user typed never
# reached DomD. This daemon is that consumer.
#
# WHY BOTH HALVES ARE ONE PROGRAM, NOT TWO
# The `aps` message the agent sends carries {ssid, bssid, sec, freq, dbm} and NO
# psk (see the PROTOCOL block of domd_wifi_agent.py) -- a scan cannot reveal a
# PSK. So "write aps.conf from the real scan" on its own would leave hostapd
# with no passphrase for the new SSIDs, and the first attempt against one would
# fail the 4-way handshake locally. That failure is NOT retried:
# config_wifiDisableReasonByWrongPasswordThreshold is 1 and
# config_wifiDisableReasonByWrongPasswordDurationMs is -1 in
# ServiceWifiResources/res/values/config.xml, so the network is disabled permanently
# (WifiConfiguration.NetworkSelectionStatus.DISABLED_BY_WRONG_PASSWORD). Publishing a
# list is therefore only safe together with a way to learn the PSK, which is what the
# companion app supplies over $REQ below.
#
# THE TWO INPUTS
#   $CHAN  /dev/hvc4         virtio-serial to DomD. Newline-delimited JSON both ways.
#                            The INBOUND format is json.dumps() output, so it has a
#                            space after every colon -- written out in full here because
#                            a pattern for the compact form never matches it:
#                            in : {"t": "aps", "v": [{"ssid": "X", "bssid": ..,
#                                  "sec": "wpa2", ..}, ..]}
#                                 {"t": "state", "ssid": "X", "state": "COMPLETED", "ip": ..}
#                            out: {"t":"connect","ssid":"X","psk":"Y"}   (ours, compact)
#   $REQ   .../relay.req     one line per request from DomaWifiRelay (the priv-app):
#                                 psk<TAB><SSID><TAB><PSK>
#                            The app has NETWORK_SETTINGS + READ_WIFI_CREDENTIAL and
#                            reads the PSK with WifiManager.getPrivilegedConfiguredNetworks().
#
# WHY A REQUEST FILE AND NOT A SOCKET
# mksh cannot select() over two descriptors. `read -t` on $CHAN plus a stat of $REQ
# polls both with one loop and no helper process. $REQ lives in $CONF_DIR/req,
# which file_contexts already labels hostapd_data_file, so no new sepolicy is
# needed (the owner and mode of that directory are explained where REQ_DIR is
# set).
#
# IT FOLLOWS THE SETTINGS WI-FI TOGGLE. init.xenvm-hwsim.rc starts it at
# sys.boot_completed while persist.vendor.doma.wifi_relay is unset or "true", and while
# the toggle is off it asks DomD for nothing -- see sta_is_up().
set -u

TAG=doma-wifi-relay
# THE TRAILING `:` IS MANDATORY. Without it, LOG()'S EXIT STATUS IS THAT OF
#   /system/bin/log, which turns the `A && log ... || die ...` idiom into "A
#   succeeded, yet die fired" (/system/bin/log is a toybox symlink and normally
#   succeeds, but if it fails you get a bogus FATAL).
log() { echo "$TAG: $*"; /system/bin/log -t "$TAG" "$*" 2>/dev/null; :; }

# THE PATHS CAN BE OVERRIDDEN FROM THE ENVIRONMENT, so the script also runs on a
#   PC against a scratch directory. Nothing sets them on the device.
CONF_DIR=${CONF_DIR:-/data/vendor/wifi/shadow}
APS=${APS:-$CONF_DIR/aps.conf}
CONF=${CONF:-$CONF_DIR/hostapd.conf}
# The request drop-box. A SUBDIRECTORY, not a file in $CONF_DIR, because of DAC:
# $CONF_DIR is wifi:wifi 0771 (init.xenvm-hwsim.rc creates it and doma-shadow-ap
# keeps the mode), and the app that writes requests runs as uid/gid system, so
# it could not create a file there. This
# directory is created wifi:system 0770 by init.xenvm-hwsim.rc (and chowned to match
# by this daemon as a fallback), which lets the app create and replace the request file while
# keeping the passphrase out of reach of everything else. SELinux needs nothing:
# file_contexts already labels /data/vendor/wifi/shadow(/.*)? hostapd_data_file, so
# the subdirectory inherits the same type.
REQ_DIR=${REQ_DIR:-$CONF_DIR/req}
REQ=${REQ:-$REQ_DIR/relay.req}
# $CHAN is the hvc node, not /dev/vport2p4. The Wi-Fi channel in doma.cfg is
#   declared as `-device virtconsole,chardev=virts_chardev5`, i.e. AS A CONSOLE
#   PORT. virtio_console only assigns an hvc to ports the host declared
#   VIRTIO_CONSOLE_CONSOLE_PORT, and the generic /dev/vportXpY node of a port
#   that got an hvc CANNOT BE OPENED (port_fops_open returns -ENXIO): init then
#   restarts this script every 10 s, and it dies before it can log anything.
#
#   Why this number (same as the corresponding comment in doma.cfg): hvc_alloc()
#   takes the lowest free vtermnos[] slot, and Xen's PV console has taken 0, so
#   the five virtconsoles land ON hvc1..hvc5 IN PORT ORDER.
#     virts1 -> hvc1   virts2 -> hvc2   virts4 -> hvc3
#     virts5 -> hvc4  <- Wi-Fi (this script)
#     virts6 -> hvc5
#   (virts3 is a virtserialport, so it takes no hvc and stays /dev/vport2p2.)
#   Measured 2026-09-07: on /dev/hvc4 the JSON from DomD's agent arrives, and a
#   connect to <SSID-A> reached COMPLETED on the DomD side.
CHAN=${CHAN:-/dev/hvc4}
AP_IF=${AP_IF:-wlan2}
BR=${BR:-br-shadow}
# The two things used to detect a station. See the stations_present() comment.
STA_IF=${STA_IF:-wlan0}
# NETDEV_DIR / STA_CARRIER / STA_FLAGS / IW can be overridden like the paths
#   above, so stations_present() and sta_is_up() also run without hardware. On
#   the device the defaults apply.
NETDEV_DIR=${NETDEV_DIR:-/sys/class/net}
STA_CARRIER=${STA_CARRIER:-$NETDEV_DIR/$STA_IF/carrier}
STA_FLAGS=${STA_FLAGS:-$NETDEV_DIR/$STA_IF/flags}
IW=${IW:-/system/bin/iw}
# Passphrase a newly discovered SSID gets until the user types the real one.
#
# IT MUST BE A VALID WPA2 PASSPHRASE, NOT EMPTY. An empty PSK makes the BSS
# beacon OPEN, and an open BSS optimises away the exact event this whole design
# depends on: the AAOS Wi-Fi screen shows no lock and NEVER PROMPTS FOR A
# PASSWORD, the association succeeds locally, DISABLED_BY_WRONG_PASSWORD never
# fires, DomaWifiRelay never learns a passphrase, DomD never associates -- a
# permanent "connected, no internet" dead end with no way out. The failure is
# load-bearing: the BSS must be WPA2 so the UI prompts, the handshake fails
# against this placeholder, and the app can then read the typed value and
# repair. Any 8..63 character string works; it is never meant to match anything.
#
# CONSEQUENCE TO EXPECT ON SCREEN: an SSID the relay discovered but nobody has
# typed a password for yet shows a lock icon, and the first attempt fails for a
# few seconds before the repair completes. A genuinely OPEN real AP is not
# supported through this path: the `sec` field of the aps message says which are
# open, but the extraction in handle_aps reads only the ssid values.
PLACEHOLDER_PSK=${PLACEHOLDER_PSK:-doma-relay-unprovisioned-0000}

# --- boot-time mirror --------------------------------------------------------
# After a reboot DomD's real association is gone (its wpa_supplicant starts
# INACTIVE) while DomA's station re-associates with the shadow AP on its own,
# because the saved PSK is already in aps.conf and the framework auto-connects.
# Nothing in the UI path fires -- the LOCAL handshake succeeds -- so no
# connect() would be forwarded and DomA would sit on a Wi-Fi with no upstream.
#
# So mirror_station() (main loop, every tick) reads the SSID the station is
# associated with (`iw dev wlan0 link`, decoded by iw_ssid()) and forwards
# connect(ssid, psk_of ssid) to DomD ONCE per (boot, ssid, psk). The marker file lives
# in $CONF_DIR (persistent) but carries the kernel boot_id, so a daemon restart does not
# re-forward and a reboot does. handle_psk() writes the same marker after its own
# forward, so the UI repair path and the mirror never send the same connect twice. A
# placeholder PSK is never forwarded, and neither is an SSID $APS has no row for.
# Kill switch:  setprop persist.vendor.doma.wifi_relay_mirror false
MIRROR_MARK=${MIRROR_MARK:-$CONF_DIR/mirror.mark}
BOOTID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
[ -n "$BOOTID" ] || BOOTID=noboot-$$
STA_LAST_SSID=""
# 1 when hostapd.conf has changes that hostapd has not picked up yet, because a
# station was associated at the time. See flush_pending_restart().
RESTART_PENDING=0
# The shipped seed. Why handle_aps consults it: see the seed_psk_of() comment.
SEED=${SEED:-/vendor/etc/doma-shadow-aps.conf}
# Whether an incoming aps message may restart hostapd. THE DEFAULT IS auto.
#   auto (unset / default): restart only when stations_present() is false. While a
#     station is associated, do not restart; set RESTART_PENDING instead and apply it
#     on the first tick after it leaves (flush_pending_restart), so an
#     unattended restart does not drop the user's connection.
#   false: never touch hostapd on aps (update the conf only). A new SSID starts
#     beaconing at the next boot (regenerated by doma-shadow-ap) or on a PSK repair.
#   true : restart even with a station present. THIS CAN DROP DomA'S ONLY WAY IN, so
#     use it only while sitting in front of the screen.
#
# THE VALUE IS getprop'd BY handle_aps FOR EVERY MESSAGE, so a `setprop` takes
#   effect from the next publication without restarting the relay. The
#   environment variable BOUNCE_ON_APS takes precedence if set.
# (A PSK repair -- the restart after the user types a passphrase on screen -- always
#  happens, independently of this flag.)
BOUNCE_ON_APS=${BOUNCE_ON_APS:-}
TAB="$(printf '\t')"

# NOT IN THE virt_wifi FALLBACK. With persist.vendor.doma.shadow_ap not true,
# doma-shadow-ap hands wlan0 to virt_wifi and creates no shadow AP (no wlan2, no
# br-shadow), so there is nothing to relay: a publication would only crash-loop hostapd,
# and the mirror would forward the VirtWifi association to DomD. Idle rather than exit,
# since init restarts a service that exits. Same property and default as doma-shadow-ap.
if [ "$(getprop persist.vendor.doma.shadow_ap true)" != "true" ]; then
    log "persist.vendor.doma.shadow_ap is not true (virt_wifi fallback) -- nothing to relay; idling"
    while :; do sleep 3600; done
fi

[ -d "$CONF_DIR" ] || { log "FATAL: $CONF_DIR missing -- start doma_shadow_ap first"; exit 1; }
[ -e "$CHAN" ]     || { log "FATAL: $CHAN missing -- is the doma.cfg virtio-serial chardev there?"; exit 1; }

mkdir -p "$REQ_DIR" 2>/dev/null
# init.xenvm-hwsim.rc already creates this as wifi:system 0770 in `on post-fs-data`;
# this is the fallback for a /data where the directory exists with another
# owner.
chown wifi:system "$REQ_DIR" 2>/dev/null || log "WARNING: chown $REQ_DIR failed; the app may not be able to write requests"
chmod 0770 "$REQ_DIR" 2>/dev/null

# --- helpers -------------------------------------------------------------------------

# psk_of <ssid> -- the PSK currently recorded for an SSID: empty for an open row;
# returns 1 when $APS has no row for it.
#
# THE _k/_v NAMES ARE LOAD-BEARING. Shell functions share one namespace, so a
# `while read -r s p` in here would overwrite a caller's $s: a caller that loops
# over SSIDs and calls this on each would see every SSID after the first come
# back EMPTY (reproduced on the PC). Every variable a helper touches here is
# _-prefixed for that reason.
psk_of() {
    while IFS="$TAB" read -r _k _v; do
        case "$_k" in ''|'#'*) continue;; esac
        [ "$_k" = "$1" ] && { printf '%s' "${_v:-}"; return 0; }
    done < "$APS"
    return 1
}

# seed_psk_of <ssid> -- the PSK the shipped seed holds for that SSID; returns 1
# if there is none.
#
# WHY handle_aps CONSULTS THE SEED. A publication that names an SSID $APS lacks
# gets the seed's PSK for it rather than $PLACEHOLDER_PSK, so a lost $APS cannot
# turn a seeded AP -- possibly the one DomA's own station is using -- into a
# placeholder the moment hostapd restarts. doma-shadow-ap's merge brings seed
# rows back at boot, but it leaves an existing row alone, placeholder or not, so
# it cannot do this. The committed seed carries only the EXAMPLE-SSID
# placeholder; this matters for a build whose seed names a real AP.
seed_psk_of() {
    [ -s "$SEED" ] || return 1
    # `|| [ -n "$_sk" ]`: the seed is hand-edited, so do not drop the last line when
    # it has no trailing newline
    while IFS="$TAB" read -r _sk _sv || [ -n "${_sk:-}" ]; do
        case "$_sk" in ''|'#'*) continue;; esac
        [ "$_sk" = "$1" ] && { printf '%s' "${_sv:-}"; return 0; }
    done < "$SEED"
    return 1
}

# json_esc <string> -- escape a value for embedding in the JSON sent to DomD.
#
# NEEDED, NOT COSMETIC. A WPA passphrase is any 8..63 printable ASCII
# characters, so it may legally contain \ or ". The connect message is parsed on
# the far side by json.loads() (parse_line() in domd_wifi_agent.py), which
# rejects or mis-decodes an unescaped one, and the failure would look like "the
# password is wrong" rather than "the message was malformed". Only \ and " need
# handling: control characters cannot appear in a passphrase, and DomD's agent
# publishes no SSID that has one. The \ substitution must run FIRST or it would
# double the backslashes " introduces.
json_esc() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# write_hostapd_conf -- regenerate $CONF from $APS.
#
# THIS IS A SECOND COPY of the generation loop in step 3 of doma-shadow-ap.sh,
# and the two MUST be kept in sync: both skip the same rows (ssid_hostapd_safe,
# psk_valid) and write the same stanzas. It is duplicated rather than factored
# out on purpose: doma-shadow-ap is the path every boot depends on, and making
# it source one would add a new way for that path to fail. If you change the
# stanza format, change both and say so in the commit message.
write_hostapd_conf() {
    {
        echo "interface=$AP_IF"
        echo "bridge=$BR"
        echo "driver=nl80211"
        echo "ctrl_interface=$CONF_DIR/sockets"
        echo "hw_mode=g"
        echo "channel=6"
        echo "ieee80211n=1"
        # Emit `bridge=` in every BSS stanza (see step 3 of doma-shadow-ap.sh).
        #   Primary sources (this apex is not a prebuilt, IT IS BUILT FROM THIS TREE:
        #   the binaries at
        #   device/google/cuttlefish/apex/com.google.cf.wpa_supplicant/Android.bp:28-29
        #   are //external/wpa_supplicant_8/wpa_supplicant/wpa_supplicant:hostapd):
        #     external/wpa_supplicant_8/hostapd/config_file.c:2240-2241
        #         `bridge` is os_strlcpy(bss->bridge, ...), i.e. A PER-BSS FIELD
        #     same file :871-906, hostapd_config_bss()
        #         only os_zalloc + hostapd_config_defaults_bss + copying iface/vlan,
        #         AND IT DOES NOT COPY bridge (nor is a default set anywhere in
        #         src/ap/ap_config.c)
        #     src/ap/hostapd.c:1510  conf->bridge[0] ? conf->bridge : NULL
        #     src/drivers/driver_nl80211.c:9706  the `bridge &&` gate
        #   => Written once at the top, every BSS after the first has no bridge, so a
        #   station joining it never completes DHCP. Measured on the board,
        #   2026-09-07: with the seed SSID sixth, association reached COMPLETED
        #   / RSSI -30 but IP: null; moved back to the front, wlan0 got
        #   192.168.10.134/24.
        _first=1
        _idx=0
        while IFS="$TAB" read -r _ssid _psk; do
            case "$_ssid" in ''|'#'*) continue;; esac
            # log() writes to stdout, i.e. into $CONF.new here: use stderr.
            if ! ssid_hostapd_safe "$_ssid"; then
                log "conf: skip SSID hostapd would reject: $_ssid" >&2
                continue
            fi
            if [ -n "${_psk:-}" ] && ! psk_valid "$_psk"; then
                log "conf: skip $_ssid: PSK neither 8..63 bytes nor 64 hex" >&2
                continue
            fi
            if [ "$_first" = 1 ]; then
                _first=0
            else
                _idx=$((_idx+1))
                echo "bss=${AP_IF}_$_idx"
                echo "bridge=$BR"
            fi
            echo "ssid=$_ssid"
            if [ -n "${_psk:-}" ]; then
                echo "wpa=2"
                echo "wpa_key_mgmt=WPA-PSK"
                echo "rsn_pairwise=CCMP"
                if psk_is_hex "$_psk"; then
                    echo "wpa_psk=$_psk"
                else
                    echo "wpa_passphrase=$_psk"
                fi
            else
                echo "wpa=0"
            fi
        done < "$APS"
    } > "$CONF.new" || { log "WARNING: cannot write $CONF.new"; return 1; }
    # SET OWNER AND MODE BEFORE THE mv. rename(2) preserves owner/mode, so this
    #   removes (a) any instant where a file containing a wpa_passphrase exists as
    #   root:root 0644, and (b) the "mv succeeded but chown failed, so hostapd cannot
    #   read it" case.
    #
    #   Why the chown is needed: HOSTAPD DROPS PRIVILEGES ITSELF.
    #   os_program_init() in external/wpa_supplicant_8/src/utils/os_unix.c does
    #   setgroups({wifi, inet, keystore, log}) -> PR_SET_KEEPCAPS -> setuid, so even
    #   though init.xenvm-hwsim.rc starts it with `user root` it runs as uid wifi.
    #   At root:root it repeatedly exits 1 with
    #   `Could not open configuration file ... for reading`. Measured 2026-09-07:
    #   12 TIMES, 5.0 s APART (15:25:40 to 15:26:35, matching init's default
    #   restart_period of 5 s), and after the chown, at 15:26:40, the same file
    #   reached `wlan2: AP-ENABLED`.
    #   NOTE that this message is printed for every fopen failure in
    #   hostapd/config_file.c, SO IT CANNOT DISTINGUISH EACCES FROM ENOENT (that log
    #   alone is not enough to pin the cause on permissions; what does pin it is the
    #   A/B: after the chown the same path worked).
    chown wifi:wifi "$CONF.new" 2>/dev/null || log "WARNING: chown $CONF.new failed"
    chmod 0660 "$CONF.new" 2>/dev/null || log "WARNING: chmod $CONF.new failed"
    mv "$CONF.new" "$CONF" || { log "WARNING: cannot replace $CONF"; return 1; }
}

# stations_present -- 0 if any station is associated with the shadow AP.
# Used to avoid bouncing hostapd under a connected user; hostapd has no way to add or
# remove a BSS without a restart, and SIGHUP does not apply bss= changes.
#
# hostapd_cli IS NOT IN THIS IMAGE (measured on the board: the apex's bin/hw
#   holds hostapd and wpa_supplicant only, and no hostapd_cli or wpa_cli exists
#   under /apex, /vendor or /system; the `binaries` at Android.bp:28-29 is the
#   single hostapd). So two other methods are tried, cheapest first, and IF
#   NEITHER CAN BE READ THE ANSWER IS "A STATION IS PRESENT" (i.e. do not
#   restart -- fall to the safe side).
#
#   Why the safe side: with the seed PSK unchanged, `setprop ctl.restart` on the
#   hostapd service under a connected station was measured on the board to leave
#   DomA's Wi-Fi not coming back. Whether a restart with the same PSK can be
#   survived is not established: dnsmasq has a MAC-pinned lease (43200 s), so
#   the same IP is expected to return, but in that measurement it did not.
#     1. $STA_CARRIER (/sys/class/net/wlan0/carrier) -- DomA's own station. THIS IS THE
#        ONLY STATION THERE IS TO PROTECT (DomA's external connectivity is this one
#        BSS). mac80211 raises carrier on a successful association. Primary source:
#        netif_carrier_on(sdata->dev) at :3987, the end of ieee80211_set_associated()
#        (:3908) in the guest kernel's net/mac80211/mlme.c. THIS IS NOT AN INFERENCE:
#        it reads 1 whichever BSS the station is joined to.
#     2. $IW (/system/bin/iw) -- really present in the image (system/bin/iw, 280,760 B).
#        It station-dumps the AP-side netdev. A STATION ON A SECONDARY BSS DOES NOT
#        SHOW UP in the wlan2 dump, so $AP_IF and the generated ${AP_IF}_N are
#        enumerated from $NETDEV_DIR.
#        THIS IS A BONUS THAT ONLY WORKS WHILE THE BOARD IS PERMISSIVE. Under
#        enforcing the exec is denied, AND NO ALLOW CAN BE WRITTEN FOR IT: iw's label
#        is iw_exec (system/sepolicy/private/file_contexts:292), but private/iw.te:2
#        declares `type iw_exec, system_file_type, ...`, and iw_exec IS NOT IN the
#        exclusion list (shell_exec / toolbox_exec / netutils_wrapper_exec, etc.) of
#        domain.te's "vendor must not access files on /system" neverallow
#        => writing the allow is a hard secilc failure and breaks the build (measured
#        with /system/bin/ip; see the comment in sepolicy/doma_shadow_ap.te). There is
#        no netutils-wrapper escape either (only ip6tables/iptables/ndc/tc/ip are
#        wrapped).
#        => LOSING IT IS HARMLESS: the decision is still reached from carrier in 1
#        (reading sysfs_net is already allowed in the .te), and if neither can be read
#        it falls back to "a station is present", i.e. no restart.
#   An image that ships hostapd_cli could add it, but these two are sufficient.
stations_present() {
    _known=0
    # 1. DomA's own station
    if [ -r "$STA_CARRIER" ]; then
        _known=1
        [ "$(cat "$STA_CARRIER" 2>/dev/null)" = 1 ] && return 0
    fi
    # 2. Any other station on any AP-side netdev (wlan2 and wlan2_1..N)
    if [ -x "$IW" ]; then
        for _d in "$NETDEV_DIR/$AP_IF" "$NETDEV_DIR/$AP_IF"_*; do
            [ -d "$_d" ] || continue
            _sta=$("$IW" dev "${_d##*/}" station dump 2>/dev/null) || continue
            _known=1
            [ -n "$_sta" ] && return 0
        done
    fi
    [ "$_known" = 1 ] && return 1
    # 3. Neither is usable => fall to the safe side (a station is present). Log once.
    if [ "${NODETECT_LOGGED:-0}" != 1 ]; then
        NODETECT_LOGGED=1
        log "stations_present: cannot detect a station (neither $STA_CARRIER nor $IW is usable) -- returning \"station present\" on the safe side; no aps-driven hostapd restart"
    fi
    return 0
}

# sta_is_up -- is DomA's station interface up, i.e. is the Settings Wi-Fi toggle on?
#
# WHY ONLY $REQ WAITS ON IT. Turning Wi-Fi off in the DomA Settings must also stop DomD
# being asked to associate, and a PSK request is the only thing that asks while the
# station is down (mirror_station already does nothing without carrier). aps
# publications keep syncing $APS and hostapd.conf: no station can be dropped, and the
# list is current the moment the toggle comes back on.
#
# FLAGS, NOT CARRIER. With the toggle off the framework takes wlan0 down -- measured on
# RPi4 2026-09-24, flags 0x1003 -> 0x1002 within 1 s -- and carrier then reads -EINVAL
# (net/core/net-sysfs.c: carrier_show() needs netif_running()). flags is printed "%#x"
# and IFF_UP is bit 0, so the last hex digit is odd exactly when the interface is up;
# `case`, because a test operand cannot be hex in mksh. Unreadable (wlan0 not created
# yet) counts as up.
sta_is_up() {
    _fl=$(cat "$STA_FLAGS" 2>/dev/null) || return 0
    case "$_fl" in
        0x*[13579bdfBDF]) return 0;;
        0x*)              return 1;;
        *)                return 0;;
    esac
}

# confirm_hostapd_running -- check that running IS SUSTAINED.
#
# WHY IT IS NEEDED (from primary sources):
#   init's `NotifyStateChange("running")` is fired IN THE PARENT, RIGHT AFTER
#   THE FORK (system/core/init/service.cpp:817, just after waiting for `setsid`
#   to complete and before the `... started service` log). It IS UNRELATED to
#   whether the child then `exit 1`s in config parsing after exec. When the
#   child dies, the SIGCHLD reaping at :322 clears SVC_RUNNING and :428 fires
#   `"restarting"`.
#   => A `getprop init.svc.*` taken immediately after `setprop ctl.restart`
#   returns IS ALWAYS running, even with an INVALID hostapd.conf. Taken as
#   success, it would log "hostapd restarted via init (N SSID(s))" and reset
#   `RESTART_PENDING` to 0 while hostapd crash-loops every 5 s and the shadow AP
#   -- DomA's only way in -- is gone. That covers EVERY CASE THAT MAKES THE CONF
#   INVALID, including a wrong owner or mode (the measured "12 times, 5.0 s
#   apart" in write_hostapd_conf).
#
# init's `restart_period` defaults to 5 s, so sampling a 3 s window every 0.5 s
# (6 samples) is guaranteed to catch a non-running state at least once during a
# crash loop. The values can be overridden from the environment.
# The hostapd init service, vendor.doma_shadow_hostapd in init.xenvm-hwsim.rc.
#   `setprop ctl.restart` exits non-zero when init has no service of that name:
#   init's control-message handler replies PROP_ERROR_HANDLE_CONTROL_MESSAGE,
#   and bionic's __system_property_set() and toolbox's setprop turn that into a
#   failed exit (system/core/init/init.cpp,
#   bionic/libc/bionic/system_property_set.cpp,
#   system/core/toolbox/setprop.cpp). init replies only to a vendor above API
#   level Q (SelinuxGetVendorAndroidVersion() in property_service.cpp); this
#   board's vendor has ro.vendor.build.version.sdk=37.
HOSTAPD_SVC=${HOSTAPD_SVC:-vendor.doma_shadow_hostapd}

kick_hostapd() {
    setprop ctl.restart "$HOSTAPD_SVC"
}

# svc_is_running -- is the hostapd service running?
#
# THIS DOES NOT CONTRADICT the "do not add pidof" note in restart_hostapd. What that
#   forbids is ANDing pidof into the success condition (which creates a false-negative
#   window until the apex's hostapd execs, plus a window where an old pid is caught).
#   Here it is a last resort used ONLY WHEN init.svc READS EMPTY -- a
#   substitute, not an OR. For vendor.doma_shadow_hostapd the property is
#   readable from this domain (vendor_default_prop; see the service's comment in
#   init.xenvm-hwsim.rc), so after a ctl.restart it is not empty and the
#   fallback is not taken. It stays for a HOSTAPD_SVC given another name.
#   The pidof route is weak (it can catch the moment before init has finished killing
#   the old process), but the way it errs is A FALSE WARNING; it never manufactures a
#   false success. The real decision is confirm_hostapd_running's 3 s window, so if
#   running is not sustained it ends in a WARNING anyway.
svc_is_running() {
    _st=$(getprop "init.svc.$HOSTAPD_SVC" 2>/dev/null)
    if [ -n "$_st" ]; then
        [ "$_st" = running ]
        return $?
    fi
    pidof hostapd >/dev/null 2>&1
}

CONFIRM_SAMPLES=${CONFIRM_SAMPLES:-6}
CONFIRM_SLEEP=${CONFIRM_SLEEP:-0.5}
confirm_hostapd_running() {
    _n=0
    while [ "$_n" -lt "$CONFIRM_SAMPLES" ]; do
        sleep "$CONFIRM_SLEEP"
        svc_is_running || return 1
        _n=$((_n+1))
    done
    return 0
}

# restart_hostapd -- make hostapd read the new $CONF.
#
# GO THROUGH init. HOSTAPD IN THIS IMAGE IS AN INIT SERVICE ($HOSTAPD_SVC),
#   started in the foreground by its init.xenvm-hwsim.rc service (with neither
#   -B nor -P), so no pid file exists to kill it by, and a second hostapd -B
#   started here fails because wlan2 is in use: the new SSIDs would go into
#   hostapd.conf and never make it into a beacon. This follows step 5 of
#   doma-shadow-ap.sh (setprop ctl.* plus a wait), and consults init.svc.<name>
#   rather than pidof alone, because with pidof alone there is a moment where
#   the old pid is caught.
restart_hostapd() {
    # LOOK AT `init.svc.$HOSTAPD_SVC` ONLY. Do not AND in `pidof hostapd` (as the
    #   svc_is_running comment says, pidof is a substitute for when init.svc cannot be
    #   read, not an additional success condition).
    #   `setprop ctl.*` DOES NOT RETURN UNTIL INIT HAS FINISHED HANDLING IT
    #   (SendControlMessage() in property_service.cpp Releases the client's socket fd
    #   and hands it to init, and init replies AFTER running
    #   HandleControlMessage()). So by the time setprop returns, the old instance has
    #   already been SIGKILLed and the state has been updated.
    #   ANDing `pidof hostapd` in here would produce a false negative during the window
    #   until the apex's hostapd has started and its process name is visible, and
    #   conversely CREATE A WINDOW WHERE THE OLD PID IS CAUGHT.
    kick_hostapd || {
        log "WARNING: ctl.restart $HOSTAPD_SVC failed (the rc has no such service)"
        RESTART_PENDING=1
        return 1
    }
    # THIS WAIT STALLS THE MAIN LOOP FOR UP TO 10 s (the caller polls every 2 s). If
    #   the hvc receive buffer overflows, one DomD publication can be lost. In practice
    #   the apex's hostapd reaches running in under a second, so this normally exits in
    #   less than 1 s.
    #   Shortening it would mean restructuring to "fire, return, and look at init.svc on
    #   the next tick", which moves where the success log comes from, so it is left as
    #   is for now.
    _i=0
    while [ $_i -lt 100 ]; do        # up to 10 s; the apex's hostapd comes up in under a second
        if svc_is_running; then
            # Do not call this a success yet (see the confirm_hostapd_running comment).
            if confirm_hostapd_running; then
                RESTART_PENDING=0
                log "hostapd restarted via init ($(grep -c '^ssid=' "$CONF") SSID(s))"
                return 0
            fi
            RESTART_PENDING=1
            log "WARNING: hostapd dies right after starting (init.svc does not sustain running). Check $CONF (is it owned wifi:wifi 0660? is wpa_passphrase 8..63 bytes?)"
            return 1
        fi
        _i=$((_i+1)); sleep 0.1
    done
    # ON FAILURE, SET RESTART_PENDING, so flush_pending_restart retries on a
    #   later tick. The hostapd service is neither critical nor updatable, so
    #   repeated failures cannot reboot the device.
    RESTART_PENDING=1
    log "WARNING: hostapd restart failed (svc=$HOSTAPD_SVC init.svc=$(getprop "init.svc.$HOSTAPD_SVC")); see $CONF"
    return 1
}

# --- handlers ------------------------------------------------------------------------

# ssid_hostapd_safe <ssid> -- false for a name hostapd.conf cannot carry.
#
# ONE bad SSID makes hostapd reject the WHOLE config, and with it the shadow AP
# and all of DomA's Wi-Fi: measured 2026-09-17, an AP beaconing 20 NUL bytes
# left the shadow AP restarting every 5 s. hostapd takes `ssid=` byte for byte
# (hostapd/config_file.c copies it with os_memcpy) and refuses more than 32
# bytes; that SSID's escaped form, \x00 twenty times, is 80. A backslash means
# the name is still escaped -- DomD's JSON escapes a quote or a backslash in an
# SSID, and the sed in handle_aps does not undo that -- so it is refused as
# well. Count BYTES: mksh's ${#s} counts characters under UTF-8.
# doma-shadow-ap.sh carries the same function.
ssid_hostapd_safe() {
    case "$1" in ''|*\\*) return 1;; esac
    [ "$(printf '%s' "$1" | wc -c)" -le 32 ]
}

# psk_is_hex <psk> -- a raw PSK: exactly 64 hex digits. hostapd.conf carries it
# as wpa_psk=, and DomD's agent sends it to wpa_supplicant unquoted.
psk_is_hex() {
    case "$1" in ''|*[!0-9A-Fa-f]*) return 1;; esac
    [ "${#1}" -eq 64 ]
}

# psk_valid <psk> -- is this a PSK both hostapd and DomD's wpa_supplicant
# accept?
#
# Two forms exist. A passphrase is 8..63 BYTES (count bytes, as above). A raw
# PSK is 64 hex digits (psk_is_hex): AAOS's Wi-Fi dialog LEGITIMATELY ACCEPTS
# ONE and stores it unquoted
# (packages/apps/Car/Settings/.../WifiUtil.java:285-288 puts it into
# preSharedKey without quotes when `password.matches("[0-9A-Fa-f]{64}")`), and
# hostapd takes it as wpa_psk=
# (external/wpa_supplicant_8/hostapd/config_file.c:2923-2934), which is how both
# generators write it.
#
# Anything else is refused BEFORE it reaches $APS or DomD.
# config_file.c:2910-2916 rejects a wpa_passphrase outside 8..63, and one error
# makes hostapd throw the WHOLE config away and exit 1; in $APS (on /data) that
# would happen at every boot and take the shadow AP -- DomA's way in -- with it.
# DomD's wpa_supplicant, for its part, prints a passphrase it refuses into its
# log. $REQ is wifi:system 0770 and is writable by more than just the app, so A
# GUARD IN THE APP ALONE IS NOT THE LAST LINE OF DEFENCE.
psk_valid() {
    psk_is_hex "$1" && return 0
    _n=$(printf '%s' "$1" | wc -c)
    [ "$_n" -ge 8 ] && [ "$_n" -le 63 ]
}

# iw_ssid <SSID as iw prints it> -- the SSID's real bytes; returns 1 for one
# that has a control byte.
#
# `iw dev wlan0 link` prints the SSID through print_ssid_escaped()
# (external/iw/util.c): each byte that is not printable ASCII, each backslash,
# and a space at either end come out as \x and two lower-case hex digits, and
# nothing else is escaped. $APS holds the real bytes -- DomD's agent publishes
# SSIDs as UTF-8 text -- so iw's form of a name such as a Japanese one matches
# no row. Undecoded, psk_of would miss it and the mirror would send DomD's
# agent the escaped text with an empty PSK, which the agent would join as an
# open network in place of the real one. Every backslash iw prints starts such an
# escape, so each is rewritten as the octal \0NNN that printf's %b decodes, in
# toybox's printf (the one mksh runs on the device) as in bash's, dash's and
# busybox's. A control byte is refused rather than decoded: DomD's agent
# publishes no SSID that has one, and a NUL or a newline would not survive
# $(...).
iw_ssid() {
    _in=$1; _out=""
    while :; do
        case "$_in" in *\\x*) ;; *) break;; esac
        _out=$_out${_in%%\\x*}
        _in=${_in#*\\x}
        case "$_in" in [0-9a-f][0-9a-f]*) ;; *) return 1;; esac
        _c=$((0x${_in%"${_in#??}"}))
        [ "$_c" -ge 32 ] && [ "$_c" -ne 127 ] || return 1
        _in=${_in#??}
        _out=$_out\\0$((_c / 64))$((_c / 8 % 8))$((_c % 8))
    done
    printf '%b' "$_out$_in"
}

# sta_link_ssid -- the SSID DomA's own station is associated with, decoded by
# iw_ssid(); iw's own form if iw_ssid() refuses it (that matches no row of
# $APS); empty when the station is not associated.
sta_link_ssid() {
    _raw=$("$IW" dev "$STA_IF" link 2>/dev/null | sed -n 's/^[[:space:]]*SSID: //p' | head -n 1)
    [ -n "$_raw" ] || return 0
    iw_ssid "$_raw" || printf '%s' "$_raw"
}

# current_sta_ssid -- the SSID DomA's own station is associated with, or empty.
current_sta_ssid() {
    if [ -n "${STA_LAST_SSID:-}" ]; then
        printf '%s' "$STA_LAST_SSID"
        return 0
    fi
    [ -x "$IW" ] || return 0
    if [ -r "$STA_CARRIER" ] && [ "$(cat "$STA_CARRIER" 2>/dev/null)" != 1 ]; then
        return 0
    fi
    sta_link_ssid
}

# in_ssid_list <ssid> <newline-separated list>
in_ssid_list() {
    _needle=$1
    while IFS= read -r _hay; do
        [ "$_hay" = "$_needle" ] && return 0
    done <<EOF
$2
EOF
    return 1
}

# handle_aps <json-line> -- make $APS mirror the SSIDs DomD can currently hear.
#
# Each publication REPLACES the list, so the picker shows what is actually in
# range, and a row that stops being published does not stay in hostapd.conf.
#
# Two kinds of row survive a publication that does not mention them:
#   * the SSID DomA's own station is associated with -- dropping it would delete
#     the shadow AP DomA is connected to, taking down the link this session runs
#     over;
#   * seeded rows (/vendor/etc/doma-shadow-aps.conf), which must be joinable
#     even before the first scan arrives.
# Existing rows keep their order and their PSK, so the primary BSS does not move
# and no learned credential is lost; only genuinely absent APs go away.
handle_aps() {
    # Extract every "ssid":"..." value. sed, not a JSON parser: toybox has none
    # and the producer is one known program. An SSID with a quote or a backslash
    # arrives escaped, and ssid_hostapd_safe refuses it below.
    _ssids=$(printf '%s\n' "$1" \
            | tr ',' '\n' | sed -n 's/.*"ssid"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [ -n "$_ssids" ] || return 0
    _added=0
    _dropped=0
    _sta=$(current_sta_ssid)
    _tmp=$APS.sync.$$
    # In a subshell: `:` is a special builtin, and mksh ends the function on a
    #   failed redirection onto one before `||` runs (see doma-shadow-ap.sh's
    #   seed merge).
    if ! ( : > "$_tmp" ) 2>/dev/null; then
        log "WARNING: aps: cannot write $_tmp"
        return 0
    fi

    # 1. existing rows, in order, if still in range (or protected)
    while IFS="$TAB" read -r _k _v || [ -n "${_k:-}" ]; do
        case "$_k" in ''|'#'*) continue;; esac
        if in_ssid_list "$_k" "$_ssids" \
           || { [ -n "$_sta" ] && [ "$_k" = "$_sta" ]; } \
           || seed_psk_of "$_k" >/dev/null 2>&1; then
            printf '%s%s%s\n' "$_k" "$TAB" "${_v:-}" >> "$_tmp"
        else
            _dropped=$((_dropped+1))
        fi
    done < "$APS"

    # 2. SSIDs in this publication that are not in the list yet
    # DO NOT WRITE `for _new in $_ssids`. With the default IFS, AN SSID
    #   CONTAINING A SPACE IS SPLIT into two rows, neither of them the real
    #   name. A pipe would lose $_added in a subshell, hence the here-document.
    #   AN SSID CONTAINING A COMMA is silently dropped by the tr above.
    while IFS= read -r _new; do
        [ -n "$_new" ] || continue
        if ! ssid_hostapd_safe "$_new"; then
            log "aps: skip SSID hostapd would reject (whole config would fail): $_new"
            continue
        fi
        _seen=0
        while IFS="$TAB" read -r _k2 _v2 || [ -n "${_k2:-}" ]; do
            [ "$_k2" = "$_new" ] && { _seen=1; break; }
        done < "$_tmp"
        [ "$_seen" = 1 ] && continue
        # If the seed holds a PSK for this SSID, use it rather than the
        #   placeholder; see the seed_psk_of() comment.
        if _seedpsk=$(seed_psk_of "$_new"); then
            printf '%s%s%s\n' "$_new" "$TAB" "$_seedpsk" >> "$_tmp"
            log "aps: registered $_new with the seed's PSK (not a placeholder)"
        else
            printf '%s%s%s\n' "$_new" "$TAB" "$PLACEHOLDER_PSK" >> "$_tmp"
        fi
        _added=$((_added+1))
    done <<EOF
$_ssids
EOF

    # 3. nothing to do unless the list actually changed
    if cmp -s "$_tmp" "$APS" 2>/dev/null; then
        rm -f "$_tmp"
        return 0
    fi
    # By rename, as handle_psk does: this daemon runs on every boot, so init's
    # SIGKILL at shutdown can land mid-write, and a truncated $APS loses every learned
    # PSK. The temporary file is in the same directory, so it has the same label.
    chmod 0660 "$_tmp" 2>/dev/null
    if ! mv -f "$_tmp" "$APS"; then
        log "WARNING: aps: could not update $APS"
        rm -f "$_tmp"
        return 0
    fi
    log "aps: synced to the current scan (+$_added -$_dropped, now $(grep -c . "$APS") row(s))"
    write_hostapd_conf || return 0
    # Read per message, so a setprop takes effect without restarting the relay.
    #   The environment variable BOUNCE_ON_APS takes precedence if set.
    _bounce=${BOUNCE_ON_APS:-$(getprop persist.vendor.doma.wifi_relay_bounce_on_aps 2>/dev/null)}
    if [ "$_bounce" = false ]; then
        log "aps: conf updated only (...wifi_relay_bounce_on_aps=false); it reaches the beacon at the next boot or on a PSK repair"
    elif [ "$_bounce" != true ] && stations_present; then
        RESTART_PENDING=1
        log "aps: a station is associated -- deferring the hostapd restart (the conf is already updated; it will be applied once the station leaves)"
    else
        restart_hostapd
    fi
}

# flush_pending_restart -- apply a deferred conf once the last station has gone.
#
# WITHOUT THIS A DEFERRAL CAN LAST FOREVER. A publication that arrives while the
# user is connected defers the restart, and the next one finds nothing new:
# handle_aps returns as soon as cmp finds $APS unchanged, before reaching any
# restart, and handle_psk cannot fire for an SSID the user cannot see. Checked
# from the main loop instead, so the pending conf is applied within one tick (<=
# 2 s) of the station disconnecting.
flush_pending_restart() {
    [ "$RESTART_PENDING" = 1 ] || return 0
    # NOT WHILE doma_shadow_ap IS ITSELF BRINGING hostapd UP. Both run at
    # sys.boot_completed, and on the board a deferred restart that landed
    # between the oneshot's `ctl.start` and its confirmation left the log saying
    # "hostapd died right after start", the bridge up late and a second restart
    # needed. The oneshot reports `stopped` once it has exited; defer one tick
    # until then.
    [ "$(getprop init.svc.doma_shadow_ap 2>/dev/null)" = running ] && return 0
    stations_present && return 0
    log "applying deferred hostapd conf (no station associated)"
    restart_hostapd
}

# handle_psk <ssid> <psk> -- the user typed a passphrase; make it work.
#
# Order matters: hostapd must know the PSK BEFORE the app re-triggers the
# connect, or the retry fails the same way. DomD is told in parallel so the real
# association is under way while the local one completes.
handle_psk() {
    _s=$1; _p=$2
    # A PSK psk_valid refuses goes nowhere, neither into $APS nor to DomD, and
    #   the log names neither the value nor its length.
    if [ -n "${_p:-}" ] && ! psk_valid "$_p"; then
        log "WARNING: psk: PSK for $_s is not 8..63 bytes or 64 hex; dropped"
        return 0
    fi
    cur=$(psk_of "$_s" 2>/dev/null) || cur=""
    if [ "$cur" = "$_p" ]; then
        log "psk: $_s already current; only forwarding to DomD"
    else
        # Rewrite just this SSID's row with awk, because the PSK may contain characters
        # that would confuse sed's replacement.
        #
        # VALUES COME THROUGH ENVIRON, NOT -v. awk processes escape sequences in
        # a -v assignment, so `-v p='a\\b'` reaches the program as `a\b`: a
        # passphrase containing a backslash would be corrupted, and since the
        # corrupted value would land in BOTH aps.conf and hostapd.conf, the
        # local handshake would succeed while the real AP rejected it
        # (reproduced on the PC). ENVIRON does no such processing.
        RELAY_SSID=$_s RELAY_PSK=$_p awk -F'\t' 'BEGIN{OFS="\t"; s=ENVIRON["RELAY_SSID"]; p=ENVIRON["RELAY_PSK"]}
            /^#/ || NF==0 { print; next }
            $1==s { print s, p; seen=1; next }
            { print }
            END { if (!seen) print s, p }' "$APS" > "$APS.new" && mv "$APS.new" "$APS"
        chmod 0660 "$APS" 2>/dev/null
        # If generating the conf failed, do not touch hostapd. `ctl.restart` is a
        #   SIGKILL, so dropping it while the old conf is still in place gains nothing
        #   and merely loses DomA's only way in.
        #   The connect forward below (handing the real PSK to DomD, the only route to
        #   the real AP) MUST still run even if this fails. Do not return here.
        if write_hostapd_conf; then
            restart_hostapd
        else
            log "WARNING: could not update hostapd.conf, so hostapd is not restarted (the connect is still forwarded)"
        fi
    fi
    # Do not write `A && log ... || log ...` (see log() at the top).
    if printf '{"t":"connect","ssid":"%s","psk":"%s"}\n' "$(json_esc "$_s")" "$(json_esc "$_p")" >&3; then
        log "psk: forwarded connect($_s) to DomD"
        mirror_mark_write "$_s" "$_p"      # the mirror must not send this connect again
    else
        log "WARNING: could not write connect($_s) to $CHAN"
    fi
}

# --- boot-time mirror ------------------------------------------------------------------
# See the MIRROR_MARK block near the top for why this exists.
mirror_mark_write() {
    if printf '%s\t%s\t%s\n' "$BOOTID" "$1" "$2" > "$MIRROR_MARK.new" 2>/dev/null \
        && mv "$MIRROR_MARK.new" "$MIRROR_MARK" 2>/dev/null; then
        chmod 0600 "$MIRROR_MARK" 2>/dev/null
    else
        log "WARNING: cannot write $MIRROR_MARK (the mirror may forward again after a daemon restart)"
    fi
}

# mirror_marked <ssid> <psk> -- was exactly this connect already forwarded this boot?
mirror_marked() {
    [ -r "$MIRROR_MARK" ] || return 1
    _mb=""; _ms=""; _mp=""
    IFS="$TAB" read -r _mb _ms _mp < "$MIRROR_MARK" || return 1
    [ "$_mb" = "$BOOTID" ] && [ "$_ms" = "$1" ] && [ "$_mp" = "$2" ]
}

mirror_station() {
    [ "$(getprop persist.vendor.doma.wifi_relay_mirror 2>/dev/null)" != false ] || return 0
    [ -x "$IW" ] || return 0
    # Gate on the carrier bit before spawning iw: in the doma_shadow_ap domain
    # each iw exec logs ~8 avc denials (iw_exec execute/map,
    # netlink_generic_socket create/setopt), and running it on every 2 s tick
    # overran the audit rate limit on the board ("audit: rate limit exceeded").
    # iw runs only while the station has carrier and the SSID is not yet known,
    # i.e. once per association.
    if [ -r "$STA_CARRIER" ] && [ "$(cat "$STA_CARRIER" 2>/dev/null)" != 1 ]; then
        STA_LAST_SSID=""
        return 0
    fi
    [ -n "$STA_LAST_SSID" ] && return 0
    _ss=$(sta_link_ssid)
    if [ -z "$_ss" ]; then
        # Not associated: re-arm so the NEXT association is a fresh event (roaming to
        # another shadow SSID, or the framework cycling Wi-Fi).
        STA_LAST_SSID=""
        return 0
    fi
    [ "$_ss" = "$STA_LAST_SSID" ] && return 0
    STA_LAST_SSID=$_ss
    # No row, no connect. The shadow AP beacons only what $APS lists, so there is
    # no PSK to pair such a name with, and a connect with an empty one would make
    # DomD's agent replace its real network with an open one of that name.
    if ! _pk=$(psk_of "$_ss" 2>/dev/null); then
        log "mirror: station on $_ss, which aps.conf has no row for; not forwarding"
        return 0
    fi
    if [ "$_pk" = "$PLACEHOLDER_PSK" ]; then
        log "mirror: station on $_ss but aps.conf holds only the placeholder PSK; leaving it to the psk repair path"
        return 0
    fi
    if mirror_marked "$_ss" "$_pk"; then
        log "mirror: station on $_ss; connect already forwarded this boot"
        return 0
    fi
    # An empty $_pk is an open row of $APS.
    if [ -n "$_pk" ]; then _how=given; else _how=none; fi
    # Do not fold this into `A && log ... || log ...` (see log() at the top).
    if printf '{"t":"connect","ssid":"%s","psk":"%s"}\n' "$(json_esc "$_ss")" "$(json_esc "$_pk")" >&3; then
        log "mirror: station associated with $_ss -> forwarded connect($_ss) to DomD (psk $_how)"
        mirror_mark_write "$_ss" "$_pk"
    else
        log "WARNING: mirror: could not write connect($_ss) to $CHAN"
    fi
}

# --- main loop -----------------------------------------------------------------------
# 3<> so the same descriptor reads the agent's publications and writes the connect
# requests; virtio-serial is bidirectional on one node.
# DO NOT HANG `|| log FATAL` OFF `exec`. `exec` is a POSIX special builtin ("*=exec"
#   in mksh's external/mksh/src/funcs.c), and A FAILED REDIRECTION ONTO A SPECIAL
#   BUILTIN MAKES MKSH TERMINATE THE WHOLE SCRIPT (iosetup() failure in exec.c ->
#   errorfz() -> LERROR -> exit 1 for a non-interactive shell). In other words the
#   right-hand side of `||` never runs, and A MISCONFIGURED CHAN TURNS INTO THE
#   INSCRUTABLE SYMPTOM "restarting every 10 s without a single log line".
#   init then logs only `process with updatable components 'doma_wifi_relay'
#   exited 4 times in 4 minutes`. So TRY THE OPEN IN A SEPARATE PROCESS BEFORE
#   THE exec:
#   inside a subshell, even a special builtin's failure stays in the subshell.
if ! ( exec 3<> "$CHAN" ) 2>/dev/null; then
    log "FATAL: cannot open $CHAN read-write (check that it exists and whether it is an hvc or a vport node)"
    exit 1
fi
exec 3<> "$CHAN"

# RAW MODE. Without it BOTH directions break: DomD's publication and the connect
# requests this script sends. Established on the board 2026-09-22.
#
#   $CHAN is a virtconsole port, so Linux attaches a TTY to the hvc node, and a TTY
#   defaults to cooked with ECHO on:
#     (1) ECHO   the JSON DomD writes becomes input to the TTY and is echoed straight
#                back out to DomD. The agent then reads its own aps message, cut at
#                whatever TTY buffer boundary it hit, and says so every time:
#                  domd-wifi-agent: ignoring malformed line:
#                    b'{"t": "aps", "v": [{"ssid": "<SSID-WPA3>", ... "dbm": -43},'
#                The echo also occupies the line, so the agent's own writes back up:
#                  domd-wifi-agent: channel write failed (timed out); reconnecting
#                and OUR connect requests never reach it. The DomA side reports
#                  psk: forwarded connect(<SSID-B>) to DomD
#                while on the DomD side `wpa_cli list_networks` is empty and
#                wpa_state stays INACTIVE -- i.e. the AP list is right and the guest
#                still cannot get out.
#     (2) onlcr  LF on output becomes CRLF, which dirties the newline framing of the
#                newline-delimited JSON.
#     (3) icrnl  CR on input becomes LF. Together with (2) a line splits twice.
#     (4) icanon line editing is on, so ^C/^D/^U are interpreted as data. They do not
#                appear in the JSON, but they can appear in a PSK.
#
#   Applied to fd 3, NOT to the path. `stty -F "$CHAN"` works too, but that opens the
#   node a second time, and termios resets to the default on the last close -- which
#   produces the confusing state where typing stty by hand fixes it and the service
#   reopening the node breaks it again. Applied to fd 3 the setting lives as long as
#   the fd does.
#   NOT fatal. On a system without a working stty the JSON still flows (badly), and
#   exiting here would take DomA's Wi-Fi away entirely. Warn and carry on.
if stty raw -echo <&3 2>/dev/null; then
    log "chan: $CHAN set to raw/-echo"
else
    log "WARNING: chan: $CHAN could not be set raw; expect 'ignoring malformed line' and 'channel write failed' on the DomD side, and connect requests may not arrive"
fi

# END WHATEVER THE ECHO LEFT ON THE OTHER SIDE. Between the `exec 3<>` above and the
# stty, the TTY is still cooked with ECHO on, and the node has had no reader until
# this script opened it, so DomD's publications have queued up and part of them is
# echoed straight back. That fragment has no newline of its own: it waits in the
# agent's receive buffer and corrupts the next line that arrives. Measured on RPi4
# 2026-09-23 -- the session's one connect request reached DomD as
#     domd-wifi-agent: ignoring malformed line: b'{{"t":"connect",...}'
# DomD never associated, and DomA had Wi-Fi with no Internet. One newline ends
# the fragment as a line of its own, which the agent drops, so the first real
# request arrives clean. (The agent also recovers a message from behind such a
# fragment; this keeps the channel clean for an agent that does not.)
printf '\n' >&3 2>/dev/null || log "WARNING: chan: could not write the flushing newline to $CHAN"

log "started (chan=$CHAN aps=$APS req=$REQ)"

# Buffer that carries an incomplete line over. Details in the else branch below.
LINEBUF=""
# The last sta_is_up() answer, so the log line appears on a change only.
WIFI_UP_LAST=""
while :; do
    # 2 s so a request file dropped by the app is picked up promptly; the agent
    # publishes every 20 s so nothing is lost by not blocking on it.
    line=""
    if read -t 2 -r line <&3 2>/dev/null; then
        # Re-attach the incomplete part from the previous pass at the front
        line=$LINEBUF$line; LINEBUF=""
        # DISPATCH ON THE PARSED VALUE, NOT A SUBSTRING. The producer is
        # json.dumps() (main() in domd_wifi_agent.py), whose default separators
        # are (', ', ': '), so the wire format is {"t": "aps", "v": [...]} --
        # with a space after every colon -- and a pattern such as *'"t":"aps"'*
        # never matches it. This sed and the ssid extraction in handle_aps both
        # allow [[:space:]]* around the colon.
        _t=$(printf '%s' "$line" \
             | sed -n 's/.*"t"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')
        case "$_t" in
            # NOT WHILE doma_shadow_ap IS STILL RUNNING. init starts this daemon right
            # after it, and the publications DomD queued while nothing read $CHAN arrive
            # at once: handle_aps would then write $APS and hostapd.conf under the
            # oneshot's seed merge, and its restart would race the oneshot's ctl.start
            # (the flush below defers for the same reason). The next publication
            # is at most 20 s away.
            aps)   if [ "$(getprop init.svc.doma_shadow_ap 2>/dev/null)" = running ]; then
                       log "aps: doma_shadow_ap is still bringing the shadow AP up -- skipping this publication"
                   else
                       handle_aps "$line"
                   fi;;
            state) log "state: $line";;
            '')    [ -z "$line" ] || log "ignoring: $(printf '%s' "$line" | cut -c1-120)";;
            *)     log "ignoring type $_t";;
        esac
    else
        # EVEN ON TIMEOUT, `read` LEAVES WHAT IT MANAGED TO READ IN THE VARIABLE (both
        #   bash and mksh do). Discarding it here would LOSE A WHOLE PUBLICATION, with
        #   the remainder surfacing on the next pass as `ignoring: <fragment>`. DomD on
        #   the device emits one ~450 B line every 20 s, so this can happen any time a
        #   line straddles the 2 s window.
        #   Reproduced on the PC under mksh (not under bash): a publication cut
        #   by the timeout surfaced as `ignoring: <fragment>` and lost its
        #   SSIDs. => Carry it over and concatenate with the next read.
        if [ -n "${line:-}" ]; then
            LINEBUF=$LINEBUF$line
            # Do not grow without bound for a broken producer that emits no newline
            if [ ${#LINEBUF} -gt 65536 ]; then
                log "WARNING: the incomplete line exceeded 64 KiB, discarding it (the producer is not emitting newlines)"
                LINEBUF=""
            fi
        fi
    fi

    if sta_is_up; then _up=1; else _up=0; fi
    if [ "$_up" != "$WIFI_UP_LAST" ]; then
        if [ "$_up" = 1 ]; then
            log "wifi: $STA_IF is up (Settings toggle on) -- relaying to DomD"
        else
            log "wifi: $STA_IF is down (Settings toggle off) -- holding PSK requests; the AP list keeps syncing"
        fi
        WIFI_UP_LAST=$_up
    fi

    # A request stays in place while the toggle is off, and one left from the previous
    # boot waits for doma_shadow_ap to finish, as the publications above do: until then
    # wlan0 may not exist, so sta_is_up cannot tell, and handle_psk's restart would race
    # the oneshot's.
    if [ "$_up" = 1 ] && [ -s "$REQ" ] && [ "$(getprop init.svc.doma_shadow_ap 2>/dev/null)" != running ]; then
        # Move before reading so a request cannot be handled twice if hostapd's
        # restart takes longer than the poll interval.
        mv "$REQ" "$REQ.busy" 2>/dev/null || continue
        while IFS="$TAB" read -r verb a b; do
            case "$verb" in
                psk) [ -n "${a:-}" ] && handle_psk "$a" "${b:-}";;
                '')  ;;
                *)   log "unknown request verb: $verb";;
            esac
        done < "$REQ.busy"
        rm -f "$REQ.busy"
    fi

    mirror_station
    flush_pending_restart
done
