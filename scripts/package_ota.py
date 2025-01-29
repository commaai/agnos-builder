#!/usr/bin/env python3
import json
import os
import hashlib
import shutil
import subprocess
from copy import deepcopy
from pathlib import Path
from collections import namedtuple

ROOT = Path(__file__).parent.parent
OUTPUT_DIR = ROOT / "output"
FIRMWARE_DIR = ROOT / "firmware"
OTA_OUTPUT_DIR = OUTPUT_DIR / "ota"
BUILD_DIR = ROOT / "build"

AGNOS_UPDATE_URL = os.getenv("AGNOS_UPDATE_URL", "https://commadist.azureedge.net/agnosupdate")
AGNOS_STAGING_UPDATE_URL = os.getenv("AGNOS_STAGING_UPDATE_URL", "https://commadist.azureedge.net/agnosupdate-staging")

GPT = namedtuple('GPT', ['lun', 'name', 'path', 'start_sector', 'num_sectors', 'has_ab', 'ota', 'full_check'])
GPTS = [
  GPT(0, 'gpt_main_0', FIRMWARE_DIR / 'gpt_main_0.bin', 0, 6, False, False, True),
  GPT(1, 'gpt_main_1', FIRMWARE_DIR / 'gpt_main_1.bin', 0, 6, False, False, True),
  GPT(2, 'gpt_main_2', FIRMWARE_DIR / 'gpt_main_2.bin', 0, 6, False, False, True),
  GPT(3, 'gpt_main_3', FIRMWARE_DIR / 'gpt_main_3.bin', 0, 6, False, False, True),
  GPT(4, 'gpt_main_4', FIRMWARE_DIR / 'gpt_main_4.bin', 0, 6, False, False, True),
  GPT(5, 'gpt_main_5', FIRMWARE_DIR / 'gpt_main_5.bin', 0, 6, False, False, True),
]

Partition = namedtuple('Partition', ['name', 'path', 'has_ab', 'ota', 'full_check'])
PARTITIONS = [
  Partition('persist', FIRMWARE_DIR / 'persist.bin', False, False, True),
  Partition('systemrw', FIRMWARE_DIR / 'systemrw.bin', False, False, True),
  Partition('cache', FIRMWARE_DIR / 'cache.bin', False, False, True),
  Partition('xbl', FIRMWARE_DIR / 'xbl.bin', True, True, True),
  Partition('xbl_config', FIRMWARE_DIR / 'xbl_config.bin', True, True, True),
  Partition('abl', FIRMWARE_DIR / 'abl.bin', True, True, True),
  Partition('aop', FIRMWARE_DIR / 'aop.bin', True, True, True),
  Partition('bluetooth', FIRMWARE_DIR / 'bluetooth.bin', True, False, True),
  Partition('cmnlib64', FIRMWARE_DIR / 'cmnlib64.bin', True, False, True),
  Partition('cmnlib', FIRMWARE_DIR / 'cmnlib.bin', True, False, True),
  Partition('devcfg', FIRMWARE_DIR / 'devcfg.bin', True, True, True),
  Partition('devinfo', FIRMWARE_DIR / 'devinfo.bin', False, False, True),
  Partition('dsp', FIRMWARE_DIR / 'dsp.bin', True, False, True),
  Partition('hyp', FIRMWARE_DIR / 'hyp.bin', True, False, True),
  Partition('keymaster', FIRMWARE_DIR / 'keymaster.bin', True, False, True),
  Partition('limits', FIRMWARE_DIR / 'limits.bin', False, False, True),
  Partition('logfs', FIRMWARE_DIR / 'logfs.bin', False, False, True),
  Partition('modem', FIRMWARE_DIR / 'modem.bin', True, False, True),
  Partition('qupfw', FIRMWARE_DIR / 'qupfw.bin', True, False, True),
  Partition('splash', FIRMWARE_DIR / 'splash.bin', False, False, True),
  Partition('storsec', FIRMWARE_DIR / 'storsec.bin', True, False, True),
  Partition('tz', FIRMWARE_DIR / 'tz.bin', True, False, True),
  Partition('boot', OUTPUT_DIR / 'boot.img', True, False, True),
  Partition('system', OUTPUT_DIR / 'system.img', True, False, False),
  Partition('userdata', OUTPUT_DIR / 'userdata_90.img', True, False, True),
  Partition('userdata', OUTPUT_DIR / 'userdata_89.img', True, False, True),
  Partition('userdata', OUTPUT_DIR / 'userdata_30.img', True, False, True),
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


def process_file(entry):
  print(entry.name)
  hash_raw = hash = checksum(entry.path)
  size = entry.path.stat().st_size
  print(f"  {size} bytes, hash {hash}")

  print("  compressing")
  xz_fn = OTA_OUTPUT_DIR / f"{entry.path.stem}-{hash_raw}.img.xz"
  compress(entry.path, xz_fn)

  ret = {
    "name": entry.name,
    "url": "{remote_url}/" + xz_fn.name,
    "hash": hash,
    "hash_raw": hash_raw,
    "size": size,
    "sparse": False,
    "full_check": entry.full_check,
    "has_ab": entry.has_ab,
  }

  if entry.name == "system":
    ret["alt"] = {
      "hash": hash_raw,
      "url": "{remote_url}/" + xz_fn.name.replace(".img.xz", ".img"),
      "size": size,
    }
    shutil.copy(entry.path, OTA_OUTPUT_DIR / f"{entry.path.stem}-{hash_raw}.img")

  if isinstance(entry, GPT):
    ret["gpt"] = {
      "lun": entry.lun,
      "start_sector": entry.start_sector,
      "num_sectors": entry.num_sectors,
    }

  return ret


if __name__ == "__main__":
  OTA_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

  files = [(process_file(x), x.ota) for x in GPTS + PARTITIONS]

  configs = [
    # URL, file name, only OTA partitions
    (AGNOS_UPDATE_URL, "ota.json", True),
    (AGNOS_STAGING_UPDATE_URL, "ota-staging.json", True),
    (AGNOS_UPDATE_URL, "all-partitions.json", False),
    (AGNOS_STAGING_UPDATE_URL, "all-partitions-staging.json", False),
  ]
  for remote_url, output_fn, only_ota in configs:
    processed_files = []
    for f, ota in deepcopy(files):
      if only_ota and not ota:
        continue
      f["url"] = f["url"].format(remote_url=remote_url)
      if "alt" in f:
        f["alt"]["url"] = f["alt"]["url"].format(remote_url=remote_url)
      processed_files.append(f)

    with open(OTA_OUTPUT_DIR / output_fn, "w") as out:
      json.dump(processed_files, out, indent=2)

  print("Done")
