# AGNOS Void Linux Migration

## Decisions
- glibc (Qualcomm blobs), runit (no systemd)
- Deleted: Qt/Weston/armhf, lpac

## Progress

| Task | Status |
|------|--------|
| Directory structure, Dockerfile, build script | done |
| Package mapping (xbps) | done |
| readonly_setup.sh | done |
| runit services | done |
| Blob extraction | done |
| Python 3.12 via uv | done |
| Eval tools (rootfs-init, diff, export) | done |
| **First boot test** | in progress |

## Development Workflow

The goal is fast iteration: fix issues live on the device, then backport working changes to the Dockerfile. Every change should be targeted. DO NOT change anything unrelated to the current bug, and only make the minimal change required to fix the bug.

### 1. Boot and Connect
```bash
# Flash the device
# reboot the device over serial to get it into flashing mode
./void/build_void.sh && ./flash_system.sh

# Connect via serial (always works, even if boot fails)
sudo screen /dev/ttyUSB0 115200

# Check if it's in fastboot flashing mode with:
fastboot devices
```

You can always reboot the device to get it into fastboot mode for flashing. Be careful about changes that will make it such that you can't reboot the device!

### 2. Initialize Git Tracking (first time only)
```bash
# On device - enables diffing against clean build
rootfs-init.sh
```

### 3. Evaluate and Fix Live
```bash
# Make changes directly on device
mount -o remount,rw /
nano /etc/sv/sshd/run
sv restart sshd

# Test immediately - no rebuild needed!

# Compare against Ubuntu reference if stuck
# (ubuntu-manifest.txt in void/eval/ on host)
```

### 4. Review Changes
```bash
# On device - see what you changed
rootfs-diff.sh

# Detailed diff
cd / && git diff
```

### 5. Export and Backport
```bash
# On device - package up changes
rootfs-export.sh

# On host - pull changes
./void/eval/rootfs-pull.sh 192.168.7.1

# Review and apply to Dockerfile/scripts
cat void/device-changes/*/modified.patch
ls void/device-changes/*/new-files/
```

### 6. Update Dockerfile
Once fixes are working, add them to `Dockerfile.void` or the appropriate script, then rebuild to verify.

## Reference Files

- `void/eval/ubuntu-manifest.txt` - Full file listing from working Ubuntu AGNOS (100k lines)
- Use to compare: `diff <(grep /etc/ssh void/eval/ubuntu-manifest.txt) <(ssh comma@192.168.7.1 "find /etc/ssh -type f")`

## Open Items

- [ ] Verify eudev rule compatibility
- [ ] Verify dbus starts before NetworkManager/ModemManager
- [ ] Verify polkit rules work on Void
- [ ] Test DSP services (adsprpcd, cdsprpcd)

## Directory Structure

```
void/
├── Dockerfile.void
├── build_void.sh
├── sv/                    # runit services
├── files/                 # configs, scripts
├── blobs/                 # cleaned agnos-*.deb contents
│   ├── base/
│   ├── display/
│   └── wlan/
└── eval/                  # development/eval tools
    ├── rootfs-init.sh     # init git tracking (device)
    ├── rootfs-manifest.sh # generate file list (device)
    ├── rootfs-diff.sh     # show changes (device)
    ├── rootfs-export.sh   # export changes (device)
    ├── rootfs-pull.sh     # pull from device (host)
    └── ubuntu-manifest.txt # reference from working Ubuntu
```

## Quick Reference

```bash
# Device tools (in /usr/local/bin/ after boot)
rootfs-init.sh      # One-time: init git tracking
rootfs-diff.sh      # Show what changed
rootfs-export.sh    # Export changes to /data

# Host tools
./void/eval/rootfs-pull.sh <device-ip>
```
