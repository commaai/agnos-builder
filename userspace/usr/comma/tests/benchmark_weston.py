#!/usr/bin/env python3
import os
import time
import subprocess

def run(cmd):
  subprocess.check_call(cmd, shell=True)

def timestamp_cmd(cmd):
  cnt = 0
  while True:
    cnt += 1
    print("try ", cnt)
    run("sudo chmod -R 700 /var/tmp/weston/")
    proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    t = time.monotonic()
    time.sleep(0.5)
    r = proc.poll()
    if r is not None:
      continue
    break
    print("r", r)
  return t

if __name__ == "__main__":

  run("sudo systemctl stop weston")
  run("sudo rm -rf /var/tmp/weston/wayland-0")
  time.sleep(0.5)
  #run("sudo systemctl restart weston-ready")

  run("sudo systemctl restart weston --no-block")
  st = time.monotonic()
  #ts = defaultdict()

  cnt = 0
  while not os.path.exists("/var/tmp/weston/wayland-0"):
    time.sleep(0.1)
    cnt += 1
  t = time.monotonic()
  print(f"- socket at {t - st:.2f}s")

  t = timestamp_cmd('/usr/comma/setup')
  print(f"- setup works {t - st:.2f}s")

  t = timestamp_cmd('cd /data/openpilot/selfdrive/ui/ && ./spinner')
  print(f"- spinner works {t - st:.2f}s")
