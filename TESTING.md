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
