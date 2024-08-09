#!/usr/bin/env python3
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


def process_file(fn, name, sparse=False, full_check=True, has_ab=True, alt=None):
  print(name)
  hash_raw = hash = checksum(fn)
  size = fn.stat().st_size
  print(f"  {size} bytes, hash {hash}")

  if sparse:
    raw_img = BUILD_DIR / "system.img.raw"
    if raw_img.exists():
      print("  using existing raw image")
      hash_raw = checksum(raw_img)
      size = raw_img.stat().st_size
    else:
      print("Error: existing raw image not found")
      exit(1)
    print(f"  {size} bytes, hash {hash_raw} (raw)")

  print("  compressing")
  xz_fn = OTA_OUTPUT_DIR / f"{fn.stem}-{hash_raw}.img.xz"
  compress(fn, xz_fn)

  ret = {
    "name": name,
    "url": "{remote_url}/" + xz_fn.name,
    "hash": hash,
    "hash_raw": hash_raw,
    "size": size,
    "sparse": sparse,
    "full_check": full_check,
    "has_ab": has_ab,
  }

  if alt is not None:
    print("  calculating alt")
    alt_hash = checksum(alt)
    alt_size = alt.stat().st_size
    print(f"  {alt_size} bytes, hash {alt_hash} (alt)")

    print("  compressing alt")
    alt_xz_fn = OTA_OUTPUT_DIR / f"{alt.stem}-{hash_raw}.img.xz"
    compress(alt, alt_xz_fn)

    ret["alt"] = {
      "hash": alt_hash,
      "url": "{remote_url}/" + alt_xz_fn.name,
      "size": alt_size,
    }

  return ret


if __name__ == "__main__":
  OTA_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

  files = [
    process_file(OUTPUT_DIR / "boot.img", "boot"),
    process_file(OUTPUT_DIR / "system.img", "system", sparse=True, full_check=False, alt=OUTPUT_DIR / "system-skip-chunks.img"),
  ]
  configs = [
    (AGNOS_UPDATE_URL, "ota.json"),
    (AGNOS_STAGING_UPDATE_URL, "ota-staging.json"),
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
