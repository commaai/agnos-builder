# testing

## Release Checklist

- [ ] [`test_onroad`](https://github.com/commaai/openpilot/blob/master/selfdrive/test/test_onroad.py) passes
- [ ] Wi-Fi: lists networks and connects
- [ ] Modem: connects to cell network
- [ ] Image sizes haven't increased
- [ ] Sounds work: `pkill -f manager ; /data/openpilot/scripts/disable-powersave.py && aplay /data/openpilot/selfdrive/assets/sounds/engage.wav`
- [ ] Clean openpilot build: `scons -c && scons -j8`
- [ ] Factory reset
  - [ ] from openpilot menu
  - [ ] tapping on boot
  - [ ] corrupt userdata: `dd if=/dev/zero of=/dev/disk/by-partlabel/userdata count=10 bs=1M`
- [ ] Clean setup: factory reset -> install openpilot -> openpilot works
- [ ] Color calibration works from `/persist/comma/`
  - [ ] tizi: `busybox logread | grep 'Successfully setup color correction'`
  - [ ] mici: `busybox logread | grep -i 'Successfully setup screen calibration'`
- [ ] AGNOS update works on warm boot
  - [ ] previous -> new
  - [ ] new -> previous
- [ ] Display works at 60FPS: `SHOW_FPS=1 /data/openpilot/selfdrive/ui/ui.py`

### ABL

- [ ] A/B slot fallback works
- [ ] Boot time hasn't regressed (1s)

### XBL

- [ ] Display init works in cold and hot temperatures
- [ ] Display works at 60FPS
- [ ] Boot time hasn't regressed (2.4s)

### Setup

- (a) Not a real URL (e.g. `comma`, `abc123`, `...`)
  - [ ] "Ensure the entered URL is valid"
  - [ ] Start over
  - [ ] Reboot device
- (b) Website but not an installer URL (e.g. `github.com`, `comma.ai`, `installer.comma.ai`)
  - [ ] "No custom software found at this URL."
- (c) Valid installer URL (e.g. `openpilot.comma.ai`)
  - [ ] Download successful (comma logo or installer appears)
  - [ ] `/tmp/installer_url` should contain the installer URL
  - [ ] Boots into openpilot

## runit migration

Before flashing, run:

```sh
python3 -m unittest discover -s tests -v
docker build -f tests/Dockerfile.runit -t agnos-runit-test .
docker run --rm agnos-runit-test
```

The disposable container checks failed initialization retries, child process
termination, default remote-access state, and openpilot's JSON log feed.

On both comma 3X and four, compare repeated cold boots with the current image:

* Confirm `/proc/1/comm` is `runit`, `sudo sv status /etc/service/*` shows the
  expected services, and no systemd manager, udev, NetworkManager, D-Bus, resolved, timesyncd or journald runs.
* Measure power-on to setup UI and openpilot readiness, including boots without
  a SIM, without Wi-Fi, and with unavailable NTP servers.
* Exercise Wi-Fi scanning, saved-network reconnect, hotspot and USB Ethernet.
  Switch between Wi-Fi and LTE repeatedly and inspect `/run/resolv.conf`, routes,
  DNS resolution, and the cellular inbound firewall.
* Toggle SSH and ADB on/off, delete their parameters, restart the watchers, and
  reconnect USB. Verify remote access stays disabled after a fresh factory reset.
* Reflash panda and reset/re-enumerate the modem repeatedly. Verify device aliases
  and permissions after each hotplug, including bootdevice partition aliases.
* Check audio, display, touch, brightness, DSP startup, thermal/power monitoring,
  persistent SSH keys, and recovery when userdata cannot mount.
* Confirm `/usr/comma/logread.py -f -o json` reaches openpilot's `operatingSystemLog`, and
  bootlog includes the current log buffer. Logs are bounded and volatile; the
  adapter has syslog timestamps (seconds), without journal process metadata.
* Test `sudo reboot`, `sudo poweroff`, abrupt power loss, and the updater's A/B
  rollback. Reboot flags must remain readable through shutdown on the RO rootfs.

The matching openpilot branch is required: `systemd-less-agnos`. For hardware
validation, launch with `AGNOS_VERSION=$(cat /VERSION)` to keep the development
image; the normal release manifest still points to the released Ubuntu image.
Do not merge the openpilot change into a release until its AGNOS manifest is
updated to the tested image. The bundled setup/reset/updater zipapps include the
new Wi-Fi client; regenerate their networking code with
`scripts/update_setup_networking.py /path/to/companion/openpilot`.

wifi.py migrates supported open/WPA-PSK NetworkManager keyfiles once into
`/data/etc/wifi.json` (root-only, atomic writes), leaving the originals intact
for rollback. Test open, WPA/WPA2, hidden and Unicode SSIDs, wrong passwords,
rapid A -> B connection switches, forgetting the current/other network, metered
settings, supplicant/daemon restarts and DHCP lease renewal/loss. WPA3-only and
enterprise networks are displayed as unsupported, matching the existing PSK
connection API. Test hotspot password changes and optional internet forwarding;
new inbound forwarded traffic to hotspot clients must be rejected.

mdev handles hotplug using sysfs USB interface IDs, not ttyUSB numbering.
`/usr/comma/hotplug.py --coldplug` also restores sysfs-only permissions. Validate
panda normal/bootstub/DFU, modem AT port aliases after resets, GPU/audio/input,
GPIO exports, panel brightness and UFS aliases on both hardware variants.

mDNS uses Ubuntu's python3-zeroconf to advertise `<serial-hostname>.local` and
`_ssh._tcp`, without avahi/D-Bus. Check discovery over Wi-Fi, hotspot and Ethernet.
The systemd, udev, NetworkManager, polkit and D-Bus daemons are absent; shared
client libraries needed by Ubuntu packages can remain.
