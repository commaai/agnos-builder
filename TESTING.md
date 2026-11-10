# testing

## Release PR

openpilot PR titled `AGNOS <VERSION>`:

```
- ~33% faster cold boot: 4.45s → 3.00s
- <what changed, most noticeable first>

Build: agnos-builder <commit link> ([diff](https://github.com/commaai/agnos-builder/compare/<previous release>...<commit>))
Sizes: system <before> → <after>, boot <before> → <after>

## Release Checklist

## Diff-specific checks
```

## Release Checklist

- [ ] [`tests/test_agnos.py`](tests/test_agnos.py) passes after every boot
  - [ ] 100/100 cold boots
  - [ ] 100/100 warm boots
- [ ] [`test_onroad`](https://github.com/commaai/openpilot/blob/master/openpilot/selfdrive/test/test_onroad.py) passes 20/20
- [ ] Wi-Fi: lists networks and connects
- [ ] Modem: connects to cell network
- [ ] Image sizes haven't increased
- [ ] Sounds work: the mic picks up a sound played on the speaker: `pkill -f manager ; /data/openpilot/scripts/disable-powersave.py && (arecord -q -d 3 -f S16_LE -r 48000 /tmp/rec.wav & aplay -q /data/openpilot/openpilot/selfdrive/assets/sounds/engage.wav; wait)`
- [ ] Clean openpilot build: `scons -c && ./openpilot/system/manager/build.py`
- [ ] Factory reset
  - [ ] from openpilot menu
  - [ ] tapping on boot: `echo 5 > /tmp/taps && sudo mount --bind /tmp/taps /sys/class/input/input2/device/touch_count && sudo rm /run/comma-booted && sudo systemctl restart comma`
  - [ ] corrupt userdata: `dd if=/dev/zero of=/dev/disk/by-partlabel/userdata count=10 bs=1M`
- [ ] Clean setup: factory reset -> install openpilot -> openpilot works (candidate is this PR)
  - [ ] release AGNOS, release openpilot
  - [ ] release AGNOS, candidate openpilot
  - [ ] candidate AGNOS, release openpilot
  - [ ] candidate AGNOS, candidate openpilot
- [ ] Color calibration works from `/persist/comma/`
  - [ ] tizi: `journalctl -u magic | grep 'Successfully setup color correction'`
  - [ ] mici: `journalctl -u magic | grep 'Successfully setup screen calibration'`
- [ ] AGNOS update works on warm boot, through the updater UI
  - [ ] previous -> new
  - [ ] new -> previous
- [ ] Display works at 60FPS: `SHOW_FPS=1 /data/openpilot/openpilot/selfdrive/ui/ui.py`
- [ ] Display stays on and calibrated after restarting `ui.py` 5 times

### ABL

- [ ] unchanged, or all of:
  - [ ] A/B slot fallback works
  - [ ] Boot time hasn't regressed (1s)

### XBL

- [ ] unchanged, or all of:
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

## Diff-specific checks

Review the full diff since the last release adversarially. Predict where the bugs are and add a check for each one.
