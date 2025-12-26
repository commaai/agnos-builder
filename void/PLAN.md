# AGNOS Void Linux Migration

## Progress

| Task | Status |
|------|--------|
| Create void/ directory structure | done |
| Dockerfile.void | done |
| build_void.sh | done |
| base_setup.sh (xbps packages) | done |
| readonly_setup.sh | done |
| runit services (simple) | done |
| runit services (complex) | done |
| Extract/clean agnos-*.deb blobs | done |
| Build integration | done |
| First boot test | |

## Decisions

- **glibc** — Qualcomm blobs require it
- **runit** — no systemd
- **No Qt/Weston/armhf** — deleted entirely
- **No lpac** — not used

---

## Safe to Translate (zero risk)

These are mechanical translations I can do without review:

### readonly_setup.sh
Direct port — just shell commands, no distro-specific logic:
- Create symlinks to /data
- Move /var, /home to /usr/default
- Create mount points

### runit services (simple ones)
These are trivial `exec script` translations:
- fs_setup — `exec /usr/comma/fs_setup.sh`
- serial-hostname — `exec /usr/comma/serial-hostname.sh` (or whatever it runs)
- gpio — `exec /usr/comma/gpio.sh`
- sound — `exec /usr/comma/sound/sound_init.sh`
- init-qcom — `exec /usr/comma/init.qcom.sh`
- varwatch — `exec python3 /usr/comma/varwatch.py`
- power_monitor — `exec python3 /usr/comma/power_monitor.py`
- power_drop_monitor — `exec python3 /usr/comma/power_drop_monitor.py`
- brightnessd — `exec python3 /usr/comma/brightnessd.py`
- screen_calibration — `exec python3 /usr/comma/screen_calibration.py`
- adbd — `exec /usr/comma/adbd`
- avahi-ssh-publish — simple exec

### Config files (already done in Dockerfile)
- udev rules — copy as-is
- NetworkManager configs — copy as-is
- iptables rules — copy as-is
- ssh configs — copy as-is
- logrotate — copy as-is
- profile — copy as-is

### Qualcomm libs
Already handled — just copy to /usr/lib/ instead of /usr/lib/aarch64-linux-gnu/

---

## Needs Review (some risk)

### base_setup.sh — package mapping
~100 packages to map from apt to xbps. Most are 1:1 but need verification:
- Some packages have different names
- Some may not exist (ubuntu-minimal, ubuntu-server, etc. — fine to skip)
- Some may need alternatives (apt-fast → just use xbps)

**Skip entirely:**
- All armhf packages (lines 129-203) — not needed without Weston
- ubuntu-minimal, ubuntu-server, ubuntu-standard — meta-packages
- apt-fast — not needed
- landscape-common, apport-retrace — Ubuntu-specific

### runit services (complex ones)

**comma.service** — runs as user, uses tmux, has rlimits:
```
User=comma
LimitRTPRIO=100
LimitNICE=-10
```
Need to handle user switching and rlimits in runit.

**magic.service** — has ExecStartPre commands:
```
ExecStartPre=/bin/bash -c "chgrp gpu /dev/ion /dev/kgsl-3d0"
ExecStartPre=/bin/bash -c "chmod 660 /dev/ion /dev/kgsl-3d0"
```
Need to run these before main exec in the run script.

**lte.service** — need to check what it does

**ModemManager** — third-party service, need to create runit wrapper

### runit services (path watchers)
These need inotifywait pattern:
- ssh-param-watcher — watches /data/params/d/SshEnabled
- adb-param-watcher — watches /data/params/d/AdbEnabled

### Timer replacement
- logrotate-hourly.timer → cron or snooze

---

## Needs Deep Review (higher risk)

### agnos-*.deb extraction
Need to manually inspect and clean:
- Remove all /etc/systemd/, /lib/systemd/ dirs
- Remove all armhf libs from agnos-display.deb
- Keep firmware, udev rules, init scripts, binaries
- Verify nothing relies on systemd

### DSP services (adsp, cdsp, adsprpcd, cdsprpcd)
These come from agnos-base.deb. Need to understand:
- What binaries they run
- Dependencies on other services
- Boot order requirements

### Compile scripts — DONE
All needed packages available in Void repos:
- capnproto 1.1.0 ✓
- ffmpeg6 6.1.3 ✓
- libqmi 1.36.0 ✓
- ModemManager 1.24.0 ✓
- lpac — removed (not used)

### Python/uv setup — DONE
- uv installed in base_setup.sh
- Python 3.12 installed via uv (Void has 3.14 which is too new)
- venv created at /usr/local/venv
- 155 packages installed via uv sync

---

## Directory Structure

```
void/
├── PLAN.md
├── Dockerfile.void
├── build_void.sh
├── base_setup.sh
├── readonly_setup.sh
├── sv/                    # runit services
│   ├── adsp/run
│   ├── cdsp/run
│   ├── comma/run
│   └── ...
├── files/                 # configs, udev rules
├── libs/                  # Qualcomm aarch64 libs
├── firmware/              # GPU firmware (a630_*)
└── blobs/                 # cleaned agnos-*.deb contents
    ├── base/
    ├── display/
    └── wlan/
```

---

## Package Mapping (WIP)

| apt | xbps | notes |
|-----|------|-------|
| build-essential | base-devel | |
| network-manager | NetworkManager | |
| openssh-server | openssh | |
| git, curl, wget | same | |
| htop, nano, jq | same | |
| python3 | python3 | |
| ... | ... | fill in as we go |

---

## Review Process

After each change, run:

```bash
# 1. Build
./void/build_void.sh

# 2. Mount and inspect rootfs
simg2img output/system.img /tmp/void-rootfs.raw
sudo mount -o loop /tmp/void-rootfs.raw /tmp/void-rootfs
# inspect...
sudo umount /tmp/void-rootfs

# 3. Run in Docker and test
docker run --rm --platform linux/arm64 void-agnos-builder /bin/sh -c "
  # test commands
"
```

### Checklist
- [ ] Build passes
- [ ] runit services enabled in /etc/runit/runsvdir/default/
- [ ] polkit rules in /etc/polkit-1/rules.d/
- [ ] udev rules in /etc/udev/rules.d/ (no polkit)
- [ ] /data, /system, /persist, /TICI, /AGNOS exist
- [ ] comma user exists with correct home ownership
- [ ] Qualcomm libs in /usr/lib/
- [ ] Firmware in /lib/firmware/
- [ ] Python installed and working (once base_setup.sh is done)

## Open Items

- [ ] Verify eudev vs udevd rule compatibility
- [ ] Verify dbus starts before NetworkManager/ModemManager
- [ ] Verify polkit rules work on Void
- [ ] Test DSP services actually start
