# testing

## Release PR

openpilot PR titled `AGNOS <VERSION>`:

```
- <what changed, most noticeable first>

Build: agnos-builder <commit link>, diff from [master's AGNOS](https://github.com/commaai/agnos-builder/compare/<master AGNOS>...<commit>) and [release's AGNOS](https://github.com/commaai/agnos-builder/compare/<release AGNOS>...<commit>)

|              | release AGNOS | this AGNOS |
|--------------|---------------|------------|
| cold boot    |               |            |
| system image |               |            |
| boot image   |               |            |

## Release Checklist

## Diff-specific checks
```

## Running the tests

1. Build the candidate: add `[upload]` to a commit message on the PR. When the build's done,
   `https://gitlab.com/commaai/ci-artifacts/-/raw/agnos-builder/pr-<number>/agnos.json` lists its images (~25 min).
2. Flash its A/B images to slot a. `cat /VERSION` then matches the PR's `VERSION` file.
3. With openpilot stopped (`pkill -f manager`), run `/usr/comma/test_agnos.py`. It passes when it ends with `OK` (skips are fine) and exits 0.
4. A cold boot is a power cycle and a warm boot is `sudo reboot`.
5. `/usr/comma/screen` looks at and taps the screen (run it with no arguments for usage).

On the comma rack, https://chestnut.comma.life explains how to do each of these without a person.

## Release Checklist

- [ ] [`/usr/comma/test_agnos.py`](userspace/root/usr/comma/test_agnos.py) passes after every boot
  - [ ] 10/10 cold boots
  - [ ] 10/10 warm boots
- [ ] [`test_onroad`](https://github.com/commaai/openpilot/blob/master/openpilot/selfdrive/test/test_onroad.py) passes 20/20
- [ ] Wi-Fi: lists networks and connects
- [ ] Modem sees the SIM and a cell tower, no data plan needed: `/dev/shm/modem` has an `iccid` and a `signal_strength`
- [ ] Sounds work: the mic picks up a sound played on the speaker: `pkill -f manager ; /data/openpilot/scripts/disable-powersave.py && (arecord -q -d 3 -f S16_LE -r 48000 /tmp/rec.wav & aplay -q /data/openpilot/openpilot/selfdrive/assets/sounds/engage.wav; wait)`
- [ ] Clean openpilot build: `scons -c && ./openpilot/system/manager/build.py`
- [ ] Factory reset
  - [ ] from openpilot menu
  - [ ] tapping on boot: `echo 5 > /tmp/taps && sudo mount --bind /tmp/taps /sys/class/input/input2/device/touch_count && sudo rm /run/comma-booted && sudo systemctl restart comma`
  - [ ] corrupt userdata: `dd if=/dev/zero of=/dev/disk/by-partlabel/userdata count=10 bs=1M`
- [ ] Clean setup: factory reset -> install openpilot -> openpilot works (candidate is this PR)
  - [ ] release AGNOS, candidate openpilot
  - [ ] candidate AGNOS, release openpilot
  - [ ] candidate AGNOS, candidate openpilot

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

- Not a real URL (e.g. `comma`, `abc123`, `...`)
  - [ ] says it's invalid. tizi: "Ensure the entered URL is valid", mici: "Invalid URL"
  - [ ] try again. tizi: Start over, mici: swipe down
  - [ ] Reboot device
- Website but not an installer URL (e.g. `github.com`, `comma.ai`, `installer.comma.ai`)
  - [ ] "No custom software found at this URL"
- Valid installer URL (e.g. `openpilot.comma.ai`)
  - [ ] Download successful (comma logo or installer appears)
  - [ ] `/tmp/installer_url` should contain the installer URL
  - [ ] Boots into openpilot

## Diff-specific checks

Review two diffs adversarially: from the AGNOS on openpilot master, and from the AGNOS on openpilot release. Predict where the bugs are and add a check for each one.
