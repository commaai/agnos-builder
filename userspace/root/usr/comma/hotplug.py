#!/usr/bin/python3
"""AGNOS device permissions and stable aliases, called by mdev on add/remove.

All decisions come from sysfs, including USB interface numbers. Never rely on
volatile ttyUSB numbering to identify a modem AT port.
"""
import grp
import os
from pathlib import Path
import subprocess
import sys

DEV = Path('/dev')


def permissions(path, group, mode):
  try:
    path.chmod(mode)
    os.chown(path, 0, grp.getgrnam(group).gr_gid)
  except FileNotFoundError:
    pass  # The device can disappear while handling its event.


def attr(path, name):
  try:
    return (path / name).read_text().strip()
  except OSError:
    return ''


def usb_identity(path):
  interface = ''
  for parent in (path, *path.parents):
    interface = interface or attr(parent, 'bInterfaceNumber')
    vendor, product = attr(parent, 'idVendor'), attr(parent, 'idProduct')
    if vendor and product:
      return vendor, product, interface
  return '', '', interface


def alias(name, device, remove):
  path = DEV / name
  if remove:
    if path.is_symlink() and os.readlink(path) == str(device):
      path.unlink(missing_ok=True)
  else:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f'.{os.getpid()}')
    tmp.symlink_to(device)
    tmp.replace(path)


def handle(path, name, subsystem, remove=False):
  device = DEV / name
  if name.startswith('/') or '..' in Path(name).parts:
    raise ValueError('invalid device name')
  vendor, product, interface = usb_identity(path)
  if subsystem == 'block':
    aliases = []
    if not remove and device.exists():
      result = subprocess.run(['blkid', '-p', '-o', 'export', str(device)], capture_output=True, text=True)
      values = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
      partname = values.get('PART_ENTRY_NAME', '')
      if '/' in partname or partname in ('.', '..'):
        partname = ''
      if partname:
        aliases.append('disk/by-partlabel/' + partname)
        if '1d84000.ufshc' in str(path):
          aliases.append('block/bootdevice/by-name/' + partname)
      if values.get('LABEL') and '/' not in values['LABEL'] and values['LABEL'] not in ('.', '..'):
        aliases.append('disk/by-label/' + values['LABEL'])
      for link in aliases:
        # Labels are names, not paths. Our partition labels are plain ASCII.
        if '/' not in link.rsplit('/', 1)[-1] and '..' not in Path(link).parts:
          alias(link, device, False)
      permissions(device, 'disk', 0o660)
    elif remove:
      for directory in ('disk/by-label', 'disk/by-partlabel', 'block/bootdevice/by-name'):
        for link in (DEV / directory).glob('*'):
          alias(str(link.relative_to(DEV)), device, True)
  elif subsystem == 'tty':
    if remove:
      for link in ('modem_at0', 'modem_at1'):
        alias(link, device, True)
      return
    permissions(device, 'gpio' if name in ('ttyHS0', 'ttyUSB2') else 'dialout', 0o660)
    if vendor == '2c7c' and product in ('0125', '6007') and interface in ('02', '03'):
      alias('modem_at' + str(int(interface) - 2), device, remove)
      if not remove:
        permissions(device, 'dialout', 0o660)
  elif not remove:
    if subsystem == 'input':
      permissions(device, 'root', 0o666)
    elif subsystem == 'sound' or name.startswith('snd/'):
      permissions(device, 'audio', 0o660)
    elif subsystem == 'drm' or name in ('adsprpc-smd', 'kgsl-3d0', 'ion'):
      permissions(device, 'gpu', 0o660)
    elif name.startswith('i2c-') or name == 'gpiochip0':
      permissions(device, 'gpio', 0o660)
    elif subsystem == 'spidev':
      permissions(device, 'root', 0o666)
    elif subsystem == 'usb':
      if (vendor, product) in (('bbaa', 'ddee'), ('bbaa', 'ddcc'), ('0483', 'df11')):
        permissions(device, 'root', 0o666)
      if (vendor, product, interface) == ('2c7c', '6007', '04') and (path / 'driver').exists():
        if (path / 'driver').resolve().name == 'cdc_ether':
          (path / 'driver/unbind').write_text(path.name)
    if subsystem == 'backlight' and path.name == 'panel0-backlight':
      for entry in ('brightness', 'bl_power'):
        permissions(path / entry, 'video', 0o664)
    if subsystem == 'leds' and path.name in ('led:torch_2', 'led:switch_2'):
      permissions(path / 'brightness', 'video', 0o664)
    if subsystem == 'platform' and path.name == 'soc:qcom,dsi-display@0':
      permissions(path / 'max_brightness_percent', 'video', 0o664)
    if subsystem == 'gpio':
      for entry in (path, *path.iterdir()):
        if not entry.is_symlink():
          permissions(entry, 'gpio', 0o770 if entry.is_dir() else 0o660)


def coldplug():
  # mdev -s handles device nodes. These sysfs-only objects have no major/minor.
  for subsystem in ('backlight', 'leds', 'gpio'):
    for path in (Path('/sys/class') / subsystem).glob('*'):
      handle(path.resolve(), path.name, subsystem)
  path = Path('/sys/devices/platform/soc/soc:qcom,dsi-display@0')
  if path.exists():
    handle(path, path.name, 'platform')


if __name__ == '__main__':
  if sys.argv[1:] == ['--coldplug']:
    coldplug()
  else:
    name = os.environ.get('DEVNAME', os.environ.get('MDEV', ''))
    subsystem = os.environ.get('SUBSYSTEM', '')
    if 'DEVPATH' in os.environ:
      path = Path('/sys' + os.environ['DEVPATH'])
    else:  # mdev's initial scan exports MDEV/SUBSYSTEM, but no DEVPATH.
      dev = (DEV / name).stat().st_rdev
      kind = 'block' if subsystem == 'block' else 'char'
      path = Path(f'/sys/dev/{kind}/{os.major(dev)}:{os.minor(dev)}').resolve()
    handle(path, name, subsystem, os.environ.get('ACTION') == 'remove')
