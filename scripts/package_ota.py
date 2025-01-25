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

# Structure: (lun, partition_name, filename, start_sector, num_sectors)
PARTITION_TABLES = [
  (0, 'gpt_main_0', 'gpt_main_0.bin', 0, 6),
  (1, 'gpt_main_1', 'gpt_main_1.bin', 0, 6),
  (2, 'gpt_main_2', 'gpt_main_2.bin', 0, 6),
  (3, 'gpt_main_3', 'gpt_main_3.bin', 0, 6),
  (4, 'gpt_main_4', 'gpt_main_4.bin', 0, 6),
  (5, 'gpt_main_5', 'gpt_main_5.bin', 0, 6),
]

# Structure: (partition_name, filename, has_ab)
QDL_FLASH_ARRAY = [
  ('persist', 'persist.bin', False),
  ('systemrw', 'systemrw.bin', False),
  ('cache', 'cache.bin', False),
  ('xbl', 'xbl.bin', True),
  ('xbl_config', 'xbl_config.bin', True),
  ('abl', 'abl.bin', True),
  ('aop', 'aop.bin', True),
  ('bluetooth', 'bluetooth.bin', True),
  ('cmnlib64', 'cmnlib64.bin', True),
  ('cmnlib', 'cmnlib.bin', True),
  ('devcfg', 'devcfg.bin', True),
  ('devinfo', 'devinfo.bin', False),
  ('dsp', 'dsp.bin', True),
  ('hyp', 'hyp.bin', True),
  ('keymaster', 'keymaster.bin', True),
  ('limits', 'limits.bin', False),
  ('logfs', 'logfs.bin', False),
  ('modem', 'modem.bin', True),
  ('qupfw', 'qupfw.bin', True),
  ('splash', 'splash.bin', False),
  ('storsec', 'storsec.bin', True),
  ('tz', 'tz.bin', True),
]


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


def process_file(fn, name, full_check=True, has_ab=True, gpt=False, lun=0, start_sector=0, num_sectors=0):
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

  if gpt:
    ret["gpt"] = {
      "lun": lun,
      "start_sector": start_sector,
      "num_sectors": num_sectors,
    }

  return ret


if __name__ == "__main__":
  OTA_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

  files = [
    process_file(OUTPUT_DIR / "boot.img", "boot"),
    process_file(OUTPUT_DIR / "system.img", "system", full_check=False),
  ]

  for (name, fn, has_ab) in QDL_FLASH_ARRAY:
    files.append(process_file(FIRMWARE_DIR / fn, name, has_ab))

  for (lun, name, fn, start_sector, num_sectors) in PARTITION_TABLES:
    files.append(process_file(FIRMWARE_DIR / fn, name, has_ab=False, gpt=True, lun=lun, start_sector=start_sector, num_sectors=num_sectors))

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
