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
  - [ ] tizi: `journalctl -u magic | grep 'Successfully setup color correction'`
  - [ ] mici: `journalctl -u screen_calibration | grep -i 'Successfully setup screen calibration'`
- [ ] AGNOS update works on warm boot
  - [ ] previous -> new
  - [ ] new -> previous
- [ ] Display works at 60FPS: `SHOW_FPS=1 /data/openpilot/selfdrive/ui/ui.py`

### Qt and Weston removal

Earlier attempts: [#360](https://github.com/commaai/agnos-builder/pull/360),
[#489](https://github.com/commaai/agnos-builder/pull/489),
[#502](https://github.com/commaai/agnos-builder/pull/502), and
[#560](https://github.com/commaai/agnos-builder/pull/560).

- [ ] Confirm the oldest supported Raylib-based openpilot release builds and can run its AGNOS updater.
  Qt-based releases are no longer supported. Their updater fails before reaching the Wayland
  interception shim; this caused the revert of #502. The obsolete shim has also been removed.
- [ ] Run a large reboot loop and check the background and UI on every boot.
  [#493](https://github.com/commaai/agnos-builder/pull/493#discussion_r2427644563)
  requested this; [#497](https://github.com/commaai/agnos-builder/pull/497) reported 350 successful boots.
- [ ] Test background transitions between spinner, setup, installer, updater, reset, and the openpilot UI.
- [ ] Check color calibration, touch input, screen brightness, and display wake/sleep on each supported device.
- [ ] Check native graphics loads `libffi.so.6`, Qualcomm GBM, Wayland client/server,
  `libwayland-egl.so.1`, and `libeglSubDriverWayland.so`; removing these broke `magic` in #502.
- [ ] Check onroad GPU compute and DSP services. ARM32 cleanup must account for
  `adsprpcd` and `cdsprpcd`, as noted in [#276](https://github.com/commaai/agnos-builder/issues/276)
  and [#492](https://github.com/commaai/agnos-builder/pull/492).
- [ ] Exercise both AGNOS update directions from the release checklist above using the oldest supported release.

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
