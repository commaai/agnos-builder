import importlib.util
from pathlib import Path
from subprocess import CompletedProcess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("modem", Path(__file__).resolve().parents[1] / "userspace/root/usr/comma/modem.py")
modem = importlib.util.module_from_spec(spec)
spec.loader.exec_module(modem)

IP = "10.77.1.2"
PEER = "10.64.64.64"
DNS = ["8.8.8.8", "1.1.1.1"]
ROUTES = [
  ["sudo", "ip", "route", "add", "default", "via", PEER, "dev", "ppp0", "metric", "1000"],
  ["sudo", "ip", "route", "add", "default", "via", PEER, "dev", "ppp0", "table", "1000"],
  ["sudo", "ip", "rule", "add", "from", IP, "table", "1000"],
]
RESOLVER = [["sudo", "resolvectl", "dns", "ppp0", *DNS], ["sudo", "resolvectl", "default-route", "ppp0", "yes"]]


class TestModemConnectivity(unittest.TestCase):
  def setUp(self):
    self.reset_session()
    run = patch.object(modem.subprocess, "run", side_effect=self.command)
    run.start()
    self.addCleanup(run.stop)

  def reset_session(self):
    self.modem = modem.Modem()
    self.commands = []
    self.failure = None
    self.address = f"    inet {IP} peer {PEER}/32 scope global ppp0\n"
    dns = patch.object(self.modem, "_read_cellular_dns", return_value=DNS)
    self.dns = dns.start()
    self.addCleanup(dns.stop)

  def command(self, cmd, **kwargs):
    self.commands.append(cmd)
    if cmd == ["ip", "-4", "addr", "show", "ppp0"]:
      return CompletedProcess(cmd, 0, self.address, "")
    if cmd == self.failure or cmd[:5] == ["sudo", "ip", "rule", "del", "table"]:
      return CompletedProcess(cmd, 1, "", "injected failure")
    return CompletedProcess(cmd, 0, "", "")

  def poll(self):
    state = self.modem._poll_iface()
    self.modem.S.update(state)
    return state

  def assert_disconnected(self, state):
    self.assertFalse(state["connected"])
    self.assertEqual(state["ip_address"], "")

  def test_route_failures_do_not_report_connected(self):
    for command in ROUTES:
      with self.subTest(command=command):
        self.reset_session()
        self.failure = command
        self.assert_disconnected(self.poll())
        self.assertIn(["sudo", "killall", "-9", "pppd"], self.commands)
        self.assertEqual(self.modem._ppp._peer, "")
        self.dns.assert_not_called()

  def test_resolver_failures_do_not_report_connected(self):
    for command in RESOLVER:
      with self.subTest(command=command):
        self.reset_session()
        self.failure = command
        self.assert_disconnected(self.poll())
        self.assertIn(["sudo", "killall", "-9", "pppd"], self.commands)
        self.assertEqual(self.modem._ppp._peer, "")

  def test_late_dns_is_retried_without_redialing(self):
    self.dns.side_effect = [[], DNS]
    self.assert_disconnected(self.poll())
    self.assertTrue(self.poll()["connected"])
    self.assertTrue(self.poll()["connected"])
    self.assertEqual(self.dns.call_count, 2)
    self.assertNotIn(["sudo", "killall", "-9", "pppd"], self.commands)
    for command in ROUTES + RESOLVER:
      self.assertEqual(self.commands.count(command), 1)

  def test_ready_session_does_not_repeat_setup(self):
    for _ in range(3):
      self.assertTrue(self.poll()["connected"])
    self.dns.assert_called_once()
    for command in ROUTES + RESOLVER:
      self.assertEqual(self.commands.count(command), 1)

  def test_peer_change_refreshes_dns(self):
    self.assertTrue(self.poll()["connected"])
    self.address = self.address.replace(PEER, "10.64.64.65")
    self.assertTrue(self.poll()["connected"])
    self.assertEqual(self.dns.call_count, 2)
    self.assertEqual(self.commands.count(RESOLVER[0]), 2)

  def test_interface_loss_clears_connected_state(self):
    self.assertTrue(self.poll()["connected"])
    self.address = ""
    self.assert_disconnected(self.poll())

  def test_missing_peer_does_not_report_connected(self):
    self.address = f"    inet {IP}/32 scope global ppp0\n"
    self.assert_disconnected(self.poll())
    self.dns.assert_not_called()


if __name__ == "__main__":
  unittest.main()
