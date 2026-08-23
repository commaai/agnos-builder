#!/usr/bin/env python3
# ruff: noqa: ISC002 - adjacent literals keep embedded shell/Python fixtures readable

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
STORAGE_SERVICE = USERSPACE / "root" / "usr" / "lib" / "systemd" / "system" / "usb-storage.service"


class UsbGadgetTest(unittest.TestCase):
  def setUp(self) -> None:
    self.temporary_directory = tempfile.TemporaryDirectory()
    self.root = Path(self.temporary_directory.name)
    self.configfs = self.root / "config"
    self.gadget = self.configfs / "usb_gadget" / "g1"
    self.config = self.gadget / "configs" / "c.1"
    self.mass_storage = self.gadget / "functions" / "mass_storage.0"
    self.lun = self.mass_storage / "lun.0"
    self.adb_param = self.root / "AdbEnabled"
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
      "USB_GADGET_STORAGE_ONLY_VID": "0xCAFE",
      "USB_GADGET_STORAGE_ONLY_PID": "0xBEEF",
      "USB_GADGET_ADB_PARAM": str(self.adb_param),
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

  def assert_storage_only_links(self) -> None:
    self.assertTrue((self.config / "mass_storage.0").is_symlink())
    self.assertFalse((self.config / "ncm.0").is_symlink())
    self.assertFalse((self.config / "ffs.adb").is_symlink())

  def assert_debug_links(self) -> None:
    self.assertTrue((self.config / "mass_storage.0").is_symlink())
    self.assertTrue((self.config / "ncm.0").is_symlink())
    self.assertTrue((self.config / "ffs.adb").is_symlink())

  def test_disabled_adb_exposes_only_empty_read_only_storage(self) -> None:
    self.run_helper("configure", "0")

    self.assertEqual(self.read(self.gadget / "UDC"), "a600000.dwc3")
    self.assertEqual(self.read(self.gadget / "idVendor"), "0xCAFE")
    self.assertEqual(self.read(self.gadget / "idProduct"), "0xBEEF")
    self.assertEqual(self.read(self.gadget / "strings" / "0x409" / "serialnumber"), "test-serial")
    self.assertEqual(self.read(self.mass_storage / "stall"), "1")
    self.assertEqual(self.read(self.lun / "ro"), "1")
    self.assertEqual(self.read(self.lun / "removable"), "1")
    self.assertEqual(self.read(self.lun / "file"), "")
    self.assertEqual(self.read(self.config / "strings" / "0x409" / "configuration"), "Storage")
    self.assert_storage_only_links()

  def test_enabled_adb_adds_network_and_functionfs(self) -> None:
    self.run_helper("configure", "1")

    self.assertEqual(self.read(self.gadget / "idVendor"), "0x04D8")
    self.assertEqual(self.read(self.gadget / "idProduct"), "0x1234")
    self.assertEqual(self.read(self.config / "strings" / "0x409" / "configuration"), "NCM+ADB+Storage")
    self.assert_debug_links()

  def test_function_order_preserves_existing_host_interface_numbers(self) -> None:
    self.run_helper("configure", "0")
    self.assertEqual(self.link_log.read_text().splitlines(), ["mass_storage.0"])

    self.link_log.write_text("")
    self.run_helper("configure", "1")
    self.assertEqual(self.link_log.read_text().splitlines(), ["ncm.0", "ffs.adb", "mass_storage.0"])

  def test_storage_only_mode_requires_a_distinct_owner_approved_identity(self) -> None:
    del self.environment["USB_GADGET_STORAGE_ONLY_VID"]
    del self.environment["USB_GADGET_STORAGE_ONLY_PID"]
    result = self.run_helper("configure", "0", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("owner-approved", result.stderr)
    self.assertFalse(self.gadget.exists())

    self.environment["USB_GADGET_STORAGE_ONLY_VID"] = "0x04D8"
    self.environment["USB_GADGET_STORAGE_ONLY_PID"] = "0x1234"
    result = self.run_helper("configure", "0", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("distinct", result.stderr)
    self.assertFalse(self.gadget.exists())

  def test_disabling_adb_without_approved_storage_identity_fails_unbound(self) -> None:
    self.run_helper("configure", "1")
    self.assertEqual(self.read(self.gadget / "UDC"), "a600000.dwc3")
    del self.environment["USB_GADGET_STORAGE_ONLY_VID"]
    del self.environment["USB_GADGET_STORAGE_ONLY_PID"]

    result = self.run_helper("configure", "0", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("owner-approved", result.stderr)
    self.assertEqual(self.read(self.gadget / "UDC"), "")

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
    self.assert_storage_only_links()

    self.run_helper("configure", "1")
    self.run_helper("configure", "1")
    self.assert_debug_links()
    self.assertEqual(self.read(self.lun / "file"), "")

  def test_bind_and_unbind_are_idempotent(self) -> None:
    self.run_helper("configure", "0")

    self.run_helper("unbind")
    self.run_helper("unbind")
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assert_storage_only_links()

    self.run_helper("bind")
    self.run_helper("bind")
    self.assertEqual(self.read(self.gadget / "UDC"), "a600000.dwc3")
    self.assert_storage_only_links()

  def test_managed_storage_reenumeration_preserves_complete_debug_personality(self) -> None:
    self.adb_param.write_text("1\n")
    self.run_helper("configure", "1")
    # Real configfs normalizes hexadecimal USB IDs to lowercase on readback.
    (self.gadget / "idVendor").write_text("0x04d8\n")
    (self.lun / "file").write_text("/run/usb-storage/footage.img\n")
    sleep_log = self.root / "reenumerate-sleep.log"
    sleep_wrapper = self.root / "logged-sleep"
    sleep_wrapper.write_text(
      "#!/bin/sh\n"
      "printf '%s\\n' \"$1\" >> \"$USB_GADGET_SLEEP_LOG\"\n",
    )
    sleep_wrapper.chmod(0o755)
    self.environment["USB_GADGET_SLEEP_BIN"] = str(sleep_wrapper)
    self.environment["USB_GADGET_SLEEP_LOG"] = str(sleep_log)
    descriptors_before = {
      path: self.read(path)
      for path in (
        self.gadget / "idVendor",
        self.gadget / "idProduct",
        self.gadget / "strings" / "0x409" / "serialnumber",
        self.config / "strings" / "0x409" / "configuration",
        self.lun / "file",
        self.lun / "ro",
        self.lun / "removable",
        self.mass_storage / "stall",
      )
    }
    links_before = {path.name: os.readlink(path) for path in self.config.iterdir() if path.is_symlink()}
    link_log_before = self.link_log.read_text()

    self.run_helper("reenumerate-managed-storage")

    self.assertEqual(self.read(self.gadget / "UDC"), "a600000.dwc3")
    self.assertEqual({path: self.read(path) for path in descriptors_before}, descriptors_before)
    self.assertEqual({path.name: os.readlink(path) for path in self.config.iterdir() if path.is_symlink()}, links_before)
    self.assertEqual(self.link_log.read_text(), link_log_before)
    self.assertEqual(sleep_log.read_text().splitlines(), ["1"])
    self.assert_debug_links()

  def test_managed_storage_reenumeration_preserves_storage_only_personality(self) -> None:
    self.adb_param.write_text("0\n")
    self.run_helper("configure", "0")
    (self.gadget / "idVendor").write_text("0xcafe\n")
    (self.gadget / "idProduct").write_text("0xbeef\n")
    (self.lun / "file").write_text("/run/usb-storage/footage.img\n")

    self.run_helper("reenumerate-managed-storage")

    self.assertEqual(self.read(self.gadget / "UDC"), "a600000.dwc3")
    self.assertEqual(self.read(self.gadget / "idVendor"), "0xcafe")
    self.assertEqual(self.read(self.gadget / "idProduct"), "0xbeef")
    self.assertEqual(self.read(self.lun / "file"), "/run/usb-storage/footage.img")
    self.assert_storage_only_links()

  def test_reenumeration_rejects_unsafe_lun_and_leaves_gadget_unbound(self) -> None:
    self.adb_param.write_text("1\n")
    self.run_helper("configure", "1")
    (self.lun / "file").write_text("/run/usb-storage/footage.img\n")
    (self.lun / "ro").write_text("0\n")

    result = self.run_helper("reenumerate-managed-storage", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("unsafe or unmanaged", result.stderr)
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertEqual(self.read(self.lun / "file"), "/run/usb-storage/footage.img")
    self.assertEqual(self.read(self.lun / "ro"), "0")

  def test_reenumeration_never_binds_partial_or_unexpected_functions(self) -> None:
    for mutation in ("missing-adb", "unexpected-function"):
      with self.subTest(mutation=mutation):
        self.adb_param.write_text("1\n")
        self.run_helper("configure", "1")
        (self.lun / "file").write_text("/run/usb-storage/footage.img\n")
        if mutation == "missing-adb":
          (self.config / "ffs.adb").unlink()
        else:
          unexpected = self.gadget / "functions" / "ecm.0"
          unexpected.mkdir()
          (self.config / "ecm.0").symlink_to(unexpected)

        result = self.run_helper("reenumerate-managed-storage", check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("re-enumerate", result.stderr)
        self.assertEqual(self.read(self.gadget / "UDC"), "")
        self.assertEqual(self.read(self.lun / "file"), "/run/usb-storage/footage.img")

        # Restore a clean fake configfs tree for the next subtest without
        # teaching the product helper how to repair a partial personality.
        if mutation == "missing-adb":
          (self.config / "ffs.adb").symlink_to(self.gadget / "functions" / "ffs.adb")
        else:
          (self.config / "ecm.0").unlink()
          unexpected.rmdir()
        self.run_helper("configure", "1")

  def test_reenumeration_rejects_hidden_foreign_function_without_modifying_it(self) -> None:
    self.adb_param.write_text("1\n")
    self.run_helper("configure", "1")
    (self.lun / "file").write_text("/run/usb-storage/footage.img\n")
    foreign_function = self.gadget / "functions" / "ecm.0"
    foreign_function.mkdir()
    hidden_link = self.config / ".foreign-function"
    hidden_link.symlink_to(foreign_function)

    result = self.run_helper("reenumerate-managed-storage", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("unexpected USB function", result.stderr)
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertEqual(self.read(self.lun / "file"), "/run/usb-storage/footage.img")
    self.assertTrue(hidden_link.is_symlink())
    self.assertEqual(os.readlink(hidden_link), str(foreign_function))

  def test_reenumeration_sleep_failure_stays_unbound_with_media_intact(self) -> None:
    self.adb_param.write_text("1\n")
    self.run_helper("configure", "1")
    (self.lun / "file").write_text("/run/usb-storage/footage.img\n")
    failing_sleep = self.root / "failing-sleep"
    failing_sleep.write_text("#!/bin/sh\nexit 1\n")
    failing_sleep.chmod(0o755)
    self.environment["USB_GADGET_SLEEP_BIN"] = str(failing_sleep)

    result = self.run_helper("reenumerate-managed-storage", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertEqual(self.read(self.lun / "file"), "/run/usb-storage/footage.img")
    self.assert_debug_links()

  def test_configure_rejects_extra_private_lun_without_modifying_it(self) -> None:
    self.adb_param.write_text("1\n")
    self.run_helper("configure", "1")
    extra_lun = self.mass_storage / "lun.1"
    extra_lun.mkdir()
    (extra_lun / "file").write_text("/data/private.img\n")
    (extra_lun / "ro").write_text("0\n")
    (extra_lun / "removable").write_text("0\n")

    result = self.run_helper("configure", "1", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("more than LUN 0", result.stderr)
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertEqual(self.read(extra_lun / "file"), "/data/private.img")
    self.assertEqual(self.read(extra_lun / "ro"), "0")
    self.assertEqual(self.read(extra_lun / "removable"), "0")
    self.assertFalse((self.config / "mass_storage.0").is_symlink())
    self.assertFalse((self.config / "ncm.0").is_symlink())
    self.assertFalse((self.config / "ffs.adb").is_symlink())

  def test_reenumeration_rejects_extra_private_lun_without_modifying_it(self) -> None:
    self.adb_param.write_text("1\n")
    self.run_helper("configure", "1")
    (self.lun / "file").write_text("/run/usb-storage/footage.img\n")
    extra_lun = self.mass_storage / "lun.1"
    extra_lun.mkdir()
    (extra_lun / "file").write_text("/data/private.img\n")
    (extra_lun / "ro").write_text("0\n")
    (extra_lun / "removable").write_text("0\n")

    result = self.run_helper("reenumerate-managed-storage", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("more than LUN 0", result.stderr)
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertEqual(self.read(self.lun / "file"), "/run/usb-storage/footage.img")
    self.assertEqual(self.read(extra_lun / "file"), "/data/private.img")
    self.assertEqual(self.read(extra_lun / "ro"), "0")
    self.assert_debug_links()

  def test_configure_rejects_alternate_config_without_modifying_it(self) -> None:
    self.adb_param.write_text("1\n")
    self.run_helper("configure", "1")
    foreign_function = self.gadget / "functions" / "mass_storage.1"
    foreign_lun = foreign_function / "lun.0"
    foreign_lun.mkdir(parents=True)
    (foreign_lun / "file").write_text("/data/private.img\n")
    (foreign_lun / "ro").write_text("0\n")
    alternate_config = self.gadget / "configs" / "c.2"
    alternate_config.mkdir()
    (alternate_config / "mass_storage.1").symlink_to(foreign_function)

    result = self.run_helper("configure", "1", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("more than configuration c.1", result.stderr)
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertEqual(self.read(foreign_lun / "file"), "/data/private.img")
    self.assertEqual(self.read(foreign_lun / "ro"), "0")
    self.assertTrue((alternate_config / "mass_storage.1").is_symlink())
    self.assertFalse((self.config / "mass_storage.0").is_symlink())
    self.assertFalse((self.config / "ncm.0").is_symlink())
    self.assertFalse((self.config / "ffs.adb").is_symlink())

  def test_reenumeration_rejects_alternate_config_without_modifying_it(self) -> None:
    self.adb_param.write_text("1\n")
    self.run_helper("configure", "1")
    (self.lun / "file").write_text("/run/usb-storage/footage.img\n")
    foreign_function = self.gadget / "functions" / "mass_storage.1"
    foreign_lun = foreign_function / "lun.0"
    foreign_lun.mkdir(parents=True)
    (foreign_lun / "file").write_text("/data/private.img\n")
    alternate_config = self.gadget / "configs" / "c.2"
    alternate_config.mkdir()
    (alternate_config / "mass_storage.1").symlink_to(foreign_function)

    result = self.run_helper("reenumerate-managed-storage", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("more than configuration c.1", result.stderr)
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertEqual(self.read(self.lun / "file"), "/run/usb-storage/footage.img")
    self.assertEqual(self.read(foreign_lun / "file"), "/data/private.img")
    self.assertTrue((alternate_config / "mass_storage.1").is_symlink())
    self.assert_debug_links()

  def test_regular_kernel_mass_storage_attributes_are_preserved(self) -> None:
    self.adb_param.write_text("1\n")
    self.run_helper("configure", "1")
    num_buffers = self.mass_storage / "num_buffers"
    num_buffers.write_text("4\n")

    self.run_helper("configure", "1")
    self.assertEqual(self.read(num_buffers), "4")
    (self.lun / "file").write_text("/run/usb-storage/footage.img\n")

    self.run_helper("reenumerate-managed-storage")

    self.assertEqual(self.read(self.gadget / "UDC"), "a600000.dwc3")
    self.assertEqual(self.read(num_buffers), "4")
    self.assertEqual(self.read(self.lun / "file"), "/run/usb-storage/footage.img")
    self.assert_debug_links()

  def test_clean_storage_stop_preserves_other_usb_functions(self) -> None:
    self.run_helper("configure", "1")

    self.run_helper("finalize-storage-stop")

    self.assertEqual(self.read(self.gadget / "UDC"), "a600000.dwc3")
    self.assertEqual(self.read(self.lun / "file"), "")
    self.assert_debug_links()

  def test_storage_stop_reconstructs_requested_personality_after_fallback_unbind(self) -> None:
    self.adb_param.write_text("1")
    self.run_helper("configure", "1")
    self.run_helper("unbind")

    self.run_helper("finalize-storage-stop")

    self.assertEqual(self.read(self.gadget / "UDC"), "a600000.dwc3")
    self.assertEqual(self.read(self.gadget / "idVendor"), "0x04D8")
    self.assertEqual(self.read(self.gadget / "idProduct"), "0x1234")
    self.assert_debug_links()

  def test_storage_stop_cannot_rebind_without_approved_requested_identity(self) -> None:
    self.run_helper("configure", "1")
    self.run_helper("unbind")
    del self.environment["USB_GADGET_STORAGE_ONLY_VID"]
    del self.environment["USB_GADGET_STORAGE_ONLY_PID"]

    result = self.run_helper("finalize-storage-stop", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("owner-approved", result.stderr)
    self.assertEqual(self.read(self.gadget / "UDC"), "")

  def test_storage_stop_with_attached_media_leaves_gadget_unbound(self) -> None:
    self.run_helper("configure", "1")
    (self.lun / "file").write_text("/run/usb-storage/footage.img\n")

    result = self.run_helper("finalize-storage-stop")

    self.assertIn("media remains attached", result.stderr)
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertEqual(self.read(self.lun / "file"), "/run/usb-storage/footage.img")
    self.assert_debug_links()

  def test_post_stop_cleanup_is_noop_for_clean_managed_personality(self) -> None:
    self.adb_param.write_text("1\n")
    self.run_helper("configure", "1")

    self.run_helper("prepare-storage-post-stop")

    self.assertEqual(self.read(self.gadget / "UDC"), "a600000.dwc3")
    self.assertEqual(self.read(self.lun / "file"), "")
    self.assert_debug_links()

  def test_post_stop_cleanup_clears_managed_media_and_stays_unbound(self) -> None:
    self.adb_param.write_text("1\n")
    self.run_helper("configure", "1")
    (self.lun / "file").write_text("/run/usb-storage/footage.img\n")

    self.run_helper("prepare-storage-post-stop")

    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertEqual(self.read(self.lun / "file"), "")
    self.assert_debug_links()

  def test_post_stop_cleanup_preserves_foreign_media_and_fails_unbound(self) -> None:
    self.adb_param.write_text("1\n")
    self.run_helper("configure", "1")
    (self.lun / "file").write_text("/data/private.img\n")

    result = self.run_helper("prepare-storage-post-stop", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("foreign", result.stderr)
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertEqual(self.read(self.lun / "file"), "/data/private.img")
    self.assert_debug_links()

  def test_post_stop_cleanup_releases_media_before_rejecting_foreign_links(self) -> None:
    self.adb_param.write_text("1\n")
    self.run_helper("configure", "1")
    (self.lun / "file").write_text("/run/usb-storage/footage.img\n")
    foreign_function = self.gadget / "functions" / "ecm.0"
    foreign_function.mkdir()
    hidden_link = self.config / ".foreign-function"
    hidden_link.symlink_to(foreign_function)

    self.run_helper("prepare-storage-post-stop")

    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertEqual(self.read(self.lun / "file"), "")
    self.assertTrue(hidden_link.is_symlink())

    result = self.run_helper("ensure-requested-personality", check=False)
    self.assertNotEqual(result.returncode, 0)
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertTrue(hidden_link.is_symlink())

  def test_post_stop_cleanup_preserves_unsafe_managed_lun_policy(self) -> None:
    self.adb_param.write_text("1\n")
    self.run_helper("configure", "1")
    (self.lun / "file").write_text("/run/usb-storage/footage.img\n")
    (self.lun / "ro").write_text("0\n")

    result = self.run_helper("prepare-storage-post-stop", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("policy is unsafe", result.stderr)
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertEqual(self.read(self.lun / "file"), "/run/usb-storage/footage.img")
    self.assertEqual(self.read(self.lun / "ro"), "0")

  def test_post_stop_cleanup_never_follows_lun_attribute_symlink(self) -> None:
    self.adb_param.write_text("1\n")
    self.run_helper("configure", "1")
    foreign_attribute = self.root / "foreign-lun-file"
    foreign_attribute.write_text("/run/usb-storage/footage.img\n")
    (self.lun / "file").unlink()
    (self.lun / "file").symlink_to(foreign_attribute)

    result = self.run_helper("prepare-storage-post-stop", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("unavailable or unsafe", result.stderr)
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertTrue((self.lun / "file").is_symlink())
    self.assertEqual(foreign_attribute.read_text(), "/run/usb-storage/footage.img\n")

  def test_post_stop_cleanup_is_not_blocked_by_adb_off_identity_approval(self) -> None:
    self.adb_param.write_text("1\n")
    self.run_helper("configure", "1")
    (self.lun / "file").write_text("/run/usb-storage/footage.img\n")
    self.adb_param.write_text("0\n")
    del self.environment["USB_GADGET_STORAGE_ONLY_VID"]
    del self.environment["USB_GADGET_STORAGE_ONLY_PID"]

    self.run_helper("prepare-storage-post-stop")

    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertEqual(self.read(self.lun / "file"), "")
    result = self.run_helper("ensure-requested-personality", check=False)
    self.assertNotEqual(result.returncode, 0)
    self.assertIn("owner-approved", result.stderr)
    self.assertEqual(self.read(self.gadget / "UDC"), "")

  def test_post_stop_cleanup_releases_media_despite_partial_descriptors(self) -> None:
    self.adb_param.write_text("1\n")
    self.run_helper("configure", "1")
    (self.lun / "file").write_text("/run/usb-storage/footage.img\n")
    (self.gadget / "idProduct").write_text("0xffff\n")
    (self.config / "ffs.adb").unlink()

    self.run_helper("prepare-storage-post-stop")

    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertEqual(self.read(self.lun / "file"), "")
    self.run_helper("ensure-requested-personality")
    self.assertEqual(self.read(self.gadget / "UDC"), "a600000.dwc3")
    self.assertEqual(self.read(self.gadget / "idProduct"), "0x1234")
    self.assert_debug_links()

  def test_post_stop_cleanup_unbinds_empty_partial_personality_before_repair(self) -> None:
    self.adb_param.write_text("1\n")
    self.run_helper("configure", "1")
    (self.gadget / "idProduct").write_text("0xffff\n")
    (self.config / "ffs.adb").unlink()

    self.run_helper("prepare-storage-post-stop")

    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertEqual(self.read(self.lun / "file"), "")
    self.run_helper("ensure-requested-personality")
    self.assertEqual(self.read(self.gadget / "UDC"), "a600000.dwc3")
    self.assertEqual(self.read(self.gadget / "idProduct"), "0x1234")
    self.assert_debug_links()

  def test_storage_start_clears_only_managed_media_before_rebinding(self) -> None:
    self.adb_param.write_text("1")
    self.run_helper("configure", "1")
    (self.lun / "file").write_text("/run/usb-storage/footage.img\n")

    self.run_helper("prepare-storage-start")

    self.assertEqual(self.read(self.gadget / "UDC"), "a600000.dwc3")
    self.assertEqual(self.read(self.lun / "file"), "")
    self.assert_debug_links()

    (self.lun / "file").write_text("/tmp/foreign.img\n")
    result = self.run_helper("prepare-storage-start", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertIn("foreign", result.stderr)
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertEqual(self.read(self.lun / "file"), "/tmp/foreign.img")

  def test_failed_personality_transition_never_restores_mixed_identity(self) -> None:
    self.run_helper("configure", "1")
    failing_link = self.root / "failing-link"
    failing_link.write_text("#!/bin/sh\nexit 1\n")
    failing_link.chmod(0o755)
    self.environment["USB_GADGET_LN_BIN"] = str(failing_link)

    result = self.run_helper("configure", "0", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertEqual(self.read(self.gadget / "idVendor"), "0xCAFE")
    self.assertEqual(self.read(self.gadget / "idProduct"), "0xBEEF")
    self.assertFalse((self.config / "ncm.0").is_symlink())
    self.assertFalse((self.config / "ffs.adb").is_symlink())
    self.assertFalse((self.config / "mass_storage.0").is_symlink())

    # A later service stop must not raw-bind this partial personality.
    del self.environment["USB_GADGET_STORAGE_ONLY_VID"]
    del self.environment["USB_GADGET_STORAGE_ONLY_PID"]
    result = self.run_helper("finalize-storage-stop", check=False)
    self.assertNotEqual(result.returncode, 0)
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertFalse((self.config / "mass_storage.0").is_symlink())

  def test_failed_transition_after_managed_lun_clear_stays_unbound(self) -> None:
    self.run_helper("configure", "1")
    (self.lun / "file").write_text("/run/usb-storage/footage.img\n")
    failing_link = self.root / "failing-link-after-clear"
    failing_link.write_text("#!/bin/sh\nexit 1\n")
    failing_link.chmod(0o755)
    self.environment["USB_GADGET_LN_BIN"] = str(failing_link)

    result = self.run_helper("configure", "0", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertEqual(self.read(self.lun / "file"), "")
    self.assertEqual(self.read(self.gadget / "idVendor"), "0xCAFE")
    self.assertEqual(self.read(self.gadget / "idProduct"), "0xBEEF")
    self.assertFalse((self.config / "ncm.0").is_symlink())
    self.assertFalse((self.config / "ffs.adb").is_symlink())
    self.assertFalse((self.config / "mass_storage.0").is_symlink())

  def test_storage_start_reconstructs_instead_of_binding_partial_transition(self) -> None:
    self.run_helper("configure", "1")
    failing_link = self.root / "failing-link-before-start"
    failing_link.write_text("#!/bin/sh\nexit 1\n")
    failing_link.chmod(0o755)
    self.environment["USB_GADGET_LN_BIN"] = str(failing_link)
    result = self.run_helper("configure", "0", check=False)
    self.assertNotEqual(result.returncode, 0)
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertFalse((self.config / "mass_storage.0").is_symlink())

    self.environment["USB_GADGET_LN_BIN"] = str(self.link_wrapper)
    self.run_helper("prepare-storage-start")

    self.assertEqual(self.read(self.gadget / "UDC"), "a600000.dwc3")
    self.assertEqual(self.read(self.gadget / "idVendor"), "0xCAFE")
    self.assertEqual(self.read(self.gadget / "idProduct"), "0xBEEF")
    self.assert_storage_only_links()

  def test_requested_personality_recovery_serializes_partial_failed_state(self) -> None:
    self.run_helper("configure", "1")
    failing_link = self.root / "failing-concurrent-link"
    failing_link.write_text("#!/bin/sh\nexit 1\n")
    failing_link.chmod(0o755)
    self.environment["USB_GADGET_LN_BIN"] = str(failing_link)

    result = self.run_helper("configure", "0", check=False)

    self.assertNotEqual(result.returncode, 0)
    self.assertEqual(self.read(self.gadget / "UDC"), "")
    self.assertFalse((self.config / "mass_storage.0").is_symlink())

    # Use a portable flock shim so this concurrency check also runs on macOS.
    # flock(2) is attached to the inherited open file description, so the
    # parent shell keeps the lock after this helper exits and until it closes
    # descriptor 9.
    flock_wrapper = self.root / "flock"
    flock_wrapper.write_text(
      "#!/usr/bin/env python3\n"
      "import fcntl\n"
      "import sys\n"
      "fcntl.flock(int(sys.argv[-1]), fcntl.LOCK_EX)\n",
    )
    flock_wrapper.chmod(0o755)
    slow_link = self.root / "slow-logged-ln"
    slow_link.write_text(
      "#!/bin/sh\n"
      "sleep 0.1\n"
      "printf '%s\\n' \"${3##*/}\" >> \"$USB_GADGET_LINK_LOG\"\n"
      "exec /bin/ln \"$@\"\n",
    )
    slow_link.chmod(0o755)
    self.environment["USB_GADGET_FLOCK_BIN"] = str(flock_wrapper)
    self.environment["USB_GADGET_LN_BIN"] = str(slow_link)
    self.adb_param.write_text("1\n")
    self.link_log.write_text("")

    processes = [
      subprocess.Popen(
        [str(GADGET_HELPER), "ensure-requested-personality"],
        env=self.environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
      )
      for _ in range(2)
    ]
    results = [process.communicate(timeout=10) for process in processes]

    self.assertEqual([process.returncode for process in processes], [0, 0], results)
    self.assertEqual(self.read(self.gadget / "UDC"), "a600000.dwc3")
    self.assertEqual(self.read(self.gadget / "idVendor"), "0x04D8")
    self.assertEqual(self.read(self.gadget / "idProduct"), "0x1234")
    self.assertEqual(self.link_log.read_text().splitlines(), ["ncm.0", "ffs.adb", "mass_storage.0"])
    self.assert_debug_links()

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
    self.assert_storage_only_links()

  def test_storage_service_reuses_adb_watcher_configuration(self) -> None:
    unit = STORAGE_SERVICE.read_text()

    self.assertIn("Requires=comma-init.service adb-param-watcher.service", unit)
    self.assertNotIn("ExecStartPre=/usr/comma/set_adb.sh", unit)
    self.assertLess(
      unit.index("ExecStartPre=/usr/comma/usb_gadget.sh prepare-storage-start"),
      unit.index("ExecStartPre=-/usr/bin/fusermount3 -uz /run/usb-storage"),
    )

  def test_storage_service_backs_off_repeated_start_failures(self) -> None:
    unit = STORAGE_SERVICE.read_text()

    self.assertIn("Restart=on-failure\n", unit)
    self.assertIn("RestartSec=5\n", unit)
    self.assertIn("RestartSteps=5\n", unit)
    self.assertIn("RestartMaxDelaySec=5min\n", unit)

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
      "printf '%s\\n' \"$1\" >> \"$USB_STORAGE_STOP_TEST_LOG\"\n",
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
      self.assertEqual(event_log.read_text().splitlines(), ["manager-ready", "manager-exit", "finalize-storage-stop"])
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
      "printf '%s\\n' \"$1\" >> \"$USB_STORAGE_STOP_TEST_LOG\"\n",
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
      self.assertEqual(event_log.read_text().splitlines(), ["manager-ready", "finalize-storage-stop"])
    finally:
      if process.poll() is None:
        process.send_signal(signal.SIGKILL)
        process.wait(timeout=2)


if __name__ == "__main__":
  unittest.main()
