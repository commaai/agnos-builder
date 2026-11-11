import importlib.util
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import socket
import threading
import time
import unittest

spec = importlib.util.spec_from_file_location('ntp', Path(__file__).resolve().parents[1] / 'userspace/root/usr/comma/ntpd.py')
n = importlib.util.module_from_spec(spec)
spec.loader.exec_module(n)

class Tests(unittest.TestCase):
  def exchange(self, fault=None):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(('127.0.0.1', 0))
    address = (socket.AF_INET, socket.SOCK_DGRAM, 0, '', sock.getsockname())
    def serve():
      try:
        req, peer = sock.recvfrom(512)
        if fault == 'loss':
          return
        reply = bytearray(48)
        reply[0], reply[1] = 0x24, 2
        reply[24:32] = req[40:48]
        reply[32:40] = reply[40:48] = n.stamp(2100000000 + n.EPOCH)
        if fault == 'origin':
          reply[24] ^= 1
        if fault == 'unsync':
          reply[0] |= 0xc0
        if fault == 'mode':
          reply[0] = 0x23
        if fault == 'zero':
          reply[40:48] = bytes(8)
        if fault == 'delay':
          time.sleep(.03)
        sock.sendto(reply, peer)
      finally:
        sock.close()
    thread = threading.Thread(target=serve)
    thread.start()
    try:
      return n.query(address, .1, 2100000000)
    finally:
      thread.join()
  def test_valid_and_delay(self):
    for fault in (None, 'delay'):
      value, _, elapsed = self.exchange(fault)
      self.assertAlmostEqual(value, 2100000000, delta=.1)
      self.assertLess(elapsed, .1)
  def test_faults(self):
    for fault in ('loss', 'origin', 'unsync', 'mode', 'zero'):
      with self.subTest(fault=fault), self.assertRaises((OSError, ValueError)):
        self.exchange(fault)
  def test_dns_recovery_and_clock_set(self):
    args = SimpleNamespace(servers=['test'], port=123, timeout=.02, era_pivot=1794355200,
                           retry=.001, max_retry=.002, dry_run=False, once=False)
    address = (socket.AF_INET, socket.SOCK_DGRAM, 0, '', ('127.0.0.1', 123))
    calls = []
    with patch.object(n, 'resolve', side_effect=[socket.gaierror(), [address]]) as dns, \
         patch.object(n, 'query', side_effect=lambda *a: (1794355200, time.monotonic(), .01)):
      n.run(args, setter=lambda clock, value: calls.append((clock, value)))
    self.assertEqual(dns.call_count, 2)
    self.assertEqual(len(calls), 1)
    self.assertEqual(calls[0][0], time.CLOCK_REALTIME)
    self.assertAlmostEqual(calls[0][1], 1794355200, delta=.1)

  def test_era(self):
    for unix in (1700000000, 2100000000, 4300000000):
      self.assertAlmostEqual(n.decode(n.stamp(unix+n.EPOCH), unix+n.EPOCH)-n.EPOCH, unix)

if __name__ == '__main__':
  unittest.main(verbosity=2)
