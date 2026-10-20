#!/usr/bin/python3
"""udhcpc hook shared by Wi-Fi and Ethernet."""
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def apply(event, env):
  interface = env['interface']
  if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,14}', interface):
    raise ValueError('invalid interface')
  lease = Path(f'/run/dhcp-{interface}.json')
  if event in ('deconfig', 'nak', 'leasefail'):
    subprocess.run(['ip', '-4', 'route', 'flush', 'dev', interface], check=False)
    subprocess.run(['ip', '-4', 'addr', 'flush', 'dev', interface], check=False)
    subprocess.run(['resolvconf', '-d', interface], check=True)
    lease.unlink(missing_ok=True)
  elif event in ('bound', 'renew'):
    address = ipaddress.IPv4Interface(f"{env['ip']}/{env.get('subnet', '255.255.255.0')}")
    routers = [str(ipaddress.IPv4Address(r)) for r in env.get('router', '').split()]
    dns = [str(ipaddress.IPv4Address(d)) for d in env.get('dns', '').split()]
    metric = '600' if interface == 'wlan0' else '100'
    # Flush the previous lease, including its connected and default routes.
    subprocess.run(['ip', '-4', 'route', 'flush', 'dev', interface], check=True)
    subprocess.run(['ip', '-4', 'addr', 'flush', 'dev', interface], check=True)
    subprocess.run(['ip', '-4', 'addr', 'add', str(address), 'dev', interface], check=True)
    if routers:
      subprocess.run(['ip', '-4', 'route', 'replace', 'default', 'via', routers[0], 'dev', interface, 'metric', metric], check=True)
    content = ''.join(f'nameserver {d}\n' for d in dns)
    domain = env.get('domain', '')
    if domain and all(re.fullmatch(r'[A-Za-z0-9_.-]+', d) for d in domain.split()):
      content += f'search {domain}\n'
    subprocess.run(['resolvconf', '-a', interface], input=content, text=True, check=True)
    tmp = lease.with_suffix('.tmp')
    tmp.write_text(json.dumps({'ip': str(address.ip), 'token': env.get('DHCP_TOKEN', '')}))
    tmp.replace(lease)


if __name__ == '__main__':
  apply(sys.argv[1], os.environ)
