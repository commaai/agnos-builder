#!/usr/bin/env python3
import os
import time
import uinput
import watchfiles

# our weston doesn't have control over power and idle states aside
# from input devices. this daemon fakes input to emulate 

BL_PATH = "/sys/class/backlight/panel0-backlight/"

def read_file(fn: str) -> str:
  try:
    with open(fn) as f:
      return f.read().strip()
  except Exception:
    print(f"Failed to read {fn}: {str(e)}")


if __name__ == "__main__":
  # TODO: fix this properly
  os.system("sudo chmod 666 /dev/uinput")

  events = (uinput.KEY_E, )
  device = uinput.Device(events)
  while True:
    bl_power = read_file(BL_PATH + "bl_power")
    brightness = read_file(BL_PATH + "brightness")
    print(f"{bl_power=}, {brightness=}")

    if bl_power == "4" and brightness == "0":
      # let weston go to idle
      pass
    else:
      # should be on
      device.emit_click(uinput.KEY_E)
    time.sleep(2)
