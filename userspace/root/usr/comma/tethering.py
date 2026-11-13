#!/usr/bin/env python3
"""
The Wi-Fi hotspot, a wpa_supplicant of its own on wlan0. AGNOS owns it: openpilot only sets its params
(/data/params/d): TetheringSsid, TetheringPassword, TetheringShareInternet (IPv4 forwarding) and TetheringEnabled.
boot.sh deletes TetheringEnabled (the hotspot doesn't survive a reboot), so it's "1" only while openpilot wants it.

  tethering.py watch    tethering-param-watcher.service: keeps tethering.service in line with the params
  tethering.py start    tethering.service: wlan0's address, then as reload
  tethering.py reload   tethering.service: the hotspot's wpa_supplicant config, forwarding and NAT
  tethering.py stop     tethering.service: remove the address, forwarding and NAT
"""
import ctypes
import hashlib
import os
import string
import struct
import subprocess
import sys

IFACE = "wlan0"
PARAMS = "/data/params/d"
CONF = "/run/tethering/wlan0.conf"  # RuntimeDirectory=tethering
KEYS = ["TetheringEnabled", "TetheringSsid", "TetheringPassword", "TetheringShareInternet"]
TETHER_IP = "192.168.43.1"
TETHER_NET = "192.168.43.0/24"
RULES = [
  ("nat", "POSTROUTING", "-s", TETHER_NET, "!", "-o", IFACE, "-j", "MASQUERADE"),
  ("filter", "FORWARD", "-i", IFACE, "-s", TETHER_NET, "-j", "ACCEPT"),
  ("filter", "FORWARD", "-o", IFACE, "-d", TETHER_NET, "-m", "state", "--state", "RELATED,ESTABLISHED", "-j", "ACCEPT"),
  # nothing else through the hotspot, either way, like NetworkManager's shared mode
  ("filter", "FORWARD", "-i", IFACE, "-j", "REJECT"),
  ("filter", "FORWARD", "-o", IFACE, "-j", "REJECT"),
]
IN_CLOSE_WRITE, IN_MOVED_TO, IN_DELETE, IN_Q_OVERFLOW, IN_IGNORED = 0x8, 0x80, 0x200, 0x4000, 0x8000


def param(key: str) -> str:
  try:
    with open(f"{PARAMS}/{key}", "rb") as f:
      return f.read(100).decode()  # longer than any valid value
  except (FileNotFoundError, UnicodeDecodeError):
    return ""


def config() -> str:
  ssid, password = param("TetheringSsid").encode(), param("TetheringPassword")
  if not 1 <= len(ssid) <= 32:
    raise ValueError("TetheringSsid isn't 1-32 bytes")
  # a WPA passphrase is 8-63 printable ASCII characters; 64 hex digits are the key itself, which a hotspot imported
  # from NetworkManager can have. Both are written as the key, so no character needs quoting
  if len(password) == 64 and all(c in string.hexdigits for c in password):
    psk = password
  elif 8 <= len(password) <= 63 and password.isascii() and password.isprintable():
    psk = hashlib.pbkdf2_hmac("sha1", password.encode(), ssid, 4096, 32).hex()
  else:
    raise ValueError("TetheringPassword isn't a WPA password")
  # the client's control socket (wlan0-globals.conf), where STATUS now says mode=AP. No update_config: there's nothing
  # to save. Channel 6, 2.4 GHz like NetworkManager's "bg" band
  return f"""ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
p2p_disabled=1
network={{
\tmode=2
\tssid={ssid.hex()}
\tfrequency=2437
\tkey_mgmt=WPA-PSK
\tproto=RSN
\tpairwise=CCMP
\tgroup=CCMP
\tpsk={psk}
}}
"""


def firewall(rules: list[tuple[str, ...]]) -> None:
  # remove ours, as many times as a stop that didn't finish left them, then add these in order
  for table, *rule in RULES:
    while subprocess.run(["iptables", "-w", "10", "-t", table, "-D", *rule], stderr=subprocess.DEVNULL).returncode == 0:
      pass
  for table, *rule in rules:
    subprocess.run(["iptables", "-w", "10", "-t", table, "-A", *rule], check=True)


def start() -> None:
  # the client's wpa_supplicant and DHCP have stopped (Conflicts=), so wlan0 is ours to address
  subprocess.run(["ip", "-4", "addr", "flush", "dev", IFACE], check=True)
  subprocess.run(["ip", "addr", "add", f"{TETHER_IP}/24", "dev", IFACE], check=True)
  reload()


def reload() -> None:
  with open(CONF, "w") as f:
    f.write(config())
  forward = "1" if param("TetheringShareInternet") == "1" else "0"
  subprocess.run(["sysctl", "-q", f"net.ipv4.ip_forward={forward}"], check=True)
  firewall(RULES)


def stop() -> None:
  # best effort; the client gets wlan0 back next (tethering.service)
  subprocess.run(["sysctl", "-q", "net.ipv4.ip_forward=0"])
  firewall([])
  subprocess.run(["ip", "-4", "addr", "flush", "dev", IFACE])


def running() -> bool:
  state = subprocess.run(["systemctl", "is-active", "tethering.service"], capture_output=True, text=True).stdout.strip()
  return state in ("active", "activating", "reloading")


def watch() -> None:
  # tethering-param-watcher.path starts this once TetheringEnabled exists. From then on, whenever they're written:
  # - TetheringEnabled "1" starts tethering.service, anything else stops it
  # - an SSID, password or sharing change reloads it, or starts it if it's stopped
  # A hotspot that stopped on its own (it failed, or wpa_supplicant or dnsmasq died) stays off until a param changes
  # or TetheringEnabled is written "1" again. Params it can't start with stop it instead: starting it stops the client
  libc = ctypes.CDLL(None, use_errno=True)
  fd = libc.inotify_init1(os.O_CLOEXEC)
  if fd < 0 or libc.inotify_add_watch(fd, PARAMS.encode(), IN_CLOSE_WRITE | IN_MOVED_TO | IN_DELETE) < 0:
    raise OSError(ctypes.get_errno(), "inotify")
  started = None  # the params tethering.service was last started with
  written = set(KEYS)  # the path unit started this because TetheringEnabled was written
  while True:
    want = [param(k) for k in KEYS]
    if want[0] != "1":
      started = None
      subprocess.run(["systemctl", "stop", "tethering.service"])
      subprocess.run(["systemctl", "reset-failed", "tethering.service"])  # a hotspot that died is off now, not a failure
    elif want != started or ("TetheringEnabled" in written and not running()):
      started = want
      try:
        config()
        subprocess.run(["systemctl", "reload-or-restart", "tethering.service"])
      except ValueError as e:
        print(e)
        subprocess.run(["systemctl", "stop", "tethering.service"])

    # wait for the next writes of them; any made meanwhile are queued already
    written = set()
    while not written:
      events, i = os.read(fd, 4096), 0
      while i < len(events):  # struct inotify_event
        _, mask, _, length = struct.unpack_from("iIII", events, i)
        if mask & IN_IGNORED:
          return  # the params directory is gone; the path unit starts this again once TetheringEnabled exists
        name = events[i + 16:i + 16 + length].rstrip(b"\0").decode()
        written |= set(KEYS) if mask & IN_Q_OVERFLOW else {name} & set(KEYS)
        i += 16 + length


if __name__ == "__main__":
  {"watch": watch, "start": start, "reload": reload, "stop": stop}[sys.argv[1]]()
