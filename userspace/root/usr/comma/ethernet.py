#!/usr/bin/python3
"""Keep a DHCP client on each wired interface with carrier."""
import os
from pathlib import Path
import signal
import socket
import subprocess
import time

from wifi import stop_process


def main():
  clients = {}
  signal.signal(signal.SIGTERM, lambda *_: exit(0))
  try:
    while True:
      interfaces = set()
      for path in Path('/sys/class/net').iterdir():
        try:
          if path.name.startswith(('lo', 'wlan', 'wwan', 'ppp')) or (path / 'wireless').exists() or (path / 'type').read_text().strip() != '1':
            continue
          subprocess.run(['ip', 'link', 'set', path.name, 'up'], check=False)
          if (path / 'carrier').read_text().strip() == '1':
            interfaces.add(path.name)
        except OSError:
          continue
      for name in list(clients):
        if name not in interfaces or clients[name].poll() is not None:
          stop_process(clients.pop(name))
          subprocess.run(['/usr/comma/dhcp.py', 'deconfig'], env={**os.environ, 'interface': name}, check=False)
      for name in interfaces - clients.keys():
        clients[name] = subprocess.Popen(['busybox', 'udhcpc', '-f', '-R', '-i', name, '-x', 'hostname:' + socket.gethostname(), '-s', '/usr/comma/dhcp.py'])
      time.sleep(1)
  finally:
    for client in clients.values():
      stop_process(client)


if __name__ == '__main__':
  main()
