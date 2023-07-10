#!/usr/bin/env python3
import datetime
import os
import sys
from pathlib import Path

here = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, here)
from panda import Panda

# Systemd pushes the system time to the systemd build time if no time is set
MIN_DATE = datetime.datetime.fromtimestamp(Path("/lib/systemd/systemd").stat().st_mtime)
MIN_DATE += datetime.timedelta(days=1)

if __name__ == "__main__":
  sys_time = datetime.datetime.today()
  print(f"System time: {sys_time}")
  if sys_time > MIN_DATE:
    print("System time valid")
    exit()

  ps = Panda.list()
  if len(ps) == 0:
    print("Failed to set time, no pandas found")
    exit()

  for s in ps:
    with Panda(serial=s) as p:
      if not p.is_internal():
        continue

      # Set system time from panda RTC time
      panda_time = p.get_datetime()
      print(f"panda time: {panda_time}")
      if panda_time > MIN_DATE:
        print(f"adjusting time from '{sys_time}' to '{panda_time}'")
        os.system(f"TZ=UTC date -s '{panda_time}'")
      else:
        print("panda time invalid")
      break
  else:
    print("No internal pandas found")
