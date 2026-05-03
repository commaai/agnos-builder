#!/usr/bin/env python3
import os
import time
import subprocess

required = [
  "[INFO] Bringing adsp out of reset",
  "waiting for sound card to come online",
  "sound card online",
]

if __name__ == "__main__":
  time.sleep(3)
  log = subprocess.check_output("cat /tmp/sound.log 2>/dev/null || true", shell=True, encoding='utf8').strip()
  passed = all(line in log for line in required)
  with open('/data/tmp/sound_log', 'a') as f:
    f.write(f"{passed}\n")

  os.system("cat /tmp/sound.log >> /data/tmp/sound_service_log")
  os.system("sudo su -c 'tail /data/tmp/sound_log > /dev/console'")
  os.system("sudo su -c 'wc -l /data/tmp/sound_log > /dev/console'")
  os.sync()

  if passed:
    time.sleep(2)
    os.system("sudo reboot")
