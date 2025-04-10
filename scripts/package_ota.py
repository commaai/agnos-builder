#!/usr/bin/env python3
import json
import os
import hashlib
import shutil
import struct
import subprocess
from copy import deepcopy
from pathlib import Path
from collections import namedtuple

ROOT = Path(__file__).parent.parent
OUTPUT_DIR = ROOT / "output"
FIRMWARE_DIR = ROOT / "firmware"
OTA_OUTPUT_DIR = OUTPUT_DIR / "ota"
BUILD_DIR = ROOT / "build"

SECTOR_SIZE = 4096

AGNOS_UPDATE_URL = os.getenv("AGNOS_UPDATE_URL", "https://commadist.azureedge.net/agnosupdate")
AGNOS_STAGING_UPDATE_URL = os.getenv("AGNOS_STAGING_UPDATE_URL", "https://commadist.azureedge.net/agnosupdate-staging")

GPT = namedtuple('GPT', ['lun', 'name', 'path', 'start_sector', 'num_sectors', 'has_ab', 'ota', 'full_check', 'sparse'])
GPTS = [
  GPT(0, 'gpt_main_0', FIRMWARE_DIR / 'gpt_main_0.img', 0, 6, False, False, True, False),
  GPT(1, 'gpt_main_1', FIRMWARE_DIR / 'gpt_main_1.img', 0, 6, False, False, True, False),
  GPT(2, 'gpt_main_2', FIRMWARE_DIR / 'gpt_main_2.img', 0, 6, False, False, True, False),
  GPT(3, 'gpt_main_3', FIRMWARE_DIR / 'gpt_main_3.img', 0, 6, False, False, True, False),
  GPT(4, 'gpt_main_4', FIRMWARE_DIR / 'gpt_main_4.img', 0, 6, False, False, True, False),
  GPT(5, 'gpt_main_5', FIRMWARE_DIR / 'gpt_main_5.img', 0, 6, False, False, True, False),
]

Partition = namedtuple('Partition', ['name', 'path', 'has_ab', 'ota', 'full_check', 'sparse'])
PARTITIONS = [
  Partition('persist', FIRMWARE_DIR / 'persist.img', False, False, True, False),
  Partition('systemrw', FIRMWARE_DIR / 'systemrw.img', False, False, True, False),
  Partition('cache', FIRMWARE_DIR / 'cache.img', False, False, True, False),
  Partition('xbl', FIRMWARE_DIR / 'xbl.img', True, True, True, False),
  Partition('xbl_config', FIRMWARE_DIR / 'xbl_config.img', True, True, True, False),
  Partition('abl', FIRMWARE_DIR / 'abl.img', True, True, True, False),
  Partition('aop', FIRMWARE_DIR / 'aop.img', True, True, True, False),
  Partition('bluetooth', FIRMWARE_DIR / 'bluetooth.img', True, False, True, False),
  Partition('cmnlib64', FIRMWARE_DIR / 'cmnlib64.img', True, False, True, False),
  Partition('cmnlib', FIRMWARE_DIR / 'cmnlib.img', True, False, True, False),
  Partition('devcfg', FIRMWARE_DIR / 'devcfg.img', True, True, True, False),
  Partition('devinfo', FIRMWARE_DIR / 'devinfo.img', False, False, True, False),
  Partition('dsp', FIRMWARE_DIR / 'dsp.img', True, False, True, False),
  Partition('hyp', FIRMWARE_DIR / 'hyp.img', True, False, True, False),
  Partition('keymaster', FIRMWARE_DIR / 'keymaster.img', True, False, True, False),
  Partition('limits', FIRMWARE_DIR / 'limits.img', False, False, True, False),
  Partition('logfs', FIRMWARE_DIR / 'logfs.img', False, False, True, False),
  Partition('modem', FIRMWARE_DIR / 'modem.img', True, False, True, False),
  Partition('qupfw', FIRMWARE_DIR / 'qupfw.img', True, False, True, False),
  Partition('splash', FIRMWARE_DIR / 'splash.img', False, False, True, False),
  Partition('storsec', FIRMWARE_DIR / 'storsec.img', True, False, True, False),
  Partition('tz', FIRMWARE_DIR / 'tz.img', True, False, True, False),
  Partition('boot', OUTPUT_DIR / 'boot.img', True, True, True, False),
  Partition('system', OUTPUT_DIR / 'system.img', True, True, False, True),
  Partition('userdata_90', OUTPUT_DIR / 'userdata_90.img', False, False, True, True),
  Partition('userdata_89', OUTPUT_DIR / 'userdata_89.img', False, False, True, True),
  Partition('userdata_30', OUTPUT_DIR / 'userdata_30.img', False, False, True, True),
]


def file_checksum(fn):
  sha256 = hashlib.sha256()
  with open(fn, 'rb') as f:
    for chunk in iter(lambda: f.read(4096), b""):
      sha256.update(chunk)
  return sha256

def ondevice_checksum_sparse(fn, ota):
  with open(fn, 'rb') as data_source:
    dat = data_source.read(28)
    header = struct.unpack("<I4H4I", dat)

    magic = header[0]
    major_version = header[1]
    minor_version = header[2]
    file_hdr_sz = header[3]
    chunk_hdr_sz = header[4]
    blk_sz = header[5]
    total_chunks = header[7]

    assert magic == 0xED26FF3A
    assert major_version == 1 and minor_version == 0
    assert file_hdr_sz == 28
    assert chunk_hdr_sz == 12
    assert blk_sz == SECTOR_SIZE

    hash_raw = hashlib.sha256()
    ondevice_hash = hashlib.sha256()
    total_size = 0
    for _ in range(total_chunks):
      header_bin = data_source.read(12)

      header = struct.unpack("<2H2I", header_bin)
      chunk_type = header[0]
      chunk_sz = header[2]

      if chunk_type == 0xCAC1: # RAW
        d = data_source.read(chunk_sz * SECTOR_SIZE)
        hash_raw.update(d)
        ondevice_hash.update(d)
        total_size += chunk_sz * SECTOR_SIZE
      elif chunk_type == 0xCAC2: # FILL
        d = data_source.read(4) * (chunk_sz * SECTOR_SIZE // 4)
        if d[:4] != b'\x00\x00\x00\x00': # For ondevice_hash, treat FILL 0 like DONT_CARE
          ondevice_hash.update(d)
        hash_raw.update(d)
        total_size += chunk_sz * SECTOR_SIZE
      elif chunk_type == 0xCAC3: # DONT_CARE
        assert not ota, 'DONT_CARE chunks are currently not supported for OTA'
      else:
        raise Exception(f'UNKNOWN SPARSE CHUNK: {hex(chunk_type)}')

    return hash_raw.hexdigest(), ondevice_hash.hexdigest(), total_size

def compress(fin, fout) -> None:
  # since system.img is a squashfs now, we don't rely on this compression.
  # however, openpilot's updater still expects an xz archive, so use lowest
  # compression level for quick packaging.
  subprocess.check_call(f"xz -0 -T0 -vc {fin} > {fout}", shell=True)


def process_file(entry):
  size = entry.path.stat().st_size
  print(f"\n{entry.name} {size} bytes")

  sha256 = file_checksum(entry.path)
  hash = hash_raw = sha256.hexdigest()

  if struct.unpack("<I", open(entry.path, 'rb').read(4))[0] == 0xED26FF3A:
    hash_raw, ondevice_hash, size = ondevice_checksum_sparse(entry.path, entry.ota)
  else:
    sha256.update(b'\x00' * ((SECTOR_SIZE - (size % SECTOR_SIZE)) % SECTOR_SIZE))
    ondevice_hash = sha256.hexdigest()

  print("  compressing")
  xz_fn = OTA_OUTPUT_DIR / f"{entry.path.stem}-{hash_raw}.img.xz"
  compress(entry.path, xz_fn)

  ret = {
    "name": entry.name,
    "url": "{remote_url}/" + xz_fn.name,
    "hash": hash,
    "hash_raw": hash_raw, # for sparse image, this is not the hash of the raw file
    "size": size, # for sparse image, this is not the size of the raw file
    "sparse": entry.sparse,
    "full_check": entry.full_check,
    "has_ab": entry.has_ab,
    "ondevice_hash": ondevice_hash,
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
