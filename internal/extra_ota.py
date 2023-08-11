#!/usr/bin/env python3
import argparse
import json
import sys
from typing import cast, Dict, List, Union
from pathlib import Path

ROOT = Path(__file__).parent.parent
OTA_DIR = ROOT / "output" / "ota"

sys.path.append(str(ROOT / "tools"))

Manifest = List[Dict[str, Union[str, int, bool]]]


def main(ota: Manifest) -> None:
  import simg2dontcare

  extras: Manifest = []

  for image in ota:
    name = cast(str, image["name"])

    print(f"Processing {name}...")

    if name == "system":
      # TODO: Optimize system image
      # simg2dontcare.process_image()
      pass

    # TODO: Compress image (gzip)
    pass

  with open(OTA_DIR / "extra.json", "w", encoding="utf-8") as f:
    json.dump(extras, f, indent=2, ensure_ascii=False)


if __name__ == "__main__":
  parser = argparse.ArgumentParser(description="Generate extra.json from ota.json manifest for flash tool")
  parser.add_argument("production", action="store_true")
  args = parser.parse_args()

  try:
    ota_file = f"ota-{'' if args.production else 'staging'}.json"
    with open(OTA_DIR / ota_file, "r", encoding="utf-8") as f:
      ota_json = json.load(f)
  except FileNotFoundError:
    print(f"File not found: {args.ota_json}")
    sys.exit(1)
  except json.JSONDecodeError:
    print(f"Invalid JSON file: {args.ota_json}")
    sys.exit(1)

  main(ota_json)
