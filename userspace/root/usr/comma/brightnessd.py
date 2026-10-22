#!/usr/bin/env python3
import time
from pathlib import Path

# limit display brightness with display uptime to prevent burn in

BL_OFF = 4
BACKLIGHT_PATH = Path("/sys/class/backlight/ae94000.dsi.0")
LIMIT_PATH = Path("/run/brightness/max_percent")

MAX_PERCENT = 90
MIN_PERCENT = 30
HOURLY_PERC_DECREASE = 5

def read(path: Path) -> int:
  return int(path.read_text())


def limit_brightness(last_off_ts: float, now: float) -> float:
  bl_power = read(BACKLIGHT_PATH / "bl_power")
  brightness = read(BACKLIGHT_PATH / "brightness")
  if bl_power == BL_OFF or brightness == 0:
    last_off_ts = now

  uptime_hours = (now - last_off_ts) / (60*60)
  percent = int(max(MAX_PERCENT - HOURLY_PERC_DECREASE*uptime_hours, MIN_PERCENT))
  # Openpilot applies this cap to each request. Atomic replacement prevents a
  # reader from seeing an empty file while the cap changes.
  temporary = LIMIT_PATH.with_suffix(".tmp")
  temporary.write_text(f"{percent}\n")
  temporary.replace(LIMIT_PATH)

  maximum = read(BACKLIGHT_PATH / "max_brightness") * percent // 100
  if brightness > maximum:
    (BACKLIGHT_PATH / "brightness").write_text(f"{maximum}\n")
  return last_off_ts


if __name__ == "__main__":
  last_off_ts = time.monotonic()
  while True:
    try:
      last_off_ts = limit_brightness(last_off_ts, time.monotonic())
    except Exception:
      pass

    time.sleep(5)
