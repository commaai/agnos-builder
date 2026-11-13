# Wi-Fi

AGNOS keeps Wi-Fi up as root, with no openpilot process running. openpilot decides what to join, over
wpa_supplicant's control socket, and drives the hotspot through params. openpilot, and the setup, reset and
updater apps frozen into each AGNOS, all depend on what's below, so change it only in ways old clients
still work with.

## Contract

- **Socket**: `/run/wpa_supplicant/wlan0`, group `netdev` (`comma` is a member). It goes away whenever
  wpa_supplicant stops (restart, crash, hotspot on or off), so a client reconnects and uses no network id from
  before.
- **Saved networks**: `/data/etc/wpa_supplicant/wlan0.conf`, root 0600. Only wpa_supplicant writes it
  (`SAVE_CONFIG`). The writer replies FAIL and keeps the old file when it can't write all of it (a full /data),
  and any SSID, id_str or passphrase accepted over the socket reads back as it was. Before each start AGNOS:
  - drops `disabled=1` lines, so every saved network starts enabled;
  - moves a file wpa_supplicant can't parse to `wlan0.conf.unreadable` and starts with no networks (a last
    resort: a later unreadable file overwrites the one set aside before);
  - adds its globals (`/etc/wpa_supplicant/wlan0-globals.conf`) with `-I`, so they win over saved copies.
- **id_str**: `""`, `"metered"` or `"unmetered"` on saved networks (`hardware.py` reads it from `STATUS`).
  `openpilot-new` marks a network openpilot is trying; any left over belongs to no one and openpilot
  removes it.
- **Wrong password**: wpa_supplicant marks the network `[TEMP-DISABLED]` in `LIST_NETWORKS`; a client checks that
  after `CTRL-EVENT-SSID-TEMP-DISABLED reason=WRONG_KEY`, since wpa_supplicant also reports that when it leaves a
  network itself (stopping mid-handshake).
- **priority**: openpilot keeps the SSID it last picked or is on at 1 and the rest at 0. AGNOS never sets one.
- **No bgscan**: the firmware roams between access points of one network. Moving to another saved SSID takes
  a scan that goes to network selection.
- **Hotspot params** (`/data/params/d`, written by openpilot only): `TetheringSsid` (1-32 bytes),
  `TetheringPassword` (8-63 printable ASCII, or 64 hex digits), `TetheringShareInternet` (`1` = forward to the
  uplink), `TetheringEnabled` (`1` = on; anything else or missing = off). boot.sh deletes `TetheringEnabled`.
- **Hotspot**: `tethering.service` is a wpa_supplicant of its own on wlan0, on the same socket. While it runs:
  - the client (`wpa_supplicant-wlan0`, `dhcpcd-wlan0`) is stopped, and starts again however the hotspot stops;
  - `STATUS` says `mode=AP` and the hotspot's SSID once the AP is up. Its one network has `mode=2`
    (`GET_NETWORK <id> mode`) from the start, which is how a client tells the two apart; the client never has one;
  - send it nothing that changes networks, saves or scans. openpilot shows the saved networks it last read from the
    client, and forgetting one or changing metered does nothing until the hotspot is off;
  - wlan0 is 192.168.43.1/24, dnsmasq hands out .10-.254, NAT to the default route if sharing is on.
  `tethering-param-watcher` follows the params: on when `TetheringEnabled` is written `1` (AP up in ~3 s), off when
  it turns anything else, and a reload (same socket, ~3 s) when the SSID, password or sharing change. Params it
  can't use turn the hotspot off; they never stop the client. A hotspot that stops on its own stays off until a
  param changes or `TetheringEnabled` is written `1` again. AGNOS doesn't write any `Tethering*` param, so
  openpilot sets `TetheringEnabled=0` itself.
- **NetworkManager**: on the first start without it, its saved networks are imported (`wifi_migrate.py`) and its
  files left in place. An older AGNOS (the other slot) only has the networks NetworkManager had then.
- **Routes**: Ethernet metric 100, Wi-Fi 600 (2000600 while it roams), LTE 2001000 (`modem.py`).

## Wi-Fi doesn't work

1. `systemctl status wpa_supplicant-wlan0 dhcpcd-wlan0 tethering tethering-param-watcher` and
   `journalctl -b -u wpa_supplicant-wlan0 -u dhcpcd-wlan0 -u tethering`. No wlan0 means the firmware didn't
   come up: `journalctl -b -u wifi`.
2. `wpa_cli -i wlan0 status` (`mode=AP` means the hotspot is on; `cat /data/params/d/Tethering*`, and turn it
   off or on by writing `TetheringEnabled`: `systemctl restart tethering` ends with the client) and
   `wpa_cli -i wlan0 list_networks`. A saved network that's `[TEMP-DISABLED]` had a wrong password or kept failing.
3. `ls /data/etc/wpa_supplicant/`: a `wlan0.conf.unreadable` means the saved networks were set aside.
4. `ip -4 addr show wlan0`, `ip route`: no address with `wpa_state=COMPLETED` means DHCP (`dhcpcd-wlan0` log).
5. DNS: `resolvectl status`; Wi-Fi's servers are in `/run/systemd/resolved.conf.d/dhcpcd-wlan0.conf`.
