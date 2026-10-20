import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('wifi', Path(__file__).resolve().parents[1] / 'userspace/root/usr/comma/wifi.py')
wifi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wifi)


class Supplicant:
  def __init__(self):
    self.commands = []
    self.next_id = 0
    self.status = 'wpa_state=DISCONNECTED'
    self.scan = 'bssid / frequency / signal level / flags / ssid\n'

  def call(self, command):
    self.commands.append(command)
    if command == 'ADD_NETWORK':
      self.next_id += 1
      return str(self.next_id)
    if command == 'STATUS':
      return self.status
    if command == 'SCAN_RESULTS':
      return self.scan
    return 'OK'


class TestWifi(unittest.TestCase):
  def setUp(self):
    self.tmp = tempfile.TemporaryDirectory()
    self.addCleanup(self.tmp.cleanup)
    self.path = Path(self.tmp.name) / 'wifi.json'
    self.path.write_text(json.dumps({'version': 1, 'networks': {'A': wifi.validate_network('A', 'password')},
                                    'hotspot': wifi.validate_network('weedle', 'swagswagcomma')}))
    self.ctrl = Supplicant()
    self.wifi = wifi.Wifi(self.ctrl, self.path)

  def test_credentials_not_saved_before_connected(self):
    with patch.object(self.wifi, 'clear_address'):
      self.wifi.command('connect', ssid='B', password='new password')
    self.assertNotIn('B', json.loads(self.path.read_text())['networks'])
    nid = self.wifi.ids['B']
    # An old connection's auth failure cannot clear the new attempt.
    self.wifi.event('CTRL-EVENT-SSID-TEMP-DISABLED id=1 reason=WRONG_KEY')
    self.assertEqual(self.wifi.pending['ssid'], 'B')
    self.wifi.event(f'CTRL-EVENT-SSID-TEMP-DISABLED id={nid} reason=WRONG_KEY')
    self.assertIsNone(self.wifi.pending)
    self.assertEqual(self.wifi.auth_error, 'B')
    self.assertNotIn('B', json.loads(self.path.read_text())['networks'])

  def test_forget_other_network_preserves_selected_attempt(self):
    with patch.object(self.wifi, 'clear_address'):
      self.wifi.command('connect', ssid='B', password='new password')
    self.ctrl.commands.clear()
    self.wifi.command('forget', ssid='A')
    self.assertEqual(self.wifi.pending['ssid'], 'B')
    self.assertNotIn('ENABLE_NETWORK all', self.ctrl.commands)

  def test_credentials_saved_only_with_current_dhcp_lease(self):
    with patch.object(self.wifi, 'clear_address'):
      self.wifi.command('connect', ssid='B', password='new password')
    nid = self.wifi.ids['B']
    self.ctrl.status = f'wpa_state=COMPLETED\nssid=B\nid={nid}'
    self.wifi.link = nid
    self.wifi.dhcp = Mock()
    self.wifi.dhcp.poll.return_value = None
    self.wifi.lease_token = 'current'
    with patch.object(wifi, 'STATE', Path(self.tmp.name) / 'state'):
      with patch.object(Path, 'read_text', return_value=json.dumps({'token': 'old', 'ip': '192.168.1.2'})):
        self.wifi.poll()
      self.assertNotIn('B', json.loads(self.path.read_text())['networks'])
      with patch.object(Path, 'read_text', return_value=json.dumps({'token': 'current', 'ip': '192.168.1.3'})):
        self.wifi.poll()
    self.assertEqual(json.loads(self.path.read_text())['networks']['B']['password'], 'new password')
    self.assertIsNone(self.wifi.pending)

  def test_command_encoding(self):
    self.wifi.add(wifi.validate_network('quoted"\nnetwork', 'password\n!'))
    self.assertTrue(all('\n' not in command for command in self.ctrl.commands))
    self.assertFalse(any('password' in command for command in self.ctrl.commands))
    with self.assertRaises(ValueError):
      self.wifi.add(wifi.validate_network('X' * 33, 'short'))

  def test_invalid_hotspot_password_preserves_config(self):
    before = self.path.read_text()
    with self.assertRaises(ValueError):
      self.wifi.command('hotspot_config', password='')
    self.assertEqual(self.path.read_text(), before)
    self.assertEqual(self.wifi.data['hotspot']['password'], 'swagswagcomma')

  def test_radio_reset_reloads_client_profiles(self):
    self.wifi.pending = wifi.validate_network('B', 'password')
    self.ctrl.commands.clear()
    with patch.object(self.wifi, 'stop_hotspot'):
      self.wifi.command('radio', enabled=False)
      self.assertIsNone(self.wifi.pending)
      self.assertIn('REMOVE_NETWORK all', self.ctrl.commands)
      self.assertNotIn('ENABLE_NETWORK all', self.ctrl.commands)
      self.wifi.command('radio', enabled=True)
    self.assertIn('ENABLE_NETWORK all', self.ctrl.commands)
    self.assertEqual(set(self.wifi.ids), {'A'})

  def test_scan_security_and_strength(self):
    self.ctrl.scan += '00:11:22:33:44:55\t2412\t-55\t[WPA2-PSK-CCMP][ESS]\tcaf\\xc3\\xa9\n'
    self.ctrl.scan += '00:11:22:33:44:66\t2412\t-75\t[WPA2-PSK-CCMP][ESS]\tcaf\\xc3\\xa9\n'
    self.ctrl.scan += '00:11:22:33:44:77\t2412\t-40\t[WPA2-EAP-CCMP][ESS]\tenterprise\n'
    with patch.object(wifi, 'STATE', Path(self.tmp.name) / 'state'):
      self.wifi.poll()
    networks = {n['ssid']: n for n in self.wifi.snapshot['networks']}
    self.assertEqual(networks['café']['strength'], 90)
    self.assertEqual(networks['enterprise']['security_type'], 4)

  def test_migration_keeps_originals(self):
    directory = Path(self.tmp.name)
    profile = directory / 'known.nmconnection'
    profile.write_text('[connection]\nmetered=1\n[wifi]\nssid=99;97;102;195;169;\nhidden=true\n'
                       '[wifi-security]\nkey-mgmt=wpa-psk\npsk=password\n')
    networks, _ = wifi.migrate_connections(directory)
    self.assertEqual(networks['café']['metered'], 1)
    self.assertTrue(networks['café']['hidden'])
    self.assertTrue(profile.exists())

  def test_ssid_unescaping(self):
    self.assertEqual(wifi.unescape_ssid(r'caf\xc3\xa9'), 'café')
    self.assertEqual(wifi.unescape_ssid(r'hello\\world'), 'hello\\world')


if __name__ == '__main__':
  unittest.main()
