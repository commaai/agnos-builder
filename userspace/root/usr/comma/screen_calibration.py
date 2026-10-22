#!/usr/bin/env python3

import struct
from pathlib import Path

GAMMA_CURVES_FILE = Path("/persist/comma/dwo_gamma_curves")
FIRMWARE_FILE = Path("/run/panel-firmware/dwo-do0200fat07-gamma.bin")


def pack_gamma(text: str) -> bytes:
  gamma = [[int(value, 16) for value in line.split()] for line in text.splitlines() if line.strip()]
  if len(gamma) != 3 or any(len(channel) != 25 for channel in gamma):
    raise ValueError("Expected three channels of 25 gamma points")
  values = [point for channel in gamma for point in channel]
  if any(point < 0 or point > 0xffff for point in values):
    raise ValueError("Gamma points must fit in 16 bits")
  return struct.pack(">75H", *values)


if __name__ == "__main__":
  FIRMWARE_FILE.unlink(missing_ok=True)
  if not GAMMA_CURVES_FILE.exists():
    print("No gamma curves found")
  else:
    data = pack_gamma(GAMMA_CURVES_FILE.read_text())
    temporary = FIRMWARE_FILE.with_suffix(".tmp")
    temporary.write_bytes(data)
    temporary.replace(FIRMWARE_FILE)
    print("Staged screen calibration firmware")
