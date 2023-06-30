#!/usr/bin/env python3
import sys
from collections import deque
from evdev import InputDevice, ecodes

def log(msg):
  # TODO: keep buffer of touch events + coords and dump after log
  print(msg, file=sys.stderr)

if __name__ == "__main__":
  touch_starts = deque([0.]*20, maxlen=20)

  dev = InputDevice('/dev/input/by-path/platform-894000.i2c-event')
  for event in dev.read_loop():
    #print(event.type, event.code, event.value)

    # TODO: consider multitouch events
    if event.type == ecodes.EV_KEY and event.code == ecodes.BTN_TOUCH:
      if event.value == 1:
        touch_starts.append(event.timestamp())

        avg_touch_dt = (max(touch_starts) - min(touch_starts)) / len(touch_starts)
        avg_touch_freq = 1 / (avg_touch_dt + 0.0001)
        if avg_touch_freq > 15:
          log(f"Quick touch frequency {avg_touch_freq:.2f}s / {event}")

        if len(touch_starts) > 2:
          dt = (touch_starts[-1] - touch_starts[-2])
          if dt < 0.02:
            log(f"Quick consecutive touches {dt:.2f}s / {event}")
      elif event.value == 0:
        if len(touch_starts):
          dt = event.timestamp() - touch_starts[-1]
          if dt > 10.:
            log(f"Touch point persisted for {dt:.2f}s / {event}")
