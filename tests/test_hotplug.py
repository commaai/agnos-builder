import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('hotplug', Path(__file__).resolve().parents[1] / 'userspace/root/usr/comma/hotplug.py')
hotplug = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hotplug)


class TestHotplug(unittest.TestCase):
  def test_modem_reenumeration(self):
    with tempfile.TemporaryDirectory() as tmp:
      root = Path(tmp)
      dev = root / 'dev'
      dev.mkdir()
      usb = root / 'usb-device'
      interface = usb / '1-1:1.2'
      tty = interface / 'ttyUSB7'
      tty.mkdir(parents=True)
      (usb / 'idVendor').write_text('2c7c')
      (usb / 'idProduct').write_text('6007')
      (interface / 'bInterfaceNumber').write_text('02')
      with patch.object(hotplug, 'DEV', dev), patch.object(hotplug, 'permissions') as perms:
        hotplug.handle(tty, 'ttyUSB7', 'tty')
        self.assertEqual((dev / 'modem_at0').readlink(), dev / 'ttyUSB7')
        perms.assert_called_with(dev / 'ttyUSB7', 'dialout', 0o660)
        # Remove has no sysfs attributes left; still remove the stale alias.
        hotplug.handle(root / 'gone', 'ttyUSB7', 'tty', True)
        self.assertFalse((dev / 'modem_at0').is_symlink())
        hotplug.handle(tty, 'ttyUSB9', 'tty')
        self.assertEqual((dev / 'modem_at0').readlink(), dev / 'ttyUSB9')
        # A late removal for the old device cannot erase the new alias.
        hotplug.handle(root / 'gone', 'ttyUSB7', 'tty', True)
        self.assertEqual((dev / 'modem_at0').readlink(), dev / 'ttyUSB9')

  def test_panda_modes(self):
    with tempfile.TemporaryDirectory() as tmp:
      path = Path(tmp)
      for vendor, product in [('bbaa', 'ddee'), ('bbaa', 'ddcc'), ('0483', 'df11')]:
        (path / 'idVendor').write_text(vendor)
        (path / 'idProduct').write_text(product)
        with patch.object(hotplug, 'permissions') as perms:
          hotplug.handle(path, 'bus/usb/001/002', 'usb')
          perms.assert_called_with(Path('/dev/bus/usb/001/002'), 'root', 0o666)


if __name__ == '__main__':
  unittest.main()
