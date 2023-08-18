#!/usr/bin/env python3
import os
import json

HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.path.join(HERE, "..")
OUTPUT_DIR = os.path.join(ROOT, "output")
OTA_OUTPUT_DIR = os.path.join(OUTPUT_DIR, "ota")
FIRMWARE_DIR = os.path.join(ROOT, "agnos-firmware")

def process_file(fn, name, sparse=False, full_check=True, has_ab=True, alt=None):
  fn = os.path.join(OUTPUT_DIR, fn)
  ret = {
    "name": name,
    "hash": "TODO",
    "hash_raw": "TODO",
    "size": os.path.getsize(fn),
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
    ("https://commadist.azureedge.net/agnosupdate", "ota.json"),
    ("https://commadist.azureedge.net/agnosupdate-staging", "ota-staging.json"),
  ]
  for remote_url, output_fn in configs:
    files = [
      process_file(os.path.join(OUTPUT_DIR, "boot.img"), "boot"),
      process_file(os.path.join(FIRMWARE_DIR, "abl.bin"), "abl"),
      process_file(os.path.join(FIRMWARE_DIR, "xbl.bin"), "xbl"),
      process_file(os.path.join(FIRMWARE_DIR, "xbl_config.bin"), "xbl_config"),
      process_file(os.path.join(FIRMWARE_DIR, "devcfg.bin"), "devcfg"),
      process_file(os.path.join(FIRMWARE_DIR, "aop.bin"), "aop"),
      process_file(os.path.join(OUTPUT_DIR, "system.img"), "system", sparse=True, full_check=False),
    ]
    with open(os.path.join(OTA_OUTPUT_DIR, output_fn), "w") as f:
      f.write(json.dumps(files, indent=2))
