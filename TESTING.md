# testing

## Release Checklist

- [ ] [`test_onroad`](https://github.com/commaai/openpilot/blob/master/selfdrive/test/test_onroad.py) passes
- [ ] Wi-Fi: lists networks and connects
- [ ] Modem: connects to cell network
- [ ] Image sizes haven't increased
- [ ] Sounds work
- [ ] `python` is our python, not system version
- [ ] Clean openpilot build: `scons -c && scons -j8`
- [ ] Factory reset
  - [ ] from openpilot menu
  - [ ] tapping on boot
  - [ ] corrupt userdata
- [ ] Color calibration
  - [ ] from /persist/comma/
  - [ ] directly from panel over sysfs
- [ ] Clean setup: factory reset -> install openpilot -> openpilot works
- [ ] AGNOS update works on warm boot
  - [ ] previous -> new
  - [ ] new -> previous
- [ ] comma three: NVMe works

### ABL

- [ ] A/B slot fallback works
- [ ] Boot time hasn't regressed (1s)

### XBL

- [ ] Display init works in cold and hot temperatures
- [ ] Boot time hasn't regressed (2.4s)

### Setup

#### Networking

- [ ] Continue button disabled when no connection
- [ ] Forget/connect to wifi

#### Custom URL
- (a) Not a real URL (e.g. `comma`, `abc123`, `...`)
  - [ ] "Ensure the entered URL is valid"
  - [ ] Start over
  - [ ] Reboot device
- (b) Website but not an installer URL (e.g. `github.com`, `comma.ai`, `installer.comma.ai`)
  - [ ] "No custom software found at this URL."
- (c) Valid installer URL (e.g. `openpilot.comma.ai`)
  - [ ] Download successful (comma logo or installer appears)
  - [ ] `/tmp/installer_url` should contain the installer URL
