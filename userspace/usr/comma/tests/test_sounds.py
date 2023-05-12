#!/usr/bin/env python3
import os
import time
import subprocess

good = """
Starting Sound...
[INFO] Bringing adsp out of reset
subsys4
waiting for sound card to come online
sound card online
sound.service: Succeeded.
Finished Sound.
""".strip()

if __name__ == "__main__":
  time.sleep(3)
  log = subprocess.check_output("journalctl -o cat -u sound", shell=True, encoding='utf8').strip()
  passed = log == good
  with open('/data/tmp/sound_log', 'a') as f:
    f.write(f"{passed}\n")

  os.system("journalctl -u sound.service -o short-monotonic >> /data/tmp/sound_service_log")
  os.system("sudo su -c 'tail /data/tmp/sound_log > /dev/console'")
  os.system("sudo su -c 'wc -l /data/tmp/sound_log > /dev/console'")
  os.sync()

  if passed:
    time.sleep(2)
    os.system("sudo reboot")
