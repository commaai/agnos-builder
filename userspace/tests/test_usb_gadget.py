#!/usr/bin/env python3

from __future__ import annotations

import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest  # noqa: TID251 - these tests intentionally use only the standard library


USERSPACE = Path(__file__).parents[1]
COMMA_DIR = USERSPACE / "root" / "usr" / "comma"
GADGET_HELPER = COMMA_DIR / "usb_gadget.sh"
SET_ADB = COMMA_DIR / "set_adb.sh"
STOP_STORAGE = COMMA_DIR / "stop_usb_storage.sh"


class UsbGadgetTest(unittest.TestCase):
  def setUp(self) -> None:
    self.temporary_directory = tempfile.TemporaryDirectory()
    self.root = Path(self.temporary_directory.name)
    self.configfs = self.root / "config"
    self.gadget = self.configfs / "usb_gadget" / "g1"
    self.config = self.gadget / "configs" / "c.1"
    self.mass_storage = self.gadget / "functions" / "mass_storage.0"
    self.lun = self.mass_storage / "lun.0"
    self.link_log = self.root / "link-order.log"
    self.link_wrapper = self.root / "logged-ln"
    self.link_wrapper.write_text(
      "#!/bin/sh\n"
      "printf '%s\\n' \"${3##*/}\" >> \"$USB_GADGET_LINK_LOG\"\n"
      "exec /bin/ln \"$@\"\n",
    )
    self.link_wrapper.chmod(0o755)

    self.environment = os.environ.copy()
    self.environment.update({
      "USB_GADGET_CONFIGFS_ROOT": str(self.configfs),
      "USB_GADGET_FFS_ADB_ROOT": str(self.root / "ffs-adb"),
      "USB_GADGET_LOCK_FILE": str(self.root / "gadget.lock"),
      "USB_GADGET_SERIAL": "test-serial",
      "USB_GADGET_SKIP_MOUNTS": "1",
      # macOS has no flock, while AGNOS gets it from util-linux. The real lock
      # path is exercised by the Python manager tests; this tree is per-test.
      "USB_GADGET_FLOCK_BIN": "/usr/bin/true",
      "USB_GADGET_SYSTEMCTL_BIN": "/usr/bin/true",
      "USB_GADGET_SETPROP_BIN": "/usr/bin/true",
      "USB_GADGET_SLEEP_BIN": "/usr/bin/true",
      "USB_GADGET_LN_BIN": str(self.link_wrapper),
      "USB_GADGET_LINK_LOG": str(self.link_log),
    })

  def tearDown(self) -> None:
    self.temporary_directory.cleanup()

  def run_helper(self, *arguments: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
      [str(GADGET_HELPER), *arguments],
      env=self.environment,
      check=check,
      capture_output=True,
      text=True,
    )

  @staticmethod
  def read(path: Path) -> str:
    return path.read_text().strip()

  def assert_non_adb_links(self) -> None:
    self.assertTrue((self.config / "mass_storage.0").is_symlink())
    self.assertTrue((self.config / "ncm.0").is_symlink())
    self.assertFalse((self.config / "ffs.adb").is_symlink())

  def assert_debug_links(self) -> None:
    self.assertTrue((self.config / "mass_storage.0").is_symlink())
    self.assertTrue((self.config / "ncm.0").is_symlink())
    self.assertTrue((self.config / "ffs.adb").is_symlink())

  def test_disabled_adb_exposes_network_and_empty_read_only_storage(self) -> None:
    self.run_helper("configure", "0")

    self.assertEqual(self.read(self.gadget / "UDC"), "a600000.dwc3")
    self.assertEqual(self.read(self.gadget / "idVendor"), "0x04D8")
    self.assertEqual(self.read(self.gadget / "idProduct"), "0x1234")
    self.assertEqual(self.read(self.gadget / "strings" / "0x409" / "serialnumber"), "test-serial")
    self.assertEqual(self.read(self.mass_storage / "stall"), "1")
    self.assertEqual(self.read(self.lun / "ro"), "1")
    self.assertEqual(self.read(self.lun / "removable"), "1")
    self.assertEqual(self.read(self.lun / "file"), "")
    self.assertEqual(self.read(self.config / "strings" / "0x409" / "configuration"), "NCM+Storage")
    self.assert_non_adb_links()

  def test_enabled_adb_adds_network_and_functionfs(self) -> None:
    self.run_helper("configure", "1")

    self.assertEqual(self.read(self.config / "strings" / "0x409" / "configuration"), "NCM+ADB+Storage")
    self.assert_debug_links()

  def test_function_order_preserves_existing_host_interface_numbers(self) -> None:
    self.run_helper("configure", "0")
    self.assertEqual(self.link_log.read_text().splitlines(), ["ncm.0", "mass_storage.0"])

    self.link_log.write_text("")
    self.run_helper("configure", "1")
    self.assertEqual(self.link_log.read_text().splitlines(), ["ncm.0", "ffs.adb", "mass_storage.0"])

  def test_reconfigure_ejects_populated_safe_lun(self) -> None:
    self.run_helper("configure", "0")
    (self.lun / "file").write_text("/run/usb-storage/footage.img\n")

    self.run_helper("configure", "1")

    self.assertEqual(self.read(self.lun / "file"), "")
    self.assertEqual(self.read(self.lun / "ro"), "1")
    self.assertEqual(self.read(self.lun / "removable"), "1")
    self.assert_debug_links()

  def test_unsafe_populated_lun_fails_unbound_and_unlinked(self) -> None:
    self.run_helper("configure", "1")
    (self.lun / "file").write_text("/run/usb-storage/footage.img\n")
    (self.lun / "ro").write_text("0\n")

    result = self.run_helper("configure", "0", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("refusing to reconfigure", result.stderr)
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertEqual(self.read(self.lun / "file"), "/run/usb-storage/footage.img")
    self.assertFalse((self.config / "mass_storage.0").is_symlink())
    self.assertFalse((self.config / "ncm.0").is_symlink())
    self.assertFalse((self.config / "ffs.adb").is_symlink())

  def test_foreign_read_only_lun_is_preserved_and_fails_unbound(self) -> None:
    self.run_helper("configure", "0")
    (self.lun / "file").write_text("/some/other/backing.img\n")

    result = self.run_helper("configure", "1", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("foreign", result.stderr)
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertEqual(self.read(self.lun / "file"), "/some/other/backing.img")
    self.assertFalse((self.config / "mass_storage.0").is_symlink())
    self.assertFalse((self.config / "ncm.0").is_symlink())
    self.assertFalse((self.config / "ffs.adb").is_symlink())

  def test_repeated_configure_is_idempotent(self) -> None:
    self.run_helper("configure", "0")
    self.run_helper("configure", "0")
    self.assert_non_adb_links()

    self.run_helper("configure", "1")
    self.run_helper("configure", "1")
    self.assert_debug_links()
    self.assertEqual(self.read(self.lun / "file"), "")

  def test_bind_and_unbind_are_idempotent(self) -> None:
    self.run_helper("configure", "0")

    self.run_helper("unbind")
    self.run_helper("unbind")
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assert_non_adb_links()

    self.run_helper("bind")
    self.run_helper("bind")
    self.assertEqual(self.read(self.gadget / "UDC"), "a600000.dwc3")
    self.assert_non_adb_links()

  def test_symbolic_link_lock_is_rejected_without_touching_target(self) -> None:
    lock = Path(self.environment["USB_GADGET_LOCK_FILE"])
    victim = self.root / "victim"
    victim.write_text("do not truncate")
    lock.symlink_to(victim)

    result = self.run_helper("configure", "0", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("symbolic-link", result.stderr)
    self.assertEqual(victim.read_text(), "do not truncate")
    self.assertFalse(self.gadget.exists())

  def test_set_adb_delegates_param_state(self) -> None:
    adb_param = self.root / "AdbEnabled"
    self.environment.update({
      "USB_GADGET_ADB_PARAM": str(adb_param),
      "USB_GADGET_HELPER": str(GADGET_HELPER),
    })

    adb_param.write_text("1")
    subprocess.run([str(SET_ADB)], env=self.environment, check=True, capture_output=True, text=True)
    self.assert_debug_links()

    adb_param.write_text("0")
    subprocess.run([str(SET_ADB)], env=self.environment, check=True, capture_output=True, text=True)
    self.assert_non_adb_links()

  def test_stop_wrapper_signals_manager_before_final_unbind(self) -> None:
    event_log = self.root / "stop-order.log"
    manager_script = self.root / "fake-manager.py"
    manager_script.write_text(
      "import os\n"
      "from pathlib import Path\n"
      "import signal\n"
      "import time\n"
      "log = Path(os.environ['USB_STORAGE_STOP_TEST_LOG'])\n"
      "def stop(_signal, _frame):\n"
      "  with log.open('a') as stream: stream.write('manager-exit\\n')\n"
      "  raise SystemExit(0)\n"
      "signal.signal(signal.SIGTERM, stop)\n"
      "with log.open('a') as stream: stream.write('manager-ready\\n')\n"
      "while True: time.sleep(1)\n",
    )
    helper = self.root / "fake-unbind"
    helper.write_text(
      "#!/bin/sh\n"
      "printf 'unbind\\n' >> \"$USB_STORAGE_STOP_TEST_LOG\"\n",
    )
    helper.chmod(0o755)
    environment = os.environ.copy()
    environment.update({
      "USB_GADGET_HELPER": str(helper),
      "USB_STORAGE_STOP_TEST_LOG": str(event_log),
      "USB_STORAGE_STOP_ATTEMPTS": "100",
      "USB_STORAGE_KILL_ATTEMPTS": "5",
      "USB_STORAGE_STOP_INTERVAL": "0.01",
    })
    process = subprocess.Popen(["python3", str(manager_script)], env=environment)
    try:
      deadline = time.monotonic() + 5
      while (not event_log.exists() or "manager-ready" not in event_log.read_text()) and time.monotonic() < deadline:
        time.sleep(0.01)
      self.assertIsNone(process.poll())

      subprocess.run(
        [str(STOP_STORAGE), str(process.pid)],
        env=environment,
        check=True,
        capture_output=True,
        text=True,
      )

      self.assertEqual(process.wait(timeout=2), 0)
      self.assertEqual(event_log.read_text().splitlines(), ["manager-ready", "manager-exit", "unbind"])
    finally:
      if process.poll() is None:
        process.send_signal(signal.SIGKILL)
        process.wait(timeout=2)

  def test_stop_wrapper_forces_manager_exit_before_final_unbind(self) -> None:
    event_log = self.root / "forced-stop-order.log"
    manager_script = self.root / "term-ignoring-manager.py"
    manager_script.write_text(
      "import os\n"
      "from pathlib import Path\n"
      "import signal\n"
      "import time\n"
      "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
      "Path(os.environ['USB_STORAGE_STOP_TEST_LOG']).write_text('manager-ready\\n')\n"
      "while True: time.sleep(1)\n",
    )
    helper = self.root / "fake-forced-unbind"
    helper.write_text(
      "#!/bin/sh\n"
      "printf 'unbind\\n' >> \"$USB_STORAGE_STOP_TEST_LOG\"\n",
    )
    helper.chmod(0o755)
    environment = os.environ.copy()
    environment.update({
      "USB_GADGET_HELPER": str(helper),
      "USB_STORAGE_STOP_TEST_LOG": str(event_log),
      "USB_STORAGE_STOP_ATTEMPTS": "2",
      "USB_STORAGE_KILL_ATTEMPTS": "2",
      "USB_STORAGE_STOP_INTERVAL": "0.01",
    })
    process = subprocess.Popen(["python3", str(manager_script)], env=environment)
    try:
      deadline = time.monotonic() + 5
      while (not event_log.exists() or "manager-ready" not in event_log.read_text()) and time.monotonic() < deadline:
        time.sleep(0.01)
      self.assertIsNone(process.poll())

      result = subprocess.run(
        [str(STOP_STORAGE), str(process.pid)],
        env=environment,
        check=True,
        capture_output=True,
        text=True,
      )

      self.assertEqual(process.wait(timeout=2), -signal.SIGKILL)
      self.assertIn("forcing main-process exit", result.stderr)
      self.assertEqual(event_log.read_text().splitlines(), ["manager-ready", "unbind"])
    finally:
      if process.poll() is None:
        process.send_signal(signal.SIGKILL)
        process.wait(timeout=2)


if __name__ == "__main__":
  unittest.main()
