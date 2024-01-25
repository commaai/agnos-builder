# internal

## release checklist

- [ ] openpilot CPU usage unchanged
- [ ] wifi
- [ ] modem
- [ ] image size
- [ ] sounds
- [ ] `python` is our python, not system version
- [ ] pyenv shims works
- [ ] clean openpilot build
- [ ] factory reset
  - [ ] from openpilot menu
  - [ ] tapping on boot
  - [ ] corrupt userdata
- [ ] color calibration
  - [ ] from /persist/comma/
  - [ ] directly from panel over sysfs
- [ ] clean setup
- [ ] cameras
- [ ] update works on warm boot
  - [ ] previous -> new
  - [ ] new -> previous

### ABL

- [ ] fastboot USB enumeration
- [ ] boot time hasn't regressed (3.8s)

### XBL

- [ ] display init works in cold and hot temperatures
- [ ] boot time hasn't regressed (2.4s)

### setup

#### networking

- [ ] continue button disabled when no connection
- [ ] forget/connect to wifi

#### custom URL
- (a) Not a real URL (e.g. `comma`, `abc123`, `...`)
  - [ ] "Ensure the entered URL is valid"
  - [ ] Start over
  - [ ] Reboot device
- (b) Website but not an installer URL (e.g. `github.com`, `comma.ai`, `installer.comma.ai`)
  - [ ] "No custom software found at this URL."
- (c) Valid installer URL (e.g. `openpilot.comma.ai`)
  - [ ] Download successful (comma logo or installer appears)
  - [ ] `/tmp/installer_url` should contain the installer URL
