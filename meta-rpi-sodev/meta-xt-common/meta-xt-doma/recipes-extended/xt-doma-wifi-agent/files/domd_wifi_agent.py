#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""DomD side of the shadow-AP Wi-Fi bridge for DomA.

DomD owns the only real radio on the board. DomA does not get it: its devices
are qemu device models, and its wlan0 has to be one that WifiService manages. So
DomA simulates its radios with mac80211_hwsim and beacons the SSIDs this agent
reports, and this agent performs the real association on DomA's behalf.

TRANSPORT
A qemu virtio-serial chardev, not vsock and not TCP: doma.cfg's virts5, a UNIX
socket qemu listens on (server=on,wait=off). Chosen over the alternatives
because it needs no IP, no routing rules (DomA's policy routing sends unmarked
traffic to a different interface) and no kernel module. This side is the CLIENT.
It must be SOCK_STREAM -- SOCK_SEQPACKET fails to connect against a qemu
chardev, which gnss_replay.py records as well.

PROTOCOL -- one JSON object per line, both directions:
    ->  {"t":"aps","v":[{"ssid":..,"bssid":..,"sec":"wpa2"|"wpa"|"open",
                         "freq":2462,"dbm":-59}, ..]}
    <-  {"t":"connect","ssid":"<SSID-A>","psk":"..."}
    ->  {"t":"state","ssid":..,"state":"COMPLETED","ip":"<from the AP's DHCP>"}

WPA_SUPPLICANT
Spoken to directly over its control socket. wpa_cli is not in the DomD image and
python3 is, so there is nothing to add. The control interface is
AF_UNIX/SOCK_DGRAM and the client must bind its own path first, which is why a
plain connect() is not enough.

The network connect_real_ap() adds keeps wpa_supplicant's default key_mgmt
(WPA-PSK and IEEE8021X) for a passphrase and sets NONE without one, and it
never carries a WEP key, so an AP that offers SAE only (WPA3-Personal without
the WPA2 transition mode), EAP only, OWE or WEP cannot be joined.
parse_scan_results() does not publish one.

SECURITY, STATED PLAINLY
A passphrase typed on the AAOS screen travels this channel in the clear, because
the shadow AP cannot learn a PSK from a 4-way handshake -- only a MIC crosses
the air. Lab use only; do not ship it to a vehicle.
"""

import argparse
import json
import os
import re
import signal
import socket
import subprocess
import sys
import time

LOG_PREFIX = "domd-wifi-agent:"


def log(*a):
    print(LOG_PREFIX, *a, flush=True)


class Supplicant:
    """Minimal wpa_supplicant control-interface client."""

    def __init__(self, path, timeout=5.0):
        self.path = path
        self.timeout = timeout
        self.local = "/tmp/domd_wifi_agent_%d" % os.getpid()
        self.sock = None

    def open(self):
        # The control interface is a datagram socket and it replies to the client's bound
        # address, so the client has to have one. Without the bind, sendto() works and
        # recv() then blocks forever.
        if os.path.exists(self.local):
            os.unlink(self.local)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.sock.bind(self.local)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)

    def close(self):
        if self.sock:
            self.sock.close()
            self.sock = None
        if os.path.exists(self.local):
            try:
                os.unlink(self.local)
            except OSError:
                pass

    def cmd(self, text):
        self.sock.send(text.encode())
        # Unsolicited events are only delivered after ATTACH, which this agent never
        # sends, so the next datagram is the reply to this command.
        return self.sock.recv(65536).decode("utf-8", "replace")


def unescape_ssid(s):
    """Undo wpa_supplicant's printf_encode() so the real bytes can be inspected."""
    BS = chr(92)
    out, i, n = bytearray(), 0, len(s)
    simple = {"n": 10, "r": 13, "t": 9, "e": 27, BS: 92, '"': 34}
    while i < n:
        c = s[i]
        if c != BS or i + 1 >= n:
            out += c.encode("utf-8", "replace")
            i += 1
            continue
        e = s[i + 1]
        if e == "x" and i + 3 < n:
            try:
                out.append(int(s[i + 2:i + 4], 16))
                i += 4
                continue
            except ValueError:
                pass
        if e in simple:
            out.append(simple[e])
        else:
            out += (BS + e).encode("utf-8", "replace")
        i += 2
    return bytes(out)


def ssid_is_usable(ssid):
    """True if this SSID can be carried through hostapd.conf on the DomA side.

    Rejects the empty SSID (hidden AP), anything containing NUL or other control bytes
    -- an AP in range beacons 20 NUL bytes and hostapd refuses its whole config over it,
    which takes out all of DomA's Wi-Fi -- and anything that is not valid UTF-8 or is
    longer than the 32-byte 802.11 limit.
    """
    raw = unescape_ssid(ssid)
    if not raw or len(raw) > 32:
        return False
    if any(b < 0x20 or b == 0x7F for b in raw):
        return False
    try:
        raw.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return True


# "bssid / frequency / signal level / flags / ssid", tab separated, one header line.
def parse_scan_results(text):
    out = []
    for line in text.splitlines()[1:]:
        f = line.split("\t")
        if len(f) < 5:
            continue
        bssid, freq, sig, flags, ssid = f[0], f[1], f[2], f[3], f[4]
        if not ssid:
            continue          # hidden SSID: nothing to show on a picker
        if not ssid_is_usable(ssid):
            # Not cosmetic: DomA writes what this agent publishes into
            # hostapd.conf, and hostapd rejects the whole file over one bad
            # SSID, which kills the shadow AP and with it all of DomA's Wi-Fi.
            # Seen with an AP beaconing NUL bytes.
            log("skipping unusable SSID %r" % ssid)
            continue
        if ("WPA" in flags or "RSN" in flags) and "PSK" not in flags:
            # SAE only, EAP or OWE: connect_real_ap() cannot join it (see
            # WPA_SUPPLICANT above), so DomA is not offered it.
            log("skipping %r: no PSK key management (%s)" % (ssid, flags))
            continue
        if "WEP" in flags:
            # A WEP AP carries no WPA or RSN flag, so the check above lets it
            # through and it would go out as "open". The DomA relay would then
            # beacon it as WPA2 and forward the key the user types as a WPA
            # passphrase, and connect_real_ap() cannot join WEP (see
            # WPA_SUPPLICANT above).
            log("skipping %r: WEP (%s)" % (ssid, flags))
            continue
        try:
            freq_i, sig_i = int(freq), int(sig)
        except ValueError:
            continue
        if "WPA2" in flags or "RSN" in flags:
            sec = "wpa2"
        elif "WPA" in flags:
            sec = "wpa"
        else:
            sec = "open"
        # Published as text, not as SCAN_RESULTS prints it: that is
        # printf-escaped (\xNN for every byte outside printable ASCII), and DomA
        # writes the value into hostapd.conf byte for byte, so the escaped form
        # would beacon another name. ssid_is_usable() has already checked that
        # it decodes.
        out.append({"ssid": unescape_ssid(ssid).decode("utf-8"), "bssid": bssid,
                    "sec": sec, "freq": freq_i, "dbm": sig_i})
    return out


def top_n(aps, n):
    """Strongest BSS per SSID, strongest SSIDs first.

    Deduplicated by SSID because an AP with several radios or several band-specific BSSes
    would otherwise fill the whole list with one network -- on the board under test a
    single scan returned 69 BSSes for far fewer distinct names.
    """
    best = {}
    for a in aps:
        cur = best.get(a["ssid"])
        if cur is None or a["dbm"] > cur["dbm"]:
            best[a["ssid"]] = a
    return sorted(best.values(), key=lambda a: -a["dbm"])[:n]


def psk_arg(psk):
    """Argument for SET_NETWORK psk, or None if wpa_supplicant would refuse it.

    64 hex digits are a raw PSK and go in unquoted; anything else is a
    passphrase, which wpa_supplicant takes quoted, at 8..63 bytes and without
    control characters. It prints a passphrase it refuses into its log, so such
    a value is not sent at all.
    """
    if len(psk) == 64 and all(c in "0123456789abcdefABCDEF" for c in psk):
        return psk
    raw = psk.encode("utf-8")
    if 8 <= len(raw) <= 63 and not any(b < 0x20 or b == 0x7F for b in raw):
        return '"%s"' % psk
    return None


def connect_real_ap(sup, ssid, psk):
    """Associate DomD's radio with a real AP and pick up a lease."""
    arg = psk_arg(psk) if psk else None
    if psk and arg is None:
        return False, "psk is neither 8..63 bytes nor 64 hex digits"
    # One network at a time: nothing else adds networks (the config file has
    # none), and without this every connect request would leave one more behind.
    sup.cmd("REMOVE_NETWORK all")
    nid = sup.cmd("ADD_NETWORK").strip()
    if not nid.isdigit():
        return False, "ADD_NETWORK -> %r" % nid
    steps = ['SET_NETWORK %s ssid "%s"' % (nid, ssid)]
    if arg:
        steps.append("SET_NETWORK %s psk %s" % (nid, arg))
    else:
        steps.append("SET_NETWORK %s key_mgmt NONE" % nid)
    steps.append("SELECT_NETWORK %s" % nid)
    for s in steps:
        r = sup.cmd(s).strip()
        if r != "OK" and not s.startswith("SELECT"):
            return False, "%s -> %r" % (s.split()[0], r)
    return True, nid


def wait_state(sup, want="COMPLETED", secs=30):
    end = time.time() + secs
    last = ""
    while time.time() < end:
        st = dict(
            kv.split("=", 1)
            for kv in sup.cmd("STATUS").splitlines()
            if "=" in kv
        )
        last = st.get("wpa_state", "")
        if last == want:
            return last, st.get("ip_address", "")
        time.sleep(1)
    return last, ""


UDHCPC_PID = "/run/domd-wifi-agent.udhcpc.pid"


def dhcp(iface):
    """Take a lease on iface with busybox's udhcpc, and keep it renewed.

    Without -q, udhcpc forks into the background once it holds the lease and
    renews it from there; -n makes it exit instead when no lease comes. The
    udhcpc of the previous association is stopped first, so only one runs.
    """
    try:
        with open(UDHCPC_PID) as f:
            os.kill(int(f.read().strip()), signal.SIGTERM)
    except (OSError, ValueError):
        pass
    try:
        subprocess.run(["udhcpc", "-i", iface, "-n", "-t", "6", "-T", "3",
                        "-p", UDHCPC_PID], timeout=60, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:                                    # noqa: BLE001
        log("dhcp on %s failed: %s" % (iface, e))
    try:
        out = subprocess.run(["ip", "-o", "-4", "addr", "show", iface],
                             capture_output=True, text=True, timeout=10).stdout
        m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", out)
        return m.group(1) if m else ""
    except Exception:                                         # noqa: BLE001
        return ""


def parse_line(line):
    """One newline-delimited JSON message from DomA, or None.

    A line can arrive with a fragment glued to its front. The DomA relay opens its
    virtconsole node and only then switches it to raw mode, so for a moment the TTY
    is cooked with ECHO on and sends part of what this agent had already written
    straight back. That fragment has no newline of its own and prefixes the next
    real line. Measured on RPi4 2026-09-23: the one connect request of a session
    arrived as b'{{"t":"connect",...}' and was dropped, so DomD never associated and
    DomA had Wi-Fi with no Internet. Every message this protocol carries starts with
    {"t", so when the whole line does not parse, retry from the last one.
    """
    try:
        return json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        pass
    i = line.rfind(b'{"t"')
    if i > 0:
        try:
            req = json.loads(line[i:].decode("utf-8", "replace"))
        except ValueError:
            pass
        else:
            log("recovered a message after dropping %d leading byte(s): %r"
                % (i, _redact(line[:i])[:40]))
            return req
    log("ignoring malformed line: %r" % _redact(line)[:120])
    return None


def _redact(b):
    """A connect request may be in the line: keep its passphrase out of the log.

    The value is matched as a JSON string, escapes included: the relay escapes a
    quote or a backslash in a passphrase, and a pattern that stopped at the
    first quote would let the rest through.
    """
    return re.sub(rb'("psk"\s*:\s*")(?:\\.|[^"\\])*', rb'\1<redacted>', b)


def connect_channel(path, tries=0):
    """Connect to the qemu-created socket, retrying while it is absent."""
    n = 0
    while True:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(path)
            return s
        except OSError as e:
            n += 1
            if tries and n >= tries:
                raise
            if n == 1 or n % 30 == 0:
                log("channel %s not ready (%s); retrying" % (path, e))
            time.sleep(2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-s", "--socket", default="/run/android_vm_virtconsole5",
                    help="qemu virtio-serial chardev socket (DomA side is /dev/hvc4)")
    ap.add_argument("-c", "--ctrl", default="/run/wpa_supplicant/wlan0")
    ap.add_argument("-i", "--iface", default="wlan0")
    ap.add_argument("-n", "--top", type=int, default=8,
                    help="how many SSIDs to publish (strongest first)")
    ap.add_argument("--interval", type=float, default=20.0,
                    help="seconds between scans")
    args = ap.parse_args()

    sup = Supplicant(args.ctrl)
    try:
        sup.open()
    except OSError as e:
        log("cannot open %s: %s -- is wpa_supplicant running on %s?"
            % (args.ctrl, e, args.iface))
        return 1
    log("wpa_supplicant ctrl %s: %s" % (args.ctrl, sup.cmd("PING").strip()))

    chan = connect_channel(args.socket)
    log("channel connected: %s" % args.socket)
    chan.settimeout(0.5)

    rx = b""
    next_scan = 0.0
    while True:
        now = time.time()
        if now >= next_scan:
            next_scan = now + args.interval
            sup.cmd("SCAN")
            time.sleep(3)          # give the radio time before reading results
            aps = top_n(parse_scan_results(sup.cmd("SCAN_RESULTS")), args.top)
            msg = json.dumps({"t": "aps", "v": aps}, ensure_ascii=False)
            try:
                chan.sendall((msg + "\n").encode())
            except OSError as e:
                log("channel write failed (%s); reconnecting" % e)
                chan.close()
                chan = connect_channel(args.socket)
                chan.settimeout(0.5)
                continue
            log("published %d SSID(s): %s"
                % (len(aps), ", ".join(a["ssid"] for a in aps)))

        try:
            b = chan.recv(65536)
            if not b:
                raise OSError("channel closed by peer")
            rx += b
        except socket.timeout:
            continue
        except OSError as e:
            log("channel read failed (%s); reconnecting" % e)
            chan.close()
            chan = connect_channel(args.socket)
            chan.settimeout(0.5)
            rx = b""
            continue

        while b"\n" in rx:
            line, rx = rx.split(b"\n", 1)
            line = line.strip()
            if not line:
                continue
            req = parse_line(line)
            if req is None:
                continue
            if req.get("t") != "connect":
                continue
            ssid, psk = req.get("ssid", ""), req.get("psk", "")
            if not ssid:
                continue
            log("connect request for %r (psk %s)"
                % (ssid, "given" if psk else "none"))
            ok, info = connect_real_ap(sup, ssid, psk)
            if not ok:
                reply = {"t": "state", "ssid": ssid, "state": "FAILED",
                         "error": info}
            else:
                state, ip = wait_state(sup)
                if state == "COMPLETED" and not ip:
                    ip = dhcp(args.iface)
                reply = {"t": "state", "ssid": ssid, "state": state, "ip": ip}
            log("result: %s" % reply)
            try:
                chan.sendall((json.dumps(reply) + "\n").encode())
            except OSError:
                pass
            # A fresh association changes what is worth reporting.
            next_scan = 0.0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        pass
