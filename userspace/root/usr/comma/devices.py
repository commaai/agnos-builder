#!/usr/bin/python3 -IS
# AGNOS doesn't run udev, the kernel creates device nodes as root:root 0600. This gives them their
# groups, modes and symlinks once at boot, nothing here reads from a driver so it can't get stuck.
# What comes and goes later is handled by its owner:
#   /dev/snd: sound_init.sh, once the ADSP is ready for clients
#   /sys/class/gpio: gpio.sh, as it exports them
#   /dev/ttyUSB*: modem.py, the modem can re-enumerate at any time
#   /dev/bus/usb: the kernel's usb_devnode
import glob
import grp
import os
import sys
import time

NODES = (
  ("adsprpc-smd", "gpu", 0o660),
  ("dri/*", "gpu", 0o660),
  ("fuse", "root", 0o666),
  ("gpiochip0", "gpio", 0o660),
  ("i2c-*", "gpio", 0o660),
  ("input/*", "input", 0o666),
  ("ion", "gpu", 0o660),
  ("kgsl-3d0", "gpu", 0o660),
  ("media*", "video", 0o660),
  ("net/tun", "root", 0o666),
  ("sd*", "disk", 0o660),
  ("sg*", "disk", 0o660),
  ("spidev*", "root", 0o666),
  ("ttyHS0", "gpio", 0o660),
  ("ttyMSM*", "dialout", 0o660),
  ("v4l-subdev*", "video", 0o660),
  ("video*", "video", 0o660),
)

# sysfs attributes the video group can write
VIDEO_ATTRS = (
  "/sys/class/backlight/panel0-backlight/brightness",
  "/sys/class/backlight/panel0-backlight/bl_power",
  "/sys/class/leds/led:torch_2/brightness",
  "/sys/class/leds/led:switch_2/brightness",
  "/sys/bus/platform/devices/soc:qcom,dsi-display@0/max_brightness_percent",
)

# what's needed from the UFS LUNs, they finish probing around when this starts
PARTITIONS = ("userdata", "persist", "cache", "modem_a", "modemst1", "modemst2", "fsc", "fsg")
PARTITION_TIMEOUT = 5


def own(path, group, mode):
  try:
    os.chown(path, 0, grp.getgrnam(group).gr_gid)
    os.chmod(path, mode)
  except OSError as e:
    print(f"{path}: {e}", file=sys.stderr)


def link(target, path):
  try:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    os.symlink(os.path.relpath(target, os.path.dirname(path)), path)
  except OSError as e:
    print(f"{path}: {e}", file=sys.stderr)


def read(path):
  try:
    with open(path, errors="replace") as f:
      return f.read().strip()
  except OSError:
    return ""


def partitions():
  parts = {}
  for path in glob.iglob("/sys/class/block/sd*/uevent"):
    env = dict(line.split("=", 1) for line in read(path).splitlines() if "=" in line)
    if "PARTNAME" in env and os.path.exists(f"/dev/{env['DEVNAME']}"):
      parts[env["PARTNAME"]] = env["DEVNAME"]
  return parts


def main():
  # nothing in userspace provides firmware, requests falling back to it would otherwise wait 60s
  try:
    with open("/sys/class/firmware/timeout", "w") as f:
      f.write("1")
  except OSError as e:
    print(f"firmware timeout: {e}", file=sys.stderr)

  start = time.monotonic()
  parts = partitions()
  while not parts.keys() >= set(PARTITIONS) and time.monotonic() - start < PARTITION_TIMEOUT:
    time.sleep(0.01)
    parts = partitions()

  for pattern, group, mode in NODES:
    for path in glob.iglob(f"/dev/{pattern}"):
      own(path, group, mode)
  for path in VIDEO_ATTRS:
    if os.path.exists(path):
      own(path, "video", 0o664)

  for name, dev in parts.items():
    if "/" not in name:
      link(f"/dev/{dev}", f"/dev/disk/by-partlabel/{name}")
      link(f"/dev/{dev}", f"/dev/block/bootdevice/by-name/{name}")
  link("/dev/rtc0", "/dev/rtc")
  for path in glob.iglob("/sys/class/input/event*"):
    if "/894000.i2c/" in os.path.realpath(path):
      link(f"/dev/input/{os.path.basename(path)}", "/dev/input/by-path/platform-894000.i2c-event")
  for path in glob.iglob("/sys/class/video4linux/video*"):
    parent = os.path.realpath(path).split("/")[-3].replace(",", "_")
    link(f"/dev/{os.path.basename(path)}", f"/dev/v4l/by-path/platform-{parent}-video-index{read(f'{path}/index')}")


if __name__ == "__main__":
  main()
