#!/usr/local/venv/bin/python
# run with openpilot stopped
import fcntl
import glob
import importlib
import importlib.metadata
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest

PARAMS = "/data/params/d"
APPS = ("/usr/comma/setup", "/usr/comma/reset", "/usr/comma/updater")

# signs of a crash, restart loop or broken filesystem
JOURNAL_ERRORS = ["segfault", "core dumped", "Traceback (most recent call last)", "Main process exited, code=",
                  "start request repeated too quickly", "Failed to start", "Out of memory", "Memory cgroup out of memory", "oom-kill",
                  "EXT4-fs error", "I/O error"]
# process names allowed to listen on anything but loopback
LISTENERS = {"sshd", "avahi-daemon"}
MAX_BOOT_TIME = 5  # seconds from kernel start to magic
DRM_IOCTL_WAIT_VBLANK = 0xC018643A
DRM_VBLANK_RELATIVE = 0x1
# without /data/pythonpath, like after a factory reset
NO_DATA_ENV = {k: v for k, v in os.environ.items() if k != "PYTHONPATH"}


def run(*cmd):
  return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()

def wait_for(f, timeout=10):
  end = time.monotonic() + timeout
  while time.monotonic() < end:
    if f():
      return True
    time.sleep(0.1)
  return f()

def is_active(unit):
  return run("systemctl", "is-active", unit) == "active"

def read(path):
  with open(path) as f:
    return f.read().strip("\0\n ")

def refresh_rate(n=60):
  """The panel's vblanks per second, whoever's drawing."""
  with open("/dev/dri/card0", "rb", buffering=0) as f:
    def vblank():
      # struct drm_wait_vblank, with the request {type, sequence, signal} replaced by {type, sequence, sec, usec}
      buf = bytearray(struct.pack("IIQ8x", DRM_VBLANK_RELATIVE, 1, 0))
      fcntl.ioctl(f, DRM_IOCTL_WAIT_VBLANK, buf)
      _, seq, sec, usec = struct.unpack("IIqq", buf)
      return seq, sec + usec / 1e6
    s0, t0 = vblank()
    for _ in range(n):
      s1, t1 = vblank()
  return (s1 - s0) / (t1 - t0)


class ParamToggle:
  """Flips a param and puts it, and whether its service runs, back as they were. Something else can run the service
  without the param, like the rack starting sshd for one boot, so restoring the param alone could stop it."""
  def __init__(self, name, watcher, service):
    self.path = os.path.join(PARAMS, name)
    self.watcher = watcher
    self.service = service

  def __enter__(self):
    # the rack masks the ssh watcher so it can always log in
    if run("systemctl", "is-enabled", self.watcher).startswith("masked"):
      raise unittest.SkipTest(f"{self.watcher} is masked")
    self.was_active = is_active(self.service)
    try:
      with open(self.path) as f:
        self.orig = f.read()
    except FileNotFoundError:
      self.orig = None
    return self

  def set(self, enabled, check):
    with open(self.path, "w") as f:
      f.write("1" if enabled else "0")
    # the watcher misses changes made while it's still running
    return wait_for(lambda: check() and run("systemctl", "is-active", self.watcher) == "inactive")

  def __exit__(self, *args):
    if self.orig is None:
      os.remove(self.path)
    else:
      with open(self.path, "w") as f:
        f.write(self.orig)
    time.sleep(0.5)
    wait_for(lambda: run("systemctl", "is-active", self.watcher) == "inactive")
    if is_active(self.service) != self.was_active:
      subprocess.run(["sudo", "systemctl", "start" if self.was_active else "stop", self.service], check=True)


class TestAgnos(unittest.TestCase):
  def test_no_failed_units(self):
    self.assertEqual(run("systemctl", "list-units", "--failed", "--plain", "--no-legend"), "")

  def test_system_running(self):
    self.assertEqual(run("systemctl", "is-system-running"), "running")

  def test_no_journal_errors(self):
    journal = run("journalctl", "-b", "--no-pager", "-o", "cat")
    for s in JOURNAL_ERRORS:
      self.assertNotIn(s, journal)

  def test_no_kernel_crashes(self):
    dmesg = run("sudo", "dmesg")
    for s in ("Internal error: Oops", "BUG:", "Kernel panic"):
      self.assertNotIn(s, dmesg)

  def test_boot_time(self):
    t = int(run("systemctl", "show", "-P", "ActiveEnterTimestampMonotonic", "magic.service")) / 1e6
    self.assertGreater(t, 0)
    self.assertLess(t, MAX_BOOT_TIME)

  def test_rootfs_readonly(self):
    self.assertTrue(os.statvfs("/").f_flag & os.ST_RDONLY)

  def test_open_ports(self):
    for line in run("sudo", "ss", "-tulpnH").splitlines():
      local = line.split()[4]
      if local.startswith(("127.", "[::1]")):
        continue
      # ss -l includes timesyncd's unconnected UDP client socket during NTP queries.
      if line.startswith("udp ") and '"systemd-timesyn"' in line:
        continue
      self.assertTrue(any(f'"{p}"' in line for p in LISTENERS), line)

  def test_no_unit_restarts(self):
    for unit in run("systemctl", "show", "-p", "Id,NRestarts", "*.service").split("\n\n"):
      self.assertIn("NRestarts=0", unit)

  def test_no_previous_panics(self):
    self.assertEqual([f for f in os.listdir("/sys/fs/pstore") if f.startswith("dmesg-")], [])

  def test_subsystems(self):
    for d in glob.glob("/sys/bus/msm_subsys/devices/*"):
      with open(f"{d}/name") as f:
        name = f.read().strip()
      with open(f"{d}/crash_count") as f:
        self.assertEqual(f.read().strip(), "0", name)
      if name in ("adsp", "cdsp", "modem"):
        with open(f"{d}/state") as f:
          self.assertEqual(f.read().strip(), "ONLINE", name)

  def test_boot_slot(self):
    with open("/proc/cmdline") as f:
      slot = f.read().split("androidboot.slot_suffix=")[1].split()[0]
    self.assertEqual(run("abctl", "--boot_slot"), slot)
    self.assertEqual(os.stat("/").st_dev, os.stat(f"/dev/disk/by-partlabel/system{slot}").st_rdev)

  def test_set_success_doesnt_write(self):
    def writes():
      os.sync()
      with open("/sys/block/sde/stat") as f:
        return int(f.read().split()[4])

    subprocess.run(["sudo", "abctl", "--set_success"], check=True)
    before = writes()
    subprocess.run(["sudo", "abctl", "--set_success"], check=True)
    self.assertEqual(writes(), before)

  def test_input_hotplug(self):
    # a fake input device that goes away with the process
    code = "import evdev, time; ui = evdev.UInput(name='test_agnos'); print(ui.device.path, flush=True); time.sleep(30)"
    p = subprocess.Popen(["sudo", sys.executable, "-c", code], stdout=subprocess.PIPE, text=True)
    try:
      node = p.stdout.readline().strip()
      self.assertTrue(node.startswith("/dev/input/event"), node)
      self.assertTrue(wait_for(lambda: os.access(node, os.R_OK | os.W_OK)))
    finally:
      p.terminate()
      p.wait()
      p.stdout.close()

  def test_magic_handoff(self):
    pid = run("systemctl", "show", "-P", "MainPID", "magic.service")
    for _ in range(5):
      with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(5)
        s.connect("/tmp/drmfd.sock")
        _, fds, _, _ = socket.recv_fds(s, 1, 1)
        self.assertEqual(len(fds), 1)
        os.close(fds[0])
    self.assertTrue(is_active("magic"))
    # the same magic, so it hasn't lost the screen calibration
    self.assertEqual(run("systemctl", "show", "-P", "MainPID", "magic.service"), pid)
    self.assertEqual(read("/sys/class/backlight/panel0-backlight/bl_power"), "0")
    self.assertGreater(int(read("/sys/class/backlight/panel0-backlight/brightness")), 0)
    self.assertAlmostEqual(refresh_rate(), 60, delta=1)

  def test_screen_calibration(self):
    journal = run("journalctl", "-b", "-u", "magic", "-o", "cat")
    if "mici" in read("/sys/firmware/devicetree/base/model"):
      self.assertTrue("Successfully setup screen calibration" in journal, "magic didn't set the gamma curves")
    else:
      self.assertTrue("Successfully setup color correction" in journal, "magic didn't set the color correction")

  def test_python_packages_import(self):
    mods = set()
    for d in importlib.metadata.distributions():
      for f in d.files or []:
        if len(f.parts) == 1 and (f.name.endswith(".py") or ".cpython-" in f.name):
          mods.add(f.name.split(".")[0])
        elif len(f.parts) == 2 and f.name == "__init__.py":
          mods.add(f.parts[0])

    # without /data/pythonpath, like after a factory reset
    path = sys.path[:]
    sys.path[:] = [p for p in sys.path if not p.startswith("/data")]
    try:
      for m in sorted(mods):
        if m.isidentifier() and not m.startswith("_"):
          with self.subTest(module=m):
            importlib.import_module(m)
    finally:
      sys.path[:] = path

  def test_standalone_apps_start(self):
    # Native apps cannot be imported through sys.path. Render two frames without
    # accessing DRM or waiting for a person, then let the normal render loop exit.
    env = NO_DATA_ENV | {"RAYLIB_BACKEND": "headless", "PROFILE_RENDER": "2", "PROFILE_STATS": "1"}
    for app in APPS:
      with self.subTest(app=app):
        p = subprocess.run([app, "/bin/false", "/nonexistent"], cwd="/", env=env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr + p.stdout)

  def test_ssh_toggle(self):
    keys = "/tmp/authorized_keys"
    with tempfile.TemporaryDirectory() as d, ParamToggle("SshEnabled", "ssh-param-watcher.service", "ssh") as p:
      key = os.path.join(d, "key")
      subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key], check=True)
      orig = os.path.join(d, "authorized_keys")
      if os.path.exists(keys):
        shutil.copy(keys, orig)
      subprocess.run(f"sudo tee -a {keys} < {key}.pub > /dev/null", shell=True, check=True)

      def can_ssh():
        return subprocess.run(["ssh", "-i", key, "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
                               "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=2", "comma@127.0.0.1", "true"],
                              capture_output=True).returncode == 0

      try:
        self.assertTrue(p.set(False, lambda: not can_ssh()))
        self.assertTrue(p.set(True, can_ssh))
      finally:
        if os.path.exists(orig):
          subprocess.run(["sudo", "cp", orig, keys], check=True)
        else:
          subprocess.run(["sudo", "rm", "-f", keys], check=True)

  def test_adb_toggle(self):
    # adbd only talks over USB, so check it's running with the USB gadget bound to the port.
    # disabling ADB unbinds the gadget, which drops USB networking until it's re-enabled
    ssh = os.environ.get("SSH_CONNECTION", "").split()
    if len(ssh) == 4 and f" {ssh[2]}/" in run("ip", "-o", "addr", "show", "usb0"):
      self.skipTest("this SSH session runs over USB")

    def gadget_bound():
      try:
        with open("/config/usb_gadget/g1/UDC") as f:
          return f.read().strip() != ""
      except FileNotFoundError:
        return False

    with ParamToggle("AdbEnabled", "adb-param-watcher.service", "adbd") as p:
      self.assertTrue(p.set(False, lambda: not is_active("adbd") and not gadget_bound()))
      self.assertTrue(p.set(True, lambda: is_active("adbd") and gadget_bound()))


if __name__ == "__main__":
  unittest.main()
