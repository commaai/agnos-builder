#!/usr/bin/env python3
"""
TEMPORARY: one-time import of NetworkManager's saved Wi-Fi networks into wpa_supplicant (wlan0.conf).
Delete this file, wifi-migrate.service (and the Wants= on it in wpa_supplicant-wlan0.service), the MIGRATE marker in
wpa_supplicant_prepare.sh and python3-yaml in base_setup.sh once no supported device can update from an AGNOS with
NetworkManager.

wifi-migrate.service runs it each time wpa_supplicant-wlan0 starts, while MIGRATE exists (wpa_supplicant_prepare.sh
creates it with a new, empty config). NM's files stay, so a rollback to an NM AGNOS keeps the networks it had.
Each network goes through SET_NETWORK, so wpa_supplicant validates it, and one it rejects or that isn't supported only
skips itself. Any other error (a control socket timeout, a disk error) leaves MIGRATE and nothing saved, so the next
start of wpa_supplicant imports everything again. Imported:
SSID, WPA-PSK password or open, hidden, metered (id_str, like openpilot). The hotspot's SSID and password go to
openpilot's params (TetheringSsid, TetheringPassword) unless they're set. Not imported: WEP, enterprise, SAE/OWE
(openpilot can only create WPA-PSK and open networks).
"""
import glob
import os
import re
import socket
import tempfile
import time

import yaml

MIGRATE = "/data/etc/wpa_supplicant/migrate-from-networkmanager"
PARAMS = "/data/params"
METERED = {"1": "metered", "2": "unmetered"}  # NM_METERED_YES / NO
WS = " \t\n\v\f\r"  # GLib's ASCII whitespace
GKEYFILE_ESCAPES = {"s": " ", "n": "\n", "t": "\t", "r": "\r", "\\": "\\"}


def ctrl(cmd: str) -> str:
  with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as s:
    s.settimeout(5)
    s.bind(f"\0wifi_migrate-{os.getpid()}-{time.monotonic_ns()}")
    s.connect("/run/wpa_supplicant/wlan0")
    s.send(cmd.encode())
    reply = s.recv(4096).decode().strip()
  if reply.startswith("FAIL"):
    raise RuntimeError(f"{cmd.partition(' psk ')[0]} failed")
  return reply


def nm_ssid(value: str) -> bytes:
  # NM saves an SSID that isn't all printable ASCII as a list of its bytes ("99;97;102;195;169;"), any other as a
  # string with its ';' escaped. Read like NM's keyfile get_bytes()
  if re.fullmatch(f"([{WS}]*[0-9]{{1,3}}[{WS}]*;)+[{WS}]*", value):
    values = [int(n) for n in re.findall("[0-9]+", value)]
    if max(values) < 256:
      return bytes(values)
  return value.replace("\\;", ";").encode()


def gkeyfile_string(value: str) -> str:
  # like GLib's g_key_file_get_string()
  def unescape(m: re.Match) -> str:
    if m[1] not in GKEYFILE_ESCAPES:
      raise ValueError("invalid escape")
    return GKEYFILE_ESCAPES[m[1]]
  return re.sub(r"\\(.?)", unescape, value, flags=re.DOTALL)


def keyfile(path: str):
  kf, groups, group = {}, set(), ""
  for line in open(path, encoding="utf-8", newline="").read().split("\n"):
    line = line.removesuffix("\r").lstrip(WS)  # values keep their trailing spaces
    if line.startswith("["):
      group = line.rstrip(WS)[1:-1]
      group = {"802-11-wireless": "wifi", "802-11-wireless-security": "wifi-security"}.get(group, group)
      groups.add(group)
    elif "=" in line and not line.startswith("#"):
      k, v = line.split("=", 1)
      kf[f"{group}.{k.rstrip(WS)}"] = v.lstrip(WS)
  if "wifi.ssid" not in kf:
    return  # not Wi-Fi

  def get(key: str) -> str:
    return gkeyfile_string(kf.get(key, ""))
  # no security settings is an open network; any but WPA-PSK isn't supported
  security = (get("wifi-security.key-mgmt") or "unknown") if "wifi-security" in groups else None
  yield nm_ssid(get("wifi.ssid")), get("wifi.mode") or None, security, get("wifi-security.psk"), \
    kf.get("wifi.hidden", "").rstrip(WS) in ("true", "1"), kf.get("connection.metered", "").strip(WS)


def netplan(path: str):
  # AGNOS 20.x's NetworkManager saves networks as netplan YAML instead, with each SSID as NM saves it. Everything is
  # read as a string, like netplan does (an SSID like 0123 or yes stays as it is)
  config = yaml.load(open(path, encoding="utf-8"), Loader=yaml.BaseLoader)
  for wifi in config["network"].get("wifis", {}).values():
    for ssid, ap in wifi.get("access-points", {}).items():
      auth = ap.get("auth", {})
      nm = ap.get("networkmanager") or wifi.get("networkmanager") or {}
      passthrough = nm.get("passthrough", {})
      key_mgmt = auth.get("key-management", "none")
      security = {"psk": "wpa-psk", "none": None}.get(key_mgmt, key_mgmt)
      # netplan has no WEP or OWE, it passes NM's settings for them through
      if security is None and any(k.startswith("wifi-security.") for k in passthrough):
        security = passthrough.get("wifi-security.key-mgmt", "unknown")
      yield nm_ssid(ssid), ap.get("mode"), security, auth.get("password", ""), \
        ap.get("hidden", "").lower() in ("true", "yes", "on", "y", "1"), passthrough.get("connection.metered")


def put_param(key: str, value: str) -> None:
  # like openpilot's Params.put, owned by openpilot's user
  if not os.path.isdir(f"{PARAMS}/d"):
    raise ValueError("no openpilot params")
  path = f"{PARAMS}/d/{key}"
  if os.path.exists(path):
    return
  st = os.stat(PARAMS)
  fd, tmp = tempfile.mkstemp(dir=PARAMS, prefix=".tmp_value_")
  try:
    os.write(fd, value.encode())
    os.fchown(fd, st.st_uid, st.st_gid)
    os.fsync(fd)
  finally:
    os.close(fd)
  os.rename(tmp, path)
  fd = os.open(f"{PARAMS}/d", os.O_RDONLY)
  try:
    os.fsync(fd)
  finally:
    os.close(fd)


def network(ssid: bytes, mode, security, psk: str, hidden: bool, metered) -> dict[str, str]:
  if mode not in (None, "infrastructure"):
    raise ValueError(f"unsupported mode {mode}")
  conf = {"ssid": ssid.hex()}
  if security == "wpa-psk":
    # 64 hex digits are the key itself, anything else a passphrase (wpa_supplicant checks either)
    conf.update(key_mgmt="WPA-PSK WPA-PSK-SHA256", psk=psk if len(psk) == 64 else f'"{psk}"')
  elif security is None:
    conf["key_mgmt"] = "NONE"
  else:
    raise ValueError(f"unsupported security {security}")
  if hidden:
    conf["scan_ssid"] = "1"
  if metered in METERED:
    conf["id_str"] = f'"{METERED[metered]}"'
  return conf


def import_network(ssid: bytes, mode, security, psk: str, hidden: bool, metered) -> None:
  if mode == "ap":
    put_param("TetheringSsid", ssid.decode())
    if psk:
      put_param("TetheringPassword", psk)
    return
  conf = network(ssid, mode, security, psk, hidden, metered)
  net_id = ctrl("ADD_NETWORK")  # added disabled
  try:
    for k, v in conf.items():
      ctrl(f"SET_NETWORK {net_id} {k} {v}")
  except RuntimeError:
    ctrl(f"REMOVE_NETWORK {net_id}")
    raise
  ctrl(f"ENABLE_NETWORK {net_id}")


def saved_ssids() -> set[bytes]:
  ssids = set()
  for line in ctrl("LIST_NETWORKS").splitlines()[1:]:
    try:
      ssid = ctrl(f"GET_NETWORK {line.split(chr(9))[0]} ssid")  # "text" or hex
    except RuntimeError:
      continue  # no SSID yet: another client is adding it
    ssids.add(ssid[1:-1].encode() if ssid.startswith('"') else bytes.fromhex(ssid))
  return ssids


def main() -> None:
  for _ in range(600):  # wpa_supplicant opens its control socket once it's up, after waiting up to 30s for wlan0
    try:
      ctrl("PING")
      break
    except OSError:
      time.sleep(0.1)

  files = [(keyfile, p) for p in sorted(glob.glob("/data/etc/NetworkManager/system-connections/*.nmconnection"))] + \
          [(netplan, p) for p in sorted(glob.glob("/data/etc/netplan/90-NM-*.yaml"))]
  # an SSID that was saved before this run (an interrupted import, or openpilot got there first) is left as it is.
  # Two NetworkManager profiles for one SSID are both imported, and wpa_supplicant tries each, like NetworkManager did
  saved = saved_ssids()
  for parse, path in files:
    try:
      networks = list(parse(path))
    except OSError:
      raise  # try again next start
    except Exception as e:
      print(f"skipped {path}: {e}")
      continue
    for n in networks:
      name = n[0].decode(errors="backslashreplace")
      if n[1] != "ap" and n[0] in saved:
        print(f"skipped {name} from {path}: already saved")
        continue
      try:
        import_network(*n)
        print(f"imported {name} from {path}")
      except (ValueError, RuntimeError) as e:  # not supported, or wpa_supplicant rejected it
        print(f"skipped {name} from {path}: {e}")
  ctrl("SAVE_CONFIG")
  os.unlink(MIGRATE)


if __name__ == "__main__":
  main()
