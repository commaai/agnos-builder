#!/usr/bin/env python3
import sys
import json
import os
import hashlib
import subprocess
from copy import deepcopy
from pathlib import Path

ROOT = Path(__file__).parent.parent
OUTPUT_DIR = ROOT / "output"
OTA_OUTPUT_DIR = OUTPUT_DIR / "ota"
BUILD_DIR = ROOT / "build"

AGNOS_UPDATE_URL = os.getenv("AGNOS_UPDATE_URL", "https://commadist.azureedge.net/agnosupdate")
AGNOS_STAGING_UPDATE_URL = os.getenv("AGNOS_STAGING_UPDATE_URL", "https://commadist.azureedge.net/agnosupdate-staging")

def checksum(fn):
  sha256 = hashlib.sha256()
  with open(fn, 'rb') as f:
    for chunk in iter(lambda: f.read(4096), b""):
      sha256.update(chunk)
  return sha256.hexdigest()

def compress(fin, fout) -> None:
  subprocess.check_call(f"xz -T4 -vc {fin} > {fout}", shell=True)


def process_file(fn, name, full_check=True, has_ab=True):
  print(name)
  hash_raw = hash = checksum(fn)
  size = fn.stat().st_size
  print(f"  {size} bytes, hash {hash}")

  print("  compressing")
  xz_fn = OTA_OUTPUT_DIR / f"{fn.stem}-{hash_raw}.img.xz"
  compress(fn, xz_fn)

  ret = {
    "name": name,
    "url": "{remote_url}/" + xz_fn.name,
    "hash": hash,
    "hash_raw": hash_raw,
    "size": size,
    "sparse": False,
    "full_check": full_check,
    "has_ab": has_ab,
  }

  return ret


if __name__ == "__main__":
  OTA_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

  if len(sys.argv[1:]):
    files = [process_file(Path(fn), Path(fn).stem) for fn in sys.argv[1:]]
  else:
    files = [
      process_file(OUTPUT_DIR / "boot.img", "boot"),
      process_file(OUTPUT_DIR / "system.img", "system", full_check=False),
    ]

    # pull in firmware not built in this repo
    with open(ROOT/"firmware.json") as f:
      fws = json.loads(f.read())
      for fw in fws:
        files.append({
          "name": fw["name"],
          "url": fw["url"],
          "hash": fw["hash"],
          "hash_raw": fw["hash"],
          "size": fw["size"],
          "sparse": False,
          "full_check": True,
          "has_ab": True,
        })

  configs = [
    (AGNOS_UPDATE_URL, "ota.json"),
    (AGNOS_STAGING_UPDATE_URL, "ota-staging.json"),
  ]
  for remote_url, output_fn in configs:
    processed_files = []
    for f in deepcopy(files):
      f["url"] = f["url"].format(remote_url=remote_url)
      processed_files.append(f)

    with open(OTA_OUTPUT_DIR / output_fn, "w") as out:
      json.dump(processed_files, out, indent=2)

  print("Done")
