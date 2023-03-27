# internal

## release checklist

- [ ] CPU usage
- [ ] wifi
- [ ] modem
- [ ] image size
- [ ] sounds
- [ ] python/shims works
- [ ] clean openpilot build
- [ ] factory reset
  - [ ] user-prompted reset
  - [ ] corrupt userdata
  - [ ] finish ABL reset
- [ ] color calibration
- [ ] clean setup
- [ ] cameras
- [ ] update works on warm boot

### ABL

- [ ] fastboot USB enumeration
- [ ] system reset trigger works
- [ ] boot time hasn't regressed (3.8s)

### XBL

- [ ] display init works in cold and hot temperatures
- [ ] boot time hasn't regressed (2.4s)

### setup

#### networking

- [ ] continue button disabled when no connection
- [ ] forget/connect to wifi
- [ ] ethernet

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
