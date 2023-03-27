#!/usr/bin/env python3
import os
import time
import hashlib
import subprocess

if __name__ == "__main__":
  socket_exists = os.path.exists("/var/tmp/weston/wayland-0")
  is_active = subprocess.check_output("systemctl is-active weston", shell=True, encoding='utf8').strip()

  d = b""
  for fn in ('/lib/systemd/system/weston.service', '/lib/systemd/system/weston-ready.service'):
    with open(fn, 'rb') as f:
      d += f.read()
  h = hashlib.sha1(d).hexdigest()

  # weston should be ready to go at this point
  proc = subprocess.Popen('/usr/comma/setup', shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
  for i in range(10):
    r = proc.poll()
    if r is not None:
      break
    time.sleep(1)

  rc = proc.returncode
  proc.kill()
  out, err = proc.stdout.read(), proc.stderr.read()

  with open('/data/weston_log', 'a') as f:
    f.write(f"{is_active=}, {socket_exists=}, app={rc} / {h}\n")
    if rc is not None:
      f.write(f"  stdout: {out}\n")
      f.write(f"  stderr: {err}\n")
  os.sync()

  os.system("sudo su -c 'tail /data/weston_log > /dev/console'")
  os.system("sudo su -c 'wc -l /data/weston_log > /dev/console'")

  time.sleep(2)
  os.system("sudo reboot")
