#!/usr/bin/env python3
import glob
import select
import time

# limit display brightness with display uptime to prevent burn in

BL_OFF = 4

MAX_PERCENT = 90
MIN_PERCENT = 30
HOURLY_PERC_DECREASE = 5

def read(path: str) -> int:
  try:
    with open(path) as f:
      return int(f.read())
  except Exception:
    return 0


if __name__ == "__main__":
  last_off_ts = time.monotonic()
  backlight = None
  poller = select.poll()
  while True:
    try:
      if backlight is None:
        path = glob.glob("/sys/class/backlight/*")[0]
        # The backlight core notifies actual_brightness on every brightness
        # write, so a write above the cap is undone right away.
        actual = open(f"{path}/actual_brightness")
        poller.register(actual, select.POLLPRI | select.POLLERR)
        backlight = path

      # sample brightness and backlight power
      actual.seek(0)
      actual.read()
      bl_power = read(f"{backlight}/bl_power")
      brightness = read(f"{backlight}/brightness")
      if bl_power == BL_OFF or brightness == 0:
        last_off_ts = time.monotonic()

      # calculate new max
      uptime_hours = (time.monotonic() - last_off_ts) / (60*60)
      clipped_perc = MAX_PERCENT - (HOURLY_PERC_DECREASE*uptime_hours)
      clipped_perc = int(max(min(clipped_perc, MAX_PERCENT), MIN_PERCENT))

      # the kernel has no brightness cap, so lower the brightness directly
      max_brightness = read(f"{backlight}/max_brightness") * clipped_perc // 100
      if brightness > max_brightness:
        with open(f"{backlight}/brightness", 'w') as f:
          f.write(f"{max_brightness}\n")
    except Exception:
      time.sleep(5)
      continue

    poller.poll(5000)
