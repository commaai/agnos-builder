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
| **First boot test** | |

## Open Items

- [ ] Verify eudev rule compatibility
- [ ] Verify dbus starts before NetworkManager/ModemManager
- [ ] Verify polkit rules work on Void
- [ ] Test DSP services (adsprpcd, cdsprpcd)

## Directory Structure

```
void/
├── Dockerfile.void
├── sv/                    # runit services
├── files/                 # configs, scripts
└── blobs/                 # cleaned agnos-*.deb contents
    ├── base/
    ├── display/
    └── wlan/
```

## Dev Tips

```bash
# Shell into built image
./scripts/shell.sh

# Quick checks
docker run --rm void-agnos-builder:latest ls -la /home/comma/

# Compare against working Ubuntu AGNOS
ssh comma@comma-b7fa2255

# USB SSH testing
./scripts/usb-ssh.sh

# Serial console via screen
sudo screen /dev/ttyUSB1 115200
# Detach: Ctrl+A, D
# List sessions: sudo screen -ls
# Reattach: sudo screen -r <session_id>

# Send commands to detached serial session (for automation)
sudo screen -S <session_id> -X stuff "command here\n"
sudo screen -S <session_id> -X hardcopy /tmp/out; cat /tmp/out

# Flash over USB network (faster than QDL for iteration)
./flash_system_usb.sh
```

### Checklist before flash
- [ ] runit services in /etc/runit/runsvdir/default/
- [ ] polkit rules in /etc/polkit-1/rules.d/
- [ ] udev rules in /etc/udev/rules.d/
- [ ] /data, /system, /persist, /TICI, /AGNOS exist
- [ ] comma user with correct home ownership
- [ ] Qualcomm libs in /usr/lib/
- [ ] Firmware in /lib/firmware/
