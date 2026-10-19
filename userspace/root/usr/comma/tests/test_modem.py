#!/usr/bin/env python3
import json
import os
import shutil
import string
import subprocess
import time
from ipaddress import IPv4Address
from pathlib import Path


def modem_state(timeout=120):
  deadline = time.monotonic() + timeout
  while True:
    try:
      state = json.loads(Path('/dev/shm/modem').read_text())
      if state.get('imei') and state.get('iccid'):
        return state
    except (FileNotFoundError, json.JSONDecodeError):
      pass
    assert time.monotonic() < deadline, "modem.service did not publish modem/SIM identity"
    time.sleep(1)


def test_modem_setup():
  assert not Path('/lib/systemd/system/ModemManager.service').exists()
  assert subprocess.check_output(['systemctl', 'is-enabled', 'modem.service'], text=True).strip() == 'enabled'
  assert subprocess.check_output(['systemctl', 'is-active', 'modem.service'], text=True).strip() == 'active'
  for port in ('/dev/modem_at0', '/dev/modem_at1'):
    assert os.access(port, os.R_OK | os.W_OK), f"comma needs access to {port}"
  for command in ('pppd', 'chat', 'ip', 'resolvectl', 'killall'):
    assert shutil.which(command), f"modem.py requires {command}"
  rules = subprocess.check_output(['sudo', '-n', 'iptables-save', '-t', 'filter'], text=True)
  assert '-A INPUT -i ppp0 -j DROP' in rules


def test_modem():
  state = modem_state()
  assert state['imei'].isdigit() and 14 <= len(state['imei']) <= 17
  assert all(c in string.hexdigits for c in state['iccid']) and 18 <= len(state['iccid']) <= 22
  assert state['modem_version'].startswith(('EG25', 'EG91'))
  assert state['state'] in ('SEARCHING', 'CONNECTING', 'CONNECTED')

  from openpilot.common.hardware import HARDWARE
  assert HARDWARE.get_imei() == state['imei']
  assert HARDWARE.get_sim_info()['sim_id'] == state['iccid']
  assert HARDWARE.get_sim_info()['sim_state'] == ['READY']


def test_cellular_connection():
  # Requires a SIM with service and cellular coverage, even when Wi-Fi is connected.
  state = modem_state()
  assert state['connected'], f"Cellular not connected: {state['state']} ({state['registration']})"
  ip = str(IPv4Address(state['ip_address']))
  routes = subprocess.check_output(['ip', '-4', 'route', 'show', 'table', '1000'], text=True)
  assert 'default' in routes and 'dev ppp0' in routes
  rules = subprocess.check_output(['ip', '-4', 'rule', 'show'], text=True)
  assert any(f'from {ip}' in rule and 'lookup 1000' in rule for rule in rules.splitlines())
  dns = subprocess.check_output(['resolvectl', 'dns', 'ppp0'], text=True)
  assert len(dns.split(':', 1)[-1].split()) > 0
  subprocess.check_call(['ping', '-I', 'ppp0', '-c', '3', '-W', '10', '1.1.1.1'])


if __name__ == '__main__':
  test_modem_setup()
  test_modem()
  test_cellular_connection()
