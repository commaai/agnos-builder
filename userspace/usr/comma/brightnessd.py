#!/usr/bin/env python3
import time

# limit display brightness with display uptime to prevent burn in

BL_OFF = 4
BL_POWER_PATH = "/sys/class/backlight/panel0-backlight/bl_power"
BRIGHTNESS_PATH = "/sys/class/backlight/panel0-backlight/brightness"
MAX_BRIGHTNESS_PATH= "/sys/devices/platform/soc/soc:qcom,dsi-display@0/max_brightness_percent"

MAX_PERCENT = 90
MIN_PERCENT = 30
HOURLY_PERC_DECREASE = 5

IGNORED_PANELS = [
  "dsi_mate10_lite_video_display",
]

def read(path: str) -> int:
  try:
    with open(path) as f:
      return int(f.read())
  except Exception:
    return 0


if __name__ == "__main__":

  # detect panel type
  with open("/sys/module/msm_drm/parameters/dsi_display0") as f:
    d = f.read().strip()
    panel = d.split(":")[0]

  print(f"Detected panel '{panel}'")
  if panel in IGNORED_PANELS:
    print("panel is ignored, exiting")
    exit(0)

  # brightness loop
  last_perc = None
  last_off_ts = time.monotonic()
  while True:
    try:
      # sample brightness and backlight power
      bl_power = read(BL_POWER_PATH)
      brightness = read(BRIGHTNESS_PATH)
      if bl_power == BL_OFF or brightness == 0:
        last_off_ts = time.monotonic()

      # calculate new max
      uptime_hours = (time.monotonic() - last_off_ts) / (60*60)
      clipped_perc = MAX_PERCENT - (HOURLY_PERC_DECREASE*uptime_hours)
      clipped_perc = int(max(min(clipped_perc, MAX_PERCENT), MIN_PERCENT))

      if clipped_perc != last_perc:
        with open(MAX_BRIGHTNESS_PATH, 'w') as f:
          f.write(f"{int(clipped_perc)}\n")
      last_perc = clipped_perc
    except Exception:
      pass

    time.sleep(5)
