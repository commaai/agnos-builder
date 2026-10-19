#!/usr/bin/env python3

import os
import shutil
from pathlib import Path

ROOT = Path("/cache/debug/")


if __name__ == "__main__":
  os.makedirs(ROOT, exist_ok=True)

  boots = sorted(list(ROOT.iterdir()), key=lambda p: int(p.stem, 16), reverse=True)

  # limit to 100 boots
  for d in boots[100:]:
    print("cleaning up", d)
    shutil.rmtree(d)

  # make a directory for this boot
  n = 0
  if len(boots):
    n = int(boots[0].stem, 16) + 1
  boot_dir = ROOT / f"{n:08x}"
  boot_dir.mkdir(parents=True)

  # log some stuff
  pstore = boot_dir / "pstore"
  pstore.mkdir()
  os.system(f"cp /sys/fs/pstore/* {pstore} 2>/dev/null")

  os.system(f"uname -a > {boot_dir / 'uname'}")
  shutil.copyfile("/VERSION", boot_dir / "VERSION")

