#!/usr/bin/env python3
import os
import time
import fcntl
import struct
import threading
from datetime import timedelta

FN = "/var/tmp/power_watchdog"
THRESHOLD = timedelta(hours=1.0)


def read(path: str) -> int:
  try:
    with open(path) as f:
      return float(f.read())
  except Exception:
    raise
    return 0


last_touch_ts = 0
def check_touches():
  global last_touch_ts

  event_format = "llHHi"
  event_size = struct.calcsize(event_format)

  with open("/dev/input/by-path/platform-894000.i2c-event", "rb") as event_file:
    fcntl.fcntl(event_file, fcntl.F_SETFL, os.O_NONBLOCK)
    while True:
      while (event := event_file.read(event_size)):
        (sec, usec, etype, code, value) = struct.unpack(event_format, event)
        if etype != 0 or code != 0 or value != 0:
          last_touch_ts = time.monotonic()
      time.sleep(60)


if __name__ == "__main__":
  # we limit worst-case power usage when openpilot isn't managing it,
  # e.g. while building or during setup.

  threading.Thread(target=check_touches, daemon=True).start()

  last_valid_readout = time.monotonic()
  while True:
    cur_t = read(FN)
    last_valid_readout = max(last_valid_readout, last_touch_ts, cur_t)

    # time to shutoff?
    dt = timedelta(seconds=time.monotonic() - last_valid_readout)
    if dt > THRESHOLD:
      os.system("sudo poweroff")

    #print((THRESHOLD - dt), "until shutdown")
    time.sleep(60)
