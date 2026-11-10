import os
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SETUP = '''import os
import signal
import sys
import time
from pathlib import Path

root = Path(os.environ["TEST_ROOT"])
mode = os.environ["TEST_MODE"]

def log(event):
  with (root / "events").open("a") as f:
    f.write(event + "\\n")

def stop(*args):
  log("stop " + str(os.getpid()))
  sys.exit(0)

signal.signal(signal.SIGTERM, signal.SIG_IGN if mode == "stubborn" else stop)
starts = sum(line.startswith("start ") for line in (root / "events").read_text().splitlines()) + 1
log("start " + str(os.getpid()))
if mode == "fail_once" and starts == 1:
  sys.exit(1)
if mode == "installer_retry" and starts == 1:
  installer = root / "installer"
  installer.write_text("#!/bin/sh\\necho installer >> \\\"$TEST_ROOT/events\\\"\\nexit 1\\n")
if mode == "installer_handoff":
  installer = root / "installer"
  installer.write_text("#!/bin/sh\\necho installer >> \\\"$TEST_ROOT/events\\\"\\ncp \\\"$TEST_ROOT/continue-template\\\" \\\"$TEST_ROOT/continue.sh\\\"\\n")
if mode == "installer_retry" and starts == 2:
  (root / "continue.sh").write_text((root / "continue-template").read_text())
  (root / "continue.sh").chmod(0o755)
while True:
  time.sleep(.05)
'''


class SetupLoop:
  def __init__(self, mode):
    self.directory = tempfile.TemporaryDirectory(prefix="setup-restart-test-")
    self.root = Path(self.directory.name)
    (self.root / "events").touch()
    (self.root / "setup.py").write_text(SETUP)
    template = self.root / "continue-template"
    template.write_text('#!/bin/sh\necho continue >> "$TEST_ROOT/events"\ntouch "$TEST_ROOT/completed"\n')
    template.chmod(0o755)
    source = (ROOT / "userspace/root/usr/comma/comma.sh").read_text()
    loop = source[source.index('setup_pid=""\n'):]
    header = '''SETUP="$TEST_ROOT/setup.py"
CONTINUE="$TEST_ROOT/continue.sh"
INSTALLER="$TEST_ROOT/installer"
handle_setup_keys () { :; }
pkill () { :; }
sudo () { :; }
'''
    self.script = self.root / "loop.sh"
    self.script.write_text(header + loop)
    self.log = (self.root / "shell.log").open("w")
    self.process = subprocess.Popen(["bash", str(self.script)], start_new_session=True,
                                    env=os.environ | {"TEST_ROOT": str(self.root), "TEST_MODE": mode},
                                    stdout=self.log, stderr=subprocess.STDOUT)

  def events(self):
    return (self.root / "events").read_text().splitlines()

  def wait_for(self, condition, timeout=8):
    deadline = time.monotonic() + timeout
    while not condition():
      if time.monotonic() >= deadline:
        raise AssertionError((self.root / "shell.log").read_text() + repr(self.events()))
      time.sleep(.01)

  def continue_now(self):
    target = self.root / "continue.sh"
    target.write_text((self.root / "continue-template").read_text())
    target.chmod(0o755)

  def close(self):
    try:
      os.killpg(self.process.pid, signal.SIGTERM)
    except ProcessLookupError:
      pass
    try:
      self.process.wait(timeout=2)
    except subprocess.TimeoutExpired:
      os.killpg(self.process.pid, signal.SIGKILL)
      self.process.wait(timeout=2)
    self.log.close()
    self.directory.cleanup()


class TestSetupRestart(unittest.TestCase):
  def fixture(self, mode):
    loop = SetupLoop(mode)
    self.addCleanup(loop.close)
    return loop

  def test_failed_setup_restarts_then_hands_off(self):
    loop = self.fixture("fail_once")
    start = time.monotonic()
    loop.wait_for(lambda: sum(event.startswith("start ") for event in loop.events()) == 2)
    self.assertGreaterEqual(time.monotonic() - start, 1)
    loop.continue_now()
    loop.process.wait(timeout=3)
    self.assertEqual(loop.process.returncode, 0)
    self.assertEqual(sum(event.startswith("start ") for event in loop.events()), 2)
    self.assertTrue(loop.events()[-2].startswith("stop "))
    self.assertEqual(loop.events()[-1], "continue")

  def test_continue_during_retry_delay_does_not_start_setup_again(self):
    loop = self.fixture("fail_once")
    loop.wait_for(lambda: "retrying" in (loop.root / "shell.log").read_text())
    loop.continue_now()
    loop.process.wait(timeout=3)
    self.assertEqual(sum(event.startswith("start ") for event in loop.events()), 1)
    self.assertEqual(loop.events()[-1], "continue")

  def test_healthy_setup_is_not_duplicated(self):
    loop = self.fixture("healthy")
    loop.wait_for(lambda: len(loop.events()) == 1)
    time.sleep(.4)
    self.assertEqual(sum(event.startswith("start ") for event in loop.events()), 1)
    loop.continue_now()
    loop.process.wait(timeout=3)
    self.assertEqual(loop.events()[-1], "continue")
    self.assertTrue((loop.root / "completed").exists())

  def test_failed_installer_reaps_setup_before_retry(self):
    loop = self.fixture("installer_retry")
    loop.process.wait(timeout=5)
    events = loop.events()
    self.assertEqual(loop.process.returncode, 0)
    self.assertEqual(sum(event.startswith("start ") for event in events), 2)
    self.assertEqual(events.count("installer"), 1)
    starts = [index for index, event in enumerate(events) if event.startswith("start ")]
    self.assertTrue(events[starts[1] - 1].startswith("stop "))
    self.assertEqual(events[-1], "continue")

  def test_stubborn_setup_cannot_block_handoff(self):
    loop = self.fixture("stubborn")
    loop.wait_for(lambda: len(loop.events()) == 1)
    start = time.monotonic()
    loop.continue_now()
    loop.process.wait(timeout=5)
    self.assertLess(time.monotonic() - start, 4)
    self.assertEqual(loop.process.returncode, 0)
    self.assertEqual(loop.events()[-1], "continue")
    self.assertTrue((loop.root / "completed").exists())

  def test_installer_handoff_stops_setup(self):
    loop = self.fixture("installer_handoff")
    loop.process.wait(timeout=5)
    self.assertEqual(loop.process.returncode, 0)
    self.assertEqual(loop.events().count("installer"), 1)
    self.assertTrue(loop.events()[-2].startswith("stop "))
    self.assertEqual(loop.events()[-1], "continue")

  def test_tmux_start_and_stop_use_dedicated_socket(self):
    unit = (ROOT / "userspace/root/usr/lib/systemd/system/comma.service").read_text()
    self.assertIn("/usr/bin/tmux -L comma new-session", unit)
    self.assertIn("/usr/bin/tmux -L comma kill-session", unit)


if __name__ == "__main__":
  unittest.main()
