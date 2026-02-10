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
3. ~~get wlan up and working~~ (fixed)
4. ~~the tmux session (from the comma service) doesn't have our tmux.conf applied~~ (fixed: HOME=/home/comma in comma service)
5. ~~get graphics (i.e. magic) working~~ (fixed: bypass libglvnd, use libEGL_adreno.so directly)
6. replace closed blobs graphics stack with freedreno
7. ~~fix DNS (e.g. make ping google.com work)~~ (fixed: ping needed CAP_NET_RAW capability)
8. ~~setup a good journalctl/logging replacement~~ (fixed: removed redundant /var/log tmpfs from fs_setup.sh that hid rsyslogd's files; journalctl shim works for all formats)
9. get ADB working
10. ~~enable LTE~~ (fixed: lte service wasn't symlinked, added usbutils for lsusb)
11. ~~remove armhf blobs~~ (removed adsprpcd/cdsprpcd services+binaries, all 32-bit binaries from void/blobs)

## Fixes Applied

### capnproto version mismatch
Void has capnproto 1.1.0 but openpilot release was built against 1.0.2. Create symlinks in /usr/lib64/ from 1.0.2 -> 1.1.0 for libcapnp, libcapnp-rpc, libcapnpc, libkj, libkj-async.

### EGL extension functions
openpilot's egl.py accesses `eglCreateImageKHR` from libEGL.so via cffi. libglvnd's dispatcher doesn't export extension functions (must use eglGetProcAddress). Replace libEGL.so.1.1.0 with libEGL_adreno.so which exports eglCreateImageKHR directly.

### ping capability
Void's iputils package doesn't set CAP_NET_RAW on ping by default, causing "Operation not permitted" for non-root users. Fixed with `setcap cap_net_raw+ep bin/iputils-ping` in build_void.sh.

### ffmpeg OpenCL link errors
Void's ffmpeg6 package is compiled with OpenCL support, requiring versioned symbols (`clCreateContext@OPENCL_1.0`) from ocl-icd. Qualcomm's libOpenCL doesn't provide versioned symbols and its ICD interface is broken (`clIcdGetPlatformIDsKHR` returns CL_INVALID_VALUE). Fix: compile ffmpeg 4.2.2 from source with `--disable-opencl`, removed ffmpeg6/ffmpeg-devel/ocl-icd from xbps packages.

### rsyslogd not writing logs at boot
`fs_setup.sh` mounted a separate tmpfs on `/var/log` (carried over from Ubuntu where `/var` is on real rootfs). On Void `/var` is already a tmpfs, so the second mount hid rsyslogd's output. Fix: removed the redundant mount from fs_setup.sh.

### LTE modem not working
The `lte` runit service was not enabled (not in the symlink list in Dockerfile.void). Without it, GPIO never powers on the Quectel EC25 modem, so no USB modem device appears. Also needed `usbutils` package (lte.sh uses `lsusb` to detect modem).

### armhf blob cleanup
adsprpcd/cdsprpcd are 32-bit armhf binaries that can't run on pure aarch64 Void. Per PR #515, they're intentionally skipped — tinygrad uses CDSP via kernel driver directly, and ALSA works without adsprpcd. Removed services, binaries, and all other 32-bit blobs (diag_*, qmi_test_*, logcat, logwrapper, fs_mgr, gbmtest, etc).

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
