#!/usr/bin/env python3
import json
import os
import hashlib
import shutil
import subprocess
from copy import deepcopy
from pathlib import Path

ROOT = Path(__file__).parent.parent
OUTPUT_DIR = ROOT / "output"
FIRMWARE_DIR = ROOT / "firmware"
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
  # since system.img is a squashfs now, we don't rely on this compression.
  # however, openpilot's updater still expects an xz archive, so use lowest
  # compression level for quick packaging.
  subprocess.check_call(f"xz -0 -T0 -vc {fin} > {fout}", shell=True)


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

  if name == "system":
    ret["alt"] = {
      "hash": hash_raw,
      "url": "{remote_url}/" + xz_fn.name.replace(".img.xz", ".img"),
      "size": size,
    }
    shutil.copy(fn, OTA_OUTPUT_DIR / f"{fn.stem}-{hash_raw}.img")

  return ret


if __name__ == "__main__":
  OTA_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

  files = [
    process_file(OUTPUT_DIR / "boot.img", "boot"),
    process_file(OUTPUT_DIR / "system.img", "system", full_check=False),
  ]
  for fw in ("xbl", "abl", "xbl_config", "devcfg", "aop"):
    # firmware not built in this repo
    files.append(process_file(FIRMWARE_DIR / f"{fw}.bin", fw))

  configs = [
    (AGNOS_UPDATE_URL, "ota.json"),
    (AGNOS_STAGING_UPDATE_URL, "ota-staging.json"),
  ]
  for remote_url, output_fn in configs:
    processed_files = []
    for f in deepcopy(files):
      f["url"] = f["url"].format(remote_url=remote_url)
      if "alt" in f:
        f["alt"]["url"] = f["alt"]["url"].format(remote_url=remote_url)
      processed_files.append(f)

    with open(OTA_OUTPUT_DIR / output_fn, "w") as out:
      json.dump(processed_files, out, indent=2)

  print("Done")
