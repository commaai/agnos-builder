import concurrent.futures
from pathlib import Path
import runpy
import tempfile
import unittest

update = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'userspace/root/usr/local/bin/resolvconf'))['update']


class TestResolver(unittest.TestCase):
  def test_handover(self):
    with tempfile.TemporaryDirectory() as tmp:
      root = Path(tmp)
      update('-a', 'ppp0', 'nameserver 1.1.1.1\n', root)
      update('-a', 'NetworkManager', 'search home\nnameserver 192.168.1.1\n', root)
      self.assertEqual((root / 'resolv.conf').read_text(), 'search home\nnameserver 192.168.1.1\nnameserver 1.1.1.1\n')
      update('-d', 'NetworkManager', '', root)
      self.assertEqual((root / 'resolv.conf').read_text(), 'nameserver 1.1.1.1\n')
      update('-d', 'ppp0', '', root)
      self.assertEqual((root / 'resolv.conf').read_text(), '\n')

  def test_invalid_update_preserves_dns(self):
    with tempfile.TemporaryDirectory() as tmp:
      root = Path(tmp)
      update('-a', 'ppp0', 'nameserver 1.1.1.1', root)
      for interface, content in [('ppp0', 'nameserver not-an-ip'), ('../../etc/passwd', ''), ('.lock', '')]:
        with self.assertRaises(ValueError):
          update('-a', interface, content, root)
      self.assertEqual((root / 'resolv.conf').read_text(), 'nameserver 1.1.1.1\n')

  def test_concurrent_updates(self):
    with tempfile.TemporaryDirectory() as tmp, concurrent.futures.ThreadPoolExecutor() as pool:
      root = Path(tmp)
      jobs = [pool.submit(update, '-a', f'link{i}', f'nameserver 10.0.0.{i}', root) for i in range(1, 20)]
      for job in jobs:
        job.result()
      self.assertEqual(len((root / 'resolv.conf').read_text().splitlines()), 19)


if __name__ == '__main__':
  unittest.main()
