#!/usr/bin/env python3
import os
import time

# limit display brightness with display uptime to prevent burn in

BL_OFF = 4
BL_POWER_PATH = "/sys/devices/platform/soc/ae00000.qcom,mdss_mdp/backlight/panel0-backlight/bl_power"
BRIGHTNESS_PATH = "/sys/devices/platform/soc/ae00000.qcom,mdss_mdp/backlight/panel0-backlight/brightness"
CLIPPED_BRIGHTNESS_PATH = "/sys/devices/platform/soc/soc:qcom,dsi-display@0/clipped_brightness"

MAX_PERCENT = 90
MIN_PERCENT = 30
HOURLY_PERC_DECREASE = 5
MAX_BRIGHTNESS = 1024

def read(path: str) -> int:
  try:
    with open(path) as f:
      return int(f.read())
  except Exception:
    return 0


if __name__ == "__main__":

  last_off_ts = time.monotonic()

  while True:
    try:
      # sample brightness and backlight power
      bl_power = read(BL_POWER_PATH)
      brightness = read(BRIGHTNESS_PATH)
      if bl_power == BL_OFF or brightness == 0:
        last_off_ts = time.monotonic()

      # calculate new max
      uptime_hours = (time.monotonic() - last_off_ts) / 60*60
      clipped_perc = MAX_PERCENT - (HOURLY_PERC_DECREASE*uptime_hours)
      clipped_perc = max(min(clipped_perc, MAX_PERCENT), MIN_PERCENT)

      clipped_brightness = int(MAX_BRIGHTNESS * clipped_perc / 100)
      with open(CLIPPED_BRIGHTNESS_PATH, 'w') as f:
        f.write(f"{clipped_brightness}\n")
    except Exception:
      pass

    time.sleep(5)
