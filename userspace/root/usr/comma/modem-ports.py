#!/usr/bin/python3
"""Maintain modem.py's port aliases when booting without udev."""
import grp
import os
from pathlib import Path
import time

TTY_CLASS = Path('/sys/class/tty')
DEV = Path('/dev')
CDC_UNBIND = Path('/sys/bus/usb/drivers/cdc_ether/unbind')


def modem_port(tty):
  interface = None
  for parent in (tty.resolve(), *tty.resolve().parents):
    if (parent / 'bInterfaceNumber').exists():
      interface = (parent / 'bInterfaceNumber').read_text().strip()
    if (parent / 'idVendor').exists():
      vendor = (parent / 'idVendor').read_text().strip()
      product = (parent / 'idProduct').read_text().strip()
      if vendor == '2c7c' and product in ('0125', '6007') and interface in ('02', '03'):
        return int(interface, 16) - 2, parent, product
      break
  return None


def update_ports(dialout_gid):
  ports = {}
  for tty in TTY_CLASS.glob('ttyUSB*'):
    try:
      port = modem_port(tty)
      if port is None:
        continue
      index, usb_device, product = port
      node = DEV / tty.name
      info = node.stat()
      if info.st_gid != dialout_gid or info.st_mode & 0o777 != 0o660:
        os.chown(node, 0, dialout_gid)
        node.chmod(0o660)
      ports[index] = node

      # EG91 uses PPP; detach its unused Ethernet interface as the old rule did.
      ethernet = usb_device / f'{usb_device.name}:1.4'
      if product == '6007' and (ethernet / 'driver').resolve().name == 'cdc_ether':
        CDC_UNBIND.write_text(ethernet.name)
    except FileNotFoundError:
      continue  # The USB device may disappear during enumeration.

  for index in (0, 1):
    alias = DEV / f'modem_at{index}'
    node = ports.get(index)
    if node is None:
      alias.unlink(missing_ok=True)
    elif not alias.is_symlink() or os.readlink(alias) != str(node):
      alias.unlink(missing_ok=True)
      alias.symlink_to(node)


if __name__ == '__main__':
  dialout_gid = grp.getgrnam('dialout').gr_gid
  while True:
    update_ports(dialout_gid)
    time.sleep(0.25)
