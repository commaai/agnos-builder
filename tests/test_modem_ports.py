import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import call, patch

spec = importlib.util.spec_from_file_location("modem", Path(__file__).resolve().parents[1] / "userspace/root/usr/comma/modem.py")
modem = importlib.util.module_from_spec(spec)
spec.loader.exec_module(modem)


class TestModemPorts(unittest.TestCase):
  def setUp(self):
    self.directory = tempfile.TemporaryDirectory()
    self.addCleanup(self.directory.cleanup)
    self.root = Path(self.directory.name)
    self.sysfs = self.root / "sys/class/tty"
    self.sysfs.mkdir(parents=True)

  def port(self, name, device="1-1", interface=2, vendor="2c7c", product="0125"):
    usb = self.root / "sys/devices" / device
    usb.mkdir(parents=True, exist_ok=True)
    (usb / "idVendor").write_text(vendor + "\n")
    (usb / "idProduct").write_text(product + "\n")
    intf = usb / f"{device}:1.{interface}"
    intf.mkdir(exist_ok=True)
    (intf / "bInterfaceNumber").write_text(f"{interface:02x}\n")
    node = intf / name / "tty" / name
    node.mkdir(parents=True, exist_ok=True)
    (self.sysfs / name).symlink_to(node)
    return node

  def test_usb_interface_roles_ignore_tty_number_order(self):
    self.port("ttyUSB11", interface=2)
    self.port("ttyUSB4", interface=3)
    self.port("ttyUSB30", interface=0)
    self.assertEqual(modem._modem_ports(self.sysfs), ("/dev/ttyUSB11", "/dev/ttyUSB4"))

  def test_eg91(self):
    self.port("ttyUSB2", interface=2, product="6007")
    self.port("ttyUSB3", interface=3, product="6007")
    self.assertEqual(modem._modem_ports(self.sysfs), ("/dev/ttyUSB2", "/dev/ttyUSB3"))

  def test_external_at_device_is_not_probed_or_linked(self):
    self.port("ttyUSB2", interface=2)
    self.port("ttyUSB3", interface=3)
    self.port("ttyUSB7", device="2-1", interface=2, vendor="1234", product="5678")
    ports = modem._modem_ports(self.sysfs)
    with patch.object(modem, "_modem_ports", return_value=ports), \
         patch.object(modem, "_answers_at", return_value=True) as answers, \
         patch.object(modem.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run, \
         patch.object(modem, "AT_LOCK", str(self.root / "modem.lock")):
      self.assertTrue(modem.Modem()._sync_ports())
    self.assertEqual(answers.call_args_list, [call("/dev/ttyUSB2"), call("/dev/ttyUSB3")])
    self.assertEqual([c.args[0] for c in run.call_args_list if c.args[0][1] == "ln"], [
      ["sudo", "ln", "-sfn", "ttyUSB2", modem.AT_PORT],
      ["sudo", "ln", "-sfn", "ttyUSB3", modem.PPP_PORT],
    ])
    self.assertNotIn("ttyUSB7", str(run.call_args_list))

  def test_interfaces_from_different_modems_are_not_paired(self):
    self.port("ttyUSB2", interface=2)
    self.port("ttyUSB7", device="2-1", interface=3)
    self.assertIsNone(modem._modem_ports(self.sysfs))

  def test_partial_enumeration_is_retried(self):
    self.port("ttyUSB2", interface=2)
    self.assertIsNone(modem._modem_ports(self.sysfs))
    self.port("ttyUSB3", interface=3)
    self.assertEqual(modem._modem_ports(self.sysfs), ("/dev/ttyUSB2", "/dev/ttyUSB3"))

  def test_disappearing_and_renumbered_nodes(self):
    control = self.port("ttyUSB2", interface=2)
    self.port("ttyUSB3", interface=3)
    control.rmdir()  # The sysfs class link is temporarily dangling.
    self.assertIsNone(modem._modem_ports(self.sysfs))
    (self.sysfs / "ttyUSB2").unlink()
    (self.sysfs / "ttyUSB3").unlink()
    self.port("ttyUSB10", interface=2)
    self.port("ttyUSB8", interface=3)
    self.assertEqual(modem._modem_ports(self.sysfs), ("/dev/ttyUSB10", "/dev/ttyUSB8"))

  def test_multiple_complete_modems_are_ambiguous(self):
    for device, control, data in [("1-1", "ttyUSB2", "ttyUSB3"), ("2-1", "ttyUSB6", "ttyUSB7")]:
      self.port(control, device=device, interface=2)
      self.port(data, device=device, interface=3)
    self.assertIsNone(modem._modem_ports(self.sysfs))

  def test_at_readiness_is_still_required(self):
    with patch.object(modem, "_modem_ports", return_value=("/dev/ttyUSB2", "/dev/ttyUSB3")), \
         patch.object(modem, "_answers_at", side_effect=[True, False]), \
         patch.object(modem.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run, \
         patch.object(modem, "AT_LOCK", str(self.root / "modem.lock")):
      self.assertFalse(modem.Modem()._sync_ports())
    self.assertFalse(any(c.args[0][1] == "ln" for c in run.call_args_list))


if __name__ == "__main__":
  unittest.main()
