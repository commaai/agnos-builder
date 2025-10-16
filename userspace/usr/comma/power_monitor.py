#!/usr/bin/env python3
import os
import time
import fcntl
import struct
import threading
import subprocess
from datetime import timedelta

FN = "/var/tmp/power_watchdog"
THRESHOLD = timedelta(hours=1.0)


def read(path: str, num: bool = False):
  try:
    with open(path) as f:
      if num:
        return float(f.read())
      return f.read()
  except Exception:
    return 0 if num else ""


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

def ssh_active():
  p = subprocess.run("ss | grep ssh", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
  return p.returncode == 0

if __name__ == "__main__":
  # we limit worst-case power usage when openpilot isn't managing it,
  # e.g. while building or during setup.

  threading.Thread(target=check_touches, daemon=True).start()

  last_valid_readout = time.monotonic()
  while True:
    cur_t = read(FN, True)
    last_valid_readout = max(last_valid_readout, last_touch_ts, cur_t)
    if ssh_active():
      last_valid_readout = cur_t

    not_engaged = not read("/data/params/d/IsEngaged").startswith("1")

    # time to shutoff?
    dt = timedelta(seconds=time.monotonic() - last_valid_readout)
    if dt > THRESHOLD and not_engaged:
      os.system("sudo poweroff")

    print((THRESHOLD - dt), "until shutdown", "/ not engaged:", not_engaged)
    time.sleep(60)
