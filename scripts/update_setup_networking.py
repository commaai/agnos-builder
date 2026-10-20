#!/usr/bin/env python3
"""Update network code in the shipped UI zipapps without changing their UI/assets.

Usage: scripts/update_setup_networking.py /path/to/companion/openpilot
The packaged apps predate openpilot's system.hardware -> common.hardware move.
Transplant the pure network methods to retain the packaged UI's module layout.
"""
import ast
from pathlib import Path
import sys
import zipfile


def functions(source, class_name=None):
  tree = ast.parse(source)
  if class_name:
    tree = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == class_name)
  lines = source.splitlines(keepends=True)
  return {n.name: ''.join(lines[min([n.lineno] + [d.lineno for d in n.decorator_list])-1:n.end_lineno])
          for n in tree.body if isinstance(n, ast.FunctionDef)}


def replace_methods(source, replacements, remove=()):
  lines = source.splitlines(keepends=True)
  edits = []
  for cls in ast.parse(source).body:
    if isinstance(cls, ast.ClassDef):
      for node in cls.body:
        if isinstance(node, ast.FunctionDef) and node.name in (*replacements, *remove):
          start = min([node.lineno] + [d.lineno for d in node.decorator_list]) - 1
          edits.append((start, node.end_lineno, replacements.get(node.name, '') + '\n'))
  for start, end, text in sorted(edits, reverse=True):
    lines[start:end] = [text]
  return ''.join(lines)


def main(op):
  root = Path(__file__).resolve().parents[1]
  hw = (op / 'openpilot/common/hardware/comma/hardware.py').read_text()
  methods = functions(hw, 'HardwareComma')
  helpers = functions(hw)
  replacements = {name: methods[name].replace('WEBBING_ICCID_PREFIX', '"8985235"') for name in
                  ('get_network_type', 'get_network_strength', 'get_network_metered')}
  for name in ('setup', 'reset', 'updater'):
    path = root / 'userspace/root/usr/comma' / name
    with zipfile.ZipFile(path) as archive:
      contents = {n: archive.read(n) for n in archive.namelist()}
    for module in ('openpilot/common/wifi.py', 'openpilot/system/ui/lib/wifi_manager.py'):
      contents[module] = (op / module).read_bytes()
    hardware = 'openpilot/system/hardware/tici/hardware.py'
    source = contents[hardware].decode()
    source = replace_methods(source, replacements, ('bus', 'nm', 'get_wlan'))
    if 'def wpa_supplicant_cmd(' not in source:
      source = 'import socket\n' + source + '\n\n' + helpers['wpa_supplicant_cmd'] + '\n\n' + helpers['get_default_route_iface'] + '\n'
    contents[hardware] = source.encode()
    setup = 'openpilot/system/ui/mici_setup.py'
    contents[setup] = contents[setup].replace(b'"systemctl", "restart", "systemd-timesyncd"', b'"sv", "restart", "/etc/service/ntpd"')
    contents.pop('openpilot/system/ui/lib/networkmanager.py', None)
    # Fixed ZIP metadata keeps regeneration reviewable and reproducible.
    tmp = path.with_suffix('.tmp')
    tmp.write_bytes(b'#!/usr/bin/env python3\n')
    with zipfile.ZipFile(tmp, 'a', compression=zipfile.ZIP_DEFLATED) as archive:
      for filename, content in sorted(contents.items()):
        if filename.endswith('.py'):
          compile(content, filename, 'exec')
        info = zipfile.ZipInfo(filename, (2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, content)
    tmp.chmod(0o755)
    tmp.replace(path)
    print(f'Updated {name}')


if __name__ == '__main__':
  main(Path(sys.argv[1]))
