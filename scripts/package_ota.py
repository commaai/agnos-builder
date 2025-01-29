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

GPT = namedtuple('GPT', ['lun', 'name', 'path', 'start_sector', 'num_sectors', 'ondevice_hash', 'has_ab', 'ota', 'full_check'])
GPTS = [
  GPT(0, 'gpt_main_0', FIRMWARE_DIR / 'gpt_main_0.bin', 0, 6, '8928A31FD9EE20F8703649F89833EBA9B55E84B6415E67799C777B163C95A0BD', False, False, True),
  GPT(1, 'gpt_main_1', FIRMWARE_DIR / 'gpt_main_1.bin', 0, 6, 'FE8EF7653DB588D7420A625920CA06927DFCB0ED8AFF3E3A1C74A52A24398BA6', False, False, True),
  GPT(2, 'gpt_main_2', FIRMWARE_DIR / 'gpt_main_2.bin', 0, 6, '5CCFC7240C8CBFA2F1A018A2E376CF274A6BAF858C9BFE71951D8E28CAB53C21', False, False, True),
  GPT(3, 'gpt_main_3', FIRMWARE_DIR / 'gpt_main_3.bin', 0, 6, 'C707979FA21E89519328F4F30C2B21C9C453401CA8303F914C1873D410A95159', False, False, True),
  GPT(4, 'gpt_main_4', FIRMWARE_DIR / 'gpt_main_4.bin', 0, 6, 'E9405DCD785DBE79412184E1894A9C51AB7DEB33BB612166C4C42A3D2BF42A0E', False, False, True),
  GPT(5, 'gpt_main_5', FIRMWARE_DIR / 'gpt_main_5.bin', 0, 6, '21AE965F05B2FA8D02E04F1EB74718F9779864F6EACDEB859757D6435E8CCCE3', False, False, True),
]

Partition = namedtuple('Partition', ['name', 'path', 'ondevice_hash', 'has_ab', 'ota', 'full_check'])
PARTITIONS = [
  Partition('persist', FIRMWARE_DIR / 'persist.bin', '9814B07851292F510F3794B767489F38AB379A99F0EA75DC620AD2D3A496D54D', False, False, True),
  Partition('systemrw', FIRMWARE_DIR / 'systemrw.bin', '8CE150CA38EF64A0885FC2FE816E5B63BAE8ADB4DF5D809C5B318E6996366C7E', False, False, True),
  Partition('cache', FIRMWARE_DIR / 'cache.bin', 'EBFBAAA2F96DC4E5FEA4F126364E5BF5B3B44C12CBC753B62FDD8BAAB82F70B4', False, False, True),
  Partition('xbl', FIRMWARE_DIR / 'xbl.bin', 'CA12B2A003D872404C94C3A875FE608B93B56C3FE3EE39BDD1EDFFE5F3A3B73C', True, True, True),
  Partition('xbl_config', FIRMWARE_DIR / 'xbl_config.bin', 'CBD2FD9BFA0D4828720A9D40A693FCA0F5841AA3934A8300156E5AE57311AC75', True, True, True),
  Partition('abl', FIRMWARE_DIR / 'abl.bin', '0084FCF79FEA067632A1C2D9519B6445AD484AA8B09F49F22E6B45B4DCCACD2D', True, True, True),
  Partition('aop', FIRMWARE_DIR / 'aop.bin', 'CD30E2DDB8F4A57640897A424E173B1D0679628D9524D5A7EAE792352C1537CE', True, True, True),
  Partition('bluetooth', FIRMWARE_DIR / 'bluetooth.bin', '9BB766D2D2CE0CC4491664B3010FE1EF62F8FFC1E362D55F78E48C4141F75533', True, False, True),
  Partition('cmnlib64', FIRMWARE_DIR / 'cmnlib64.bin', '1A876BD151BB9635F18719C4A17F953079DE6E11D3EAEC800968FC75669E0DC3', True, False, True),
  Partition('cmnlib', FIRMWARE_DIR / 'cmnlib.bin', '63DF823E8A5FAE01D66CB2B8C20F0D2DDB5C5F2425E5D0992A64676273BA1C82', True, False, True),
  Partition('devcfg', FIRMWARE_DIR / 'devcfg.bin', 'F65FFD35D01A527802585238F8BA40DE4FC5A87BB066E256FDC4B6CFF8C79788', True, True, True),
  Partition('devinfo', FIRMWARE_DIR / 'devinfo.bin', '143869C499A7E878FBEAB756E9C53074195770CC41D6D0D10E45C043141389A3', False, False, True),
  Partition('dsp', FIRMWARE_DIR / 'dsp.bin', '4B15FBD2F45581F1553F33F01649E450B24AA19D5DEFF2AC7DCB16A534D9C248', True, False, True),
  Partition('hyp', FIRMWARE_DIR / 'hyp.bin', 'FF5ECE6A4E3D2B4D898C77FFE193FC8BBC8ACEBE78263996ECF52373D8088927', True, False, True),
  Partition('keymaster', FIRMWARE_DIR / 'keymaster.bin', '5C968C76F29B9A4D66FBE57E639BAC6B7A2C83B1758E25ABBAF5D276B8A6AF04', True, False, True),
  Partition('limits', FIRMWARE_DIR / 'limits.bin', '94951A0F7AA55FB6CB975535CE4EBBFE6D695F04CB5424677B01C10DFA2E94E1', False, False, True),
  Partition('logfs', FIRMWARE_DIR / 'logfs.bin', 'B8B5AC87F3D954404FC7ECBDD9EE3B5B0CF5691E5006E6EC55DB4C899FF61220', False, False, True),
  Partition('modem', FIRMWARE_DIR / 'modem.bin', 'A3D014F0896D77A2DF7E5A80A70F43A51A047B9D03CFC675B6F0E31A6ECC4994', True, False, True),
  Partition('qupfw', FIRMWARE_DIR / 'qupfw.bin', '64CC7C29D5D69B04267452B8B4DDBA9F4809E68F476FC162CA283F58537AFE4A', True, False, True),
  Partition('splash', FIRMWARE_DIR / 'splash.bin', '5C61260048F22EDE6E6343FABB27F6FF73F9271F4751A01AAF7ABF097AFC1F08', False, False, True),
  Partition('storsec', FIRMWARE_DIR / 'storsec.bin', '4494D86F68B125FBF2C004C824B1C6DBE71E61A65D2A1CC7DB13C553EDCB3FCE', True, False, True),
  Partition('tz', FIRMWARE_DIR / 'tz.bin', 'E9443BF187641661BFA6C96702B9AB0156E72FB7482500F8799BA9EE2503CB16', True, False, True),
  Partition('boot', OUTPUT_DIR / 'boot.img', 'C848B8CD26A15EC884E90534E1591F860F194495E2B01E887846C9EC699696CF', True, False, True),
  Partition('system', OUTPUT_DIR / 'system.img', '95C5A47F7B3C93B37513356AA36CA1CF7941F941E9461462E796E2E4AFA1B919', True, False, False),
  Partition('userdata', OUTPUT_DIR / 'userdata_90.img', '9940672129B2E049BEB879A62B7D73F957003FC8A2FBE74C2D4A4CC01BFB62E6', True, False, True),
  Partition('userdata', OUTPUT_DIR / 'userdata_89.img', '699AA5918DCBAC98EE4EFFA1FA5CBC20EE4447C5F85DB4892D10198EE571C879', True, False, True),
  Partition('userdata', OUTPUT_DIR / 'userdata_30.img', 'DE7625C4143C7769DB86F1E6913053120A2A0A5CA24F4EB634B2C2D1474BD20A', True, False, True),
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
    "ondevice_hash": entry.ondevice_hash,
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
