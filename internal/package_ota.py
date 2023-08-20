#!/usr/bin/env python3
import json
import os
import subprocess
from pathlib import Path
from tempfile import NamedTemporaryFile

ROOT = Path(__file__).parent.parent
OUTPUT_DIR = ROOT / "output"
OTA_OUTPUT_DIR = OUTPUT_DIR / "ota"
FIRMWARE_DIR = ROOT / "agnos-firmware"

AGNOS_UPDATE_URL = os.getenv("AGNOS_UPDATE_URL", "https://commadist.azureedge.net/agnosupdate")
AGNOS_STAGING_UPDATE_URL = os.getenv("AGNOS_STAGING_UPDATE_URL", "https://commadist.azureedge.net/agnosupdate-staging")


def checksum(fn: str) -> str:
  return subprocess.check_output(["sha256sum", fn]).decode().split()[0]


def process_file(fn, name, sparse=False, full_check=True, has_ab=True, alt=None) -> dict:
  fn = os.path.join(OUTPUT_DIR, fn)
  hash_raw = hash = checksum(fn)
  size = os.path.getsize(fn)

  if sparse:
    with NamedTemporaryFile() as f:
      os.system(f"simg2img {fn} {f.name}")
      hash_raw = checksum(f.name)
      size = os.path.getsize(f.name)

  ret = {
    "name": name,
    "hash": hash,
    "hash_raw": hash_raw,
    "size": size,
    "sparse": sparse,
    "full_check": full_check,
    "has_ab": has_ab,
  }

  if alt is not None:
    ret["alt"] = {
      "url": "",
      "hash": "",
      "size": 0,
    }

  return ret


if __name__ == "__main__":
  configs = [
    (AGNOS_UPDATE_URL, "ota.json"),
    (AGNOS_STAGING_UPDATE_URL, "ota-staging.json"),
  ]
  for remote_url, output_fn in configs:
    files = [
      process_file(OUTPUT_DIR / "boot.img", "boot"),
      process_file(FIRMWARE_DIR / "abl.bin", "abl"),
      process_file(FIRMWARE_DIR / "xbl.bin", "xbl"),
      process_file(FIRMWARE_DIR / "xbl_config.bin", "xbl_config"),
      process_file(FIRMWARE_DIR / "devcfg.bin", "devcfg"),
      process_file(FIRMWARE_DIR / "aop.bin", "aop"),
      process_file(OUTPUT_DIR / "system.img", "system", sparse=True, full_check=False),
    ]
    with open(OTA_OUTPUT_DIR / output_fn, "w") as f:
      f.write(json.dumps(files, indent=2))
