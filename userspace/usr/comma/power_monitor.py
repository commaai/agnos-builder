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
timestamps = {}


def read(path: str, num: bool = False):
  try:
    with open(path) as f:
      if num:
        return float(f.read())
      return f.read()
  except Exception:
    return 0 if num else ""


def check_touches():
  global timestamps

  event_format = "llHHi"
  event_size = struct.calcsize(event_format)

  with open("/dev/input/by-path/platform-894000.i2c-event", "rb") as event_file:
    fcntl.fcntl(event_file, fcntl.F_SETFL, os.O_NONBLOCK)
    while True:
      while (event := event_file.read(event_size)):
        (sec, usec, etype, code, value) = struct.unpack(event_format, event)
        if etype != 0 or code != 0 or value != 0:
          timestamps['touch'] = time.monotonic()
      time.sleep(60)

def ssh_active():
  p = subprocess.run("ss | grep ssh", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
  return p.returncode == 0

if __name__ == "__main__":
  # we limit worst-case power usage when openpilot isn't managing it,
  # e.g. while building or during setup.

  threading.Thread(target=check_touches, daemon=True).start()

  timestamps['startup'] = time.monotonic()
  while True:
    timestamps['watchdog'] = read(FN, True)
    if ssh_active():
      timestamps['ssh'] = time.monotonic()
    if read("/data/params/d/IsEngaged").startswith("1"):
      timestamps['engaged'] = time.monotonic()

    # time to shutoff?
    dt = timedelta(seconds=time.monotonic() - max(timestamps.values()))
    if dt > THRESHOLD:
      os.system("sudo poweroff")

    print((THRESHOLD - dt), "until shutdown", f"/ {timestamps=}")
    time.sleep(60)
