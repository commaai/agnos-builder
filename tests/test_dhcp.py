import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('dhcp', Path(__file__).resolve().parents[1] / 'userspace/root/usr/comma/dhcp.py')
dhcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dhcp)


class TestDHCP(unittest.TestCase):
  def test_bound_and_lost_lease(self):
    with tempfile.TemporaryDirectory() as tmp, patch.object(dhcp.subprocess, 'run') as run:
      with patch.object(dhcp, 'Path', side_effect=lambda p: Path(tmp) / Path(p).name):
        env = {'interface': 'wlan0', 'ip': '192.168.1.2', 'subnet': '255.255.255.0',
               'router': '192.168.1.1', 'dns': '192.168.1.1 1.1.1.1', 'DHCP_TOKEN': 'test'}
        dhcp.apply('bound', env)
        self.assertTrue((Path(tmp) / 'dhcp-wlan0.json').exists())
        calls = [c.args[0] for c in run.call_args_list]
        self.assertIn(['ip', '-4', 'route', 'replace', 'default', 'via', '192.168.1.1', 'dev', 'wlan0', 'metric', '600'], calls)
        dhcp.apply('deconfig', env)
        self.assertFalse((Path(tmp) / 'dhcp-wlan0.json').exists())
        run.assert_called_with(['resolvconf', '-d', 'wlan0'], check=True)

  def test_invalid_offer_does_not_touch_network(self):
    with patch.object(dhcp.subprocess, 'run') as run:
      with self.assertRaises(ValueError):
        dhcp.apply('bound', {'interface': 'wlan0', 'ip': '192.168.1.2', 'router': '1.1.1.1;rm -rf /'})
      run.assert_not_called()


if __name__ == '__main__':
  unittest.main()
