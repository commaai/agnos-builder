#!/usr/bin/python3
"""Publish the serial hostname and SSH service on LAN interfaces."""
import json
from pathlib import Path
import signal
import socket
import subprocess
import time

from zeroconf import IPVersion, ServiceInfo, Zeroconf


def main():
  signal.signal(signal.SIGTERM, lambda *_: exit(0))
  hostname = socket.gethostname()
  model = Path('/sys/firmware/devicetree/base/model').read_text().strip('\x00').removeprefix('comma ')
  service_type = '_ssh._tcp.local.'
  name = f'comma SSH - {model} - [{hostname}].{service_type}'
  current, zeroconf, info = None, None, None
  try:
    while True:
      links = json.loads(subprocess.check_output(['ip', '-j', '-4', 'addr', 'show']))
      addresses = sorted(a['local'] for link in links if not link['ifname'].startswith(('lo', 'ppp', 'wwan'))
                         for a in link.get('addr_info', []) if a.get('scope') == 'global')
      if addresses != current:
        if zeroconf:
          zeroconf.unregister_service(info)
          zeroconf.close()
          zeroconf = None
        if addresses:
          zeroconf = Zeroconf(interfaces=addresses, ip_version=IPVersion.V4Only)
          info = ServiceInfo(service_type, name, addresses=[socket.inet_aton(a) for a in addresses], port=22,
                             properties={'vendor': 'comma', 'device': 'comma', 'model': model}, server=hostname + '.local.')
          zeroconf.register_service(info)
        current = addresses
      time.sleep(2)
  finally:
    if zeroconf:
      zeroconf.unregister_service(info)
      zeroconf.close()


if __name__ == '__main__':
  main()
