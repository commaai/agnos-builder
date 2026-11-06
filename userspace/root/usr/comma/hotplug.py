#!/usr/bin/python3 -IS
# AGNOS doesn't run udev. The kernel creates device nodes as root:root 0600, this gives them their
# groups, modes and symlinks: first for what's already there, then as devices come and go.
# /dev/snd isn't here, sound_init.sh opens it up once the ADSP is ready for clients.
import collections
import fnmatch
import glob
import grp
import os
import re
import socket
import sys
import threading
import time

NETLINK_KOBJECT_UEVENT = 15
SO_RCVBUFFORCE = 33

# give up on a device after this long, and carry on with the rest
STUCK_TIMEOUT = 2

NODES = (
  ("adsprpc-smd", "gpu", 0o660),
  ("bus/usb/*/*", "root", 0o664),
  ("dri/*", "gpu", 0o660),
  ("fuse", "root", 0o666),
  ("gpiochip0", "gpio", 0o660),
  ("i2c-*", "gpio", 0o660),
  ("input/*", "input", 0o666),
  ("ion", "gpu", 0o660),
  ("kgsl-3d0", "gpu", 0o660),
  ("media*", "video", 0o660),
  ("net/tun", "root", 0o666),
  ("rtc0", "root", 0o600),
  ("sd*", "disk", 0o660),
  ("sg*", "disk", 0o660),
  ("spidev*", "root", 0o666),
  ("ttyHS0", "gpio", 0o660),
  ("ttyMSM*", "dialout", 0o660),
  ("ttyUSB*", "dialout", 0o660),
  ("v4l-subdev*", "video", 0o660),
  ("video*", "video", 0o660),
)
EG91_USB = ("2c7c", "6007")
MODEM_USB = (("2c7c", "0125"), EG91_USB)

# sysfs attributes the video group can write
VIDEO_ATTRS = {
  ("backlight", "panel0-backlight"): ("brightness", "bl_power"),
  ("leds", "led:torch_2"): ("brightness",),
  ("leds", "led:switch_2"): ("brightness",),
  ("platform", "soc:qcom,dsi-display@0"): ("max_brightness_percent",),
}

# links can outlive their device if it's removed while this isn't running
LINKS = (
  "/dev/modem_at*", "/dev/rtc", "/dev/disk/by-partlabel/*", "/dev/block/bootdevice/by-name/*", "/dev/input/by-path/*",
  "/dev/v4l/by-path/*",
)

# everything with a node is in /sys/dev
COLDPLUG = (
  "/sys/dev/char/*", "/sys/dev/block/*", "/sys/class/backlight/*", "/sys/class/firmware/*", "/sys/class/gpio/*",
  "/sys/class/leds/*", "/sys/class/net/*", "/sys/bus/platform/devices/soc:qcom,dsi-display@0",
)

GIDS = {name: grp.getgrnam(name).gr_gid for _, name, _ in NODES}
links = {}  # DEVNAME -> its symlinks
pending = collections.deque()  # coldplug work left to do, this goes before any new events
worker = None
busy_since = None  # when the worker started on its current job
notified = False


def own(path, group, mode):
  try:
    os.chown(path, 0, GIDS[group])
    os.chmod(path, mode)
  except OSError as e:
    print(f"{path}: {e}", file=sys.stderr)


def link(devname, path):
  os.makedirs(os.path.dirname(path), exist_ok=True)
  tmp = f"{path}.tmp"
  try:
    os.unlink(tmp)
  except FileNotFoundError:
    pass
  os.symlink(os.path.relpath(f"/dev/{devname}", os.path.dirname(path)), tmp)
  os.rename(tmp, path)
  links.setdefault(devname, set()).add(path)


def unlink(devname):
  for path in links.pop(devname, ()):
    try:
      os.unlink(path)
    except FileNotFoundError:
      pass


def read_attr(path):
  try:
    with open(path, errors="replace") as f:
      return f.read().strip()
  except OSError:
    return ""


def usb_id(usb_device):
  return read_attr(f"/sys/bus/usb/devices/{usb_device}/idVendor"), read_attr(f"/sys/bus/usb/devices/{usb_device}/idProduct")


def node_rule(devname):
  return next((rule for rule in NODES if fnmatch.fnmatchcase(devname, rule[0])), None)


def add(env):
  devname, devpath, subsystem = env.get("DEVNAME"), env["DEVPATH"], env["SUBSYSTEM"]
  name = os.path.basename(devpath)

  if subsystem == "firmware":
    # nothing in userspace provides firmware, don't leave the kernel waiting for it
    try:
      with open(f"/sys{devpath}/loading", "w") as f:
        f.write("-1")
    except OSError:
      pass
    return

  if subsystem == "gpio" and name.startswith("gpio") and not devname:
    own(f"/sys{devpath}", "gpio", 0o770)
    for attr in os.scandir(f"/sys{devpath}"):
      if not attr.is_symlink():
        own(attr.path, "gpio", 0o770)
    return

  for attr in VIDEO_ATTRS.get((subsystem, name), ()):
    path = f"/sys{devpath}/{attr}"
    if os.path.exists(path):
      own(path, "video", 0o664)

  if subsystem == "net":
    # the EG91's cdc_ether interface isn't used, it'd only take the usb0 name
    m = re.search(r"/((\d+-[\d.]+):1\.4)/net/", devpath)
    if m and usb_id(m[2]) == EG91_USB:
      try:
        with open("/sys/bus/usb/drivers/cdc_ether/unbind", "w") as f:
          f.write(m[1])
      except OSError as e:
        print(f"cdc_ether unbind {m[1]}: {e}", file=sys.stderr)
    return

  if not devname:
    return

  rule = node_rule(devname)
  if rule:
    own(f"/dev/{devname}", rule[1], rule[2])

  if subsystem == "block" and "/" not in env.get("PARTNAME", "/"):
    link(devname, f"/dev/disk/by-partlabel/{env['PARTNAME']}")
    link(devname, f"/dev/block/bootdevice/by-name/{env['PARTNAME']}")
  elif subsystem == "input" and name.startswith("event") and "/894000.i2c/" in devpath:
    link(devname, "/dev/input/by-path/platform-894000.i2c-event")
  elif subsystem == "video4linux" and name.startswith("video"):
    parent = devpath.split("/")[-3].replace(",", "_")
    link(devname, f"/dev/v4l/by-path/platform-{parent}-video-index{read_attr(f'/sys{devpath}/index')}")
  elif subsystem == "rtc" and name == "rtc0":
    link(devname, "/dev/rtc")
  elif subsystem == "tty" and (m := re.search(r"/(\d+-[\d.]+):1\.([23])/", devpath)) and usb_id(m[1]) in MODEM_USB:
    link(devname, f"/dev/modem_at{int(m[2]) - 2}")


def uevent(action, env):
  try:
    if action == "add":
      add(env)
    elif action == "remove" and "DEVNAME" in env:
      unlink(env["DEVNAME"])
  except Exception as e:
    print(f"{action} {env}: {e}", file=sys.stderr)


def coldplug_device(path):
  if not os.path.exists(f"{path}/uevent"):
    return
  lines = read_attr(f"{path}/uevent").splitlines()
  env = dict(line.split("=", 1) for line in lines if "=" in line)
  # most nodes don't need anything
  if "DEVNAME" in env and not node_rule(env["DEVNAME"]):
    return
  real = os.path.realpath(path)
  env.update(DEVPATH=real[len("/sys"):], SUBSYSTEM=os.path.basename(os.path.realpath(f"{real}/subsystem")))
  uevent("add", env)


def remove_dangling_links():
  for pattern in LINKS:
    for path in glob.iglob(pattern):
      if not os.path.exists(path):
        os.unlink(path)


def coldplug():
  pending.append((remove_dangling_links, ()))
  for path in ("/sys/class/gpio", "/sys/class/gpio/export", "/sys/class/gpio/unexport"):
    pending.append((own, (path, "gpio", 0o770)))
  for pattern in COLDPLUG:
    pending.extend((coldplug_device, (path,)) for path in glob.iglob(pattern))


def sd_notify_ready():
  global notified
  notify = os.environ.get("NOTIFY_SOCKET")
  if notify and not notified:
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as s:
      s.sendto(b"READY=1", notify)
  notified = True


def next_job(sock):
  if pending:
    return pending.popleft()
  sd_notify_ready()

  try:
    msg, sender = sock.recvfrom(16384)
  except OSError:  # ENOBUFS, events were dropped
    coldplug()
    return None
  # only the kernel. each service's memcg slabs send hundreds of these
  if sender[0] != 0 or msg.startswith((b"add@/kernel/slab", b"remove@/kernel/slab")):
    return None
  fields = msg.decode(errors="replace").split("\0")
  env = dict(f.split("=", 1) for f in fields[1:] if "=" in f)
  if "DEVPATH" in env and "SUBSYSTEM" in env:
    return uevent, (fields[0].split("@")[0], env)
  return None


def work(sock):
  global busy_since
  me = threading.current_thread()
  while me is worker:
    job = next_job(sock)
    if job:
      busy_since = time.monotonic()
      job[0](*job[1])
      if me is worker:
        busy_since = None


def start_worker(sock):
  global worker, busy_since
  busy_since = None
  worker = threading.Thread(target=work, args=(sock,), daemon=True)
  worker.start()


def main():
  # listen first so nothing is missed between the coldplug and the first recv
  sock = socket.socket(socket.AF_NETLINK, socket.SOCK_DGRAM, NETLINK_KOBJECT_UEVENT)
  sock.setsockopt(socket.SOL_SOCKET, SO_RCVBUFFORCE, 4 * 1024 * 1024)
  sock.bind((0, 1))
  coldplug()
  start_worker(sock)

  # a stuck sysfs access only loses that device. the stuck thread exits if it ever comes back
  while True:
    time.sleep(1)
    since = busy_since
    if not worker.is_alive() or (since is not None and time.monotonic() - since > STUCK_TIMEOUT):
      print("worker stuck or died, starting another", file=sys.stderr)
      start_worker(sock)


if __name__ == "__main__":
  main()
