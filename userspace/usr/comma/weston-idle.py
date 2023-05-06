#!/usr/bin/env python3
import uinput
from watchfiles import watch

# our weston only uses input devices to manage its idle and power
# states. this daemon fakes input to manage the idle state, matching
# the requested state from the display brightness

INPUT = uinput.KEY_BRIGHTNESS_ZERO
BRIGHTNESS = "/sys/devices/platform/soc/ae00000.qcom,mdss_mdp/backlight/panel0-backlight/brightness"

def read_file(fn: str) -> str:
  try:
    with open(fn) as f:
      return f.read().strip()
  except Exception as e:
    print(f"Failed to read {fn}: {str(e)}")
  return ""


if __name__ == "__main__":
  device = uinput.Device([INPUT, ])
  for _ in watch(BRIGHTNESS, debounce=0, step=0, rust_timeout=2*1000, yield_on_timeout=True):
    brightness = read_file(BRIGHTNESS)
    if brightness == "0":
      # let weston go to idle
      pass
    else:
      # should be on
      device.emit_click(INPUT)
