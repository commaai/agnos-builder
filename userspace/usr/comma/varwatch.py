#!/usr/bin/env python3
import os
import time

if __name__ == "__main__":
  # we are the last line of defense for /var/log filling up
  while True:
    usage = os.statvfs('/var/log')
    percent = (usage.f_blocks - usage.f_bavail) / usage.f_blocks * 100
    print(percent)
    if percent > 70:
      for fn in os.listdir('/var/log'):
        file_path = os.path.join('/var/log', fn)
        if os.path.isfile(file_path):
          with open(file_path, 'w'):
            pass
    time.sleep(1)
