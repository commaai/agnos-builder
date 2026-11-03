#!/usr/bin/env python3

import os
import struct

GAMMA_CURVES_FILE = "/persist/comma/dwo_gamma_curves"
# the panel driver loads this as /lib/firmware/comma/dwo-do0200fat07-gamma.bin the first time it powers on with it there
FIRMWARE_FILE = "/run/panel-firmware/dwo-do0200fat07-gamma.bin"

if __name__ == "__main__":
  if not os.path.exists(GAMMA_CURVES_FILE):
    print("No gamma curves found")
    exit(0)

  with open(GAMMA_CURVES_FILE, "r") as f:
    gamma = [[int(x, 16) for x in l.strip().split()] for l in f]

  # 3 channels of 25 big-endian points. packed first, so bad curves leave no file
  data = struct.pack(">75H", *sum(gamma, []))
  os.makedirs(os.path.dirname(FIRMWARE_FILE), exist_ok=True)
  with open(FIRMWARE_FILE, "wb") as f:
    f.write(data)
  print("Successfully setup screen calibration")
