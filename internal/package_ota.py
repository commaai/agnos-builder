#!/usr/bin/env python3
import json
import os
import subprocess
from copy import deepcopy
from pathlib import Path
from tempfile import NamedTemporaryFile
from typing import Optional, Union

ROOT = Path(__file__).parent.parent
OUTPUT_DIR = ROOT / "output"
OTA_OUTPUT_DIR = OUTPUT_DIR / "ota"
FIRMWARE_DIR = ROOT / "agnos-firmware"

AGNOS_UPDATE_URL = os.getenv("AGNOS_UPDATE_URL", "https://commadist.azureedge.net/agnosupdate")
AGNOS_STAGING_UPDATE_URL = os.getenv("AGNOS_STAGING_UPDATE_URL", "https://commadist.azureedge.net/agnosupdate-staging")


def checksum(fn: Union[str, Path]) -> str:
  return subprocess.check_output(["sha256sum", fn]).decode().split()[0]


def compress(fin: Path, fout: Path) -> None:
  subprocess.check_call(f"xz -vc {fin} > {fout}", shell=True)


def process_file(fn: Path, name: str, sparse=False, full_check=True, has_ab=True,
                 alt: Optional[Path] = None) -> dict:
  print("Processing", name)
  print("  calculating checksum")
  hash_raw = hash = checksum(fn)
  size = fn.stat().st_size
  print(f"  {size} bytes, hash {hash}")

  if sparse:
    with NamedTemporaryFile() as tmp_f:
      print("  converting sparse image to raw")
      subprocess.check_call(["simg2img", fn, tmp_f.name])
      print("  calculating checksum")
      hash = checksum(tmp_f.name)
      size = Path(tmp_f.name).stat().st_size
      print(f"  {size} bytes, hash {hash}")

  print("  compressing image")
  xz_fn = OTA_OUTPUT_DIR / f"{fn.stem}-{hash_raw}.img.xz"
  compress(fn, xz_fn)

  ret = {
    "name": name,
    "hash": hash,
    "hash_raw": hash_raw,
    "size": size,
    "sparse": sparse,
    "full_check": full_check,
    "has_ab": has_ab,
    "url": "{remote_url}/" + xz_fn.name,
  }

  if alt is not None:
    print("  calculating alt checksum")
    alt_hash = checksum(alt)

    print("  compressing alt image")
    alt_xz_fn = OTA_OUTPUT_DIR / f"{alt.stem}-{hash_raw}.img.xz"
    compress(fn, xz_fn)

    ret["alt"] = {
      "url": "{remote_url}/" + alt_xz_fn.name,
      "hash": alt_hash,
    }

  return ret


if __name__ == "__main__":
  OTA_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

  files = [
    process_file(OUTPUT_DIR / "boot.img", "boot"),
    process_file(FIRMWARE_DIR / "abl.bin", "abl"),
    process_file(FIRMWARE_DIR / "xbl.bin", "xbl"),
    process_file(FIRMWARE_DIR / "xbl_config.bin", "xbl_config"),
    process_file(FIRMWARE_DIR / "devcfg.bin", "devcfg"),
    process_file(FIRMWARE_DIR / "aop.bin", "aop"),
    process_file(OUTPUT_DIR / "system.img", "system", sparse=True, full_check=False, alt=OUTPUT_DIR / "system-skip-chunks.img"),
  ]
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
