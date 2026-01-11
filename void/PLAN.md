# AGNOS Void Linux Migration

## Decisions
- glibc (Qualcomm blobs), runit (no systemd)
- Deleted: Qt/Weston/armhf, lpac
- Code style: 2-space indentation

## Development Workflow

The goal is fast iteration: fix issues live on the device, then backport working changes to the Dockerfile. Every change should be targeted. DO NOT change anything unrelated to the current bug, and only make the minimal change required to fix the bug.

things to know:
* every boot starts in fastboot. you can either flash it with flash_system.sh or continue booting with "fastboot continue"
* be careful to not make changes that will prevent you from being able to reboot to get it back into fastboot
* you have access to a serial console running in a screen session
* you can check if it's in fastboot mode with "fastboot devices"
* you can also use ADB to get a shell on our device with "adb shell"
* you can SSH into this second device ("ssh comma@comma-564b9adb") to check against a known working device running Ubuntu AGNOS
* `void/eval/ubuntu-manifest.txt` - Full file listing from working Ubuntu AGNOS (100k lines)
* Use to compare: `diff <(grep /etc/ssh void/eval/ubuntu-manifest.txt) <(ssh void_device_ip "find /etc/ssh -type f")`

```bash
# Flash the device
# reboot the device over serial to get it into flashing mode
./void/build_void.sh && ./flash_system.sh

# Connect via serial (always works, even if boot fails)
sudo screen /dev/ttyUSB0 115200

# Check if it's in fastboot flashing mode with:
fastboot devices
```

always follow this exact workflow:
* i will give a task that we're working on
* you will root cause it and fix it on the live running device
* once it's fixed on the device, present me with a succint root cause. then i'll review and test
* if i approve, then fix it in the docker build, build, flash, then test the fix
* if it works after flashing, let me know for a final review. then i will give the next task
for these tests, test with 2x reboots unless otherwise specified.

NEVER FLASH WITHOUT GETTING APPROVAL

## tasks

this is a running list of tasks. do not work on one until i tell you to do so.
once we work on one and finish it, cross it off.
1. ~~get USB SSH networking reliable~~ (fixed: /dev/socket dir creation in leprop, set_ssh.sh always enables SSH)
2. ~~why does udev settle timeout? can we fix it?~~ (fixed: 99-gpio.rules was running expensive find on every gpio event)
3. get wlan up and working
4. ~~the tmux session (from the comma service) doesn't have our tmux.conf applied~~ (fixed: HOME=/home/comma in comma service)
5. get graphics (i.e. magic) working
6. replace closed blobs graphics stack with freedreno
7. fix DNS (e.g. make curl google.com work)
8. setup a good journalctl/logging replacement
9. get ADB working

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
