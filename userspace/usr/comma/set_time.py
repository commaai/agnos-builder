#!/usr/bin/env python3
import datetime
import os
import struct
import usb1
from pathlib import Path

REQUEST_IN = usb1.ENDPOINT_IN | usb1.TYPE_VENDOR | usb1.RECIPIENT_DEVICE

# Systemd pushes the system time to the systemd build time if no time is set
MIN_DATE = datetime.datetime.fromtimestamp(Path("/lib/systemd/systemd").stat().st_mtime)
MIN_DATE += datetime.timedelta(days=1)

if __name__ == "__main__":
  ctx = usb1.USBContext()
  dev = ctx.openByVendorIDAndProductID(0xbbaa, 0xddcc)
  if dev is None:
    print("No panda found")
    exit()

  # Set system time from panda RTC time
  dat = dev.controlRead(REQUEST_IN, 0xa0, 0, 0, 8)
  a = struct.unpack("HBBBBBB", dat)
  panda_time = datetime.datetime(a[0], a[1], a[2], a[4], a[5], a[6])
  sys_time = datetime.datetime.today()
  if panda_time > MIN_DATE and sys_time < MIN_DATE:
    print(f"adjusting time from '{sys_time}' to '{panda_time}'")
    os.system(f"TZ=UTC date -s '{panda_time}'")
