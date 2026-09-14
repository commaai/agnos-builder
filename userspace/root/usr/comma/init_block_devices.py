#!/usr/bin/env python3

import glob
import grp
import os
import stat


DISK_GID = grp.getgrnam("disk").gr_gid


def link(target, path):
  try:
    os.unlink(path)
  except FileNotFoundError:
    pass
  except OSError:
    return
  os.symlink(target, path)


def partname_for(path):
  try:
    with open(os.path.join(path, "uevent")) as f:
      for line in f:
        if line.startswith("PARTNAME="):
          return line.removeprefix("PARTNAME=").strip()
  except OSError:
    pass
  return None


if __name__ == "__main__":
  os.makedirs("/dev/disk/by-partlabel", exist_ok=True)
  os.makedirs("/dev/block/bootdevice/by-name", exist_ok=True)

  for path in glob.glob("/sys/class/block/sd[a-f]*"):
    dev = os.path.basename(path)
    dev_path = f"/dev/{dev}"

    try:
      dev_stat = os.stat(dev_path)
    except FileNotFoundError:
      continue
    if not stat.S_ISBLK(dev_stat.st_mode):
      continue

    os.chown(dev_path, 0, DISK_GID)
    os.chmod(dev_path, 0o660)

    partname = partname_for(path)
    if partname is None:
      continue

    link(f"../../{dev}", f"/dev/disk/by-partlabel/{partname}")
    link(dev_path, f"/dev/block/bootdevice/by-name/{partname}")
