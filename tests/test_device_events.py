import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'userspace/root/usr/comma/uevent_helper.sh'


class TestDeviceEvents(unittest.TestCase):
  def setUp(self):
    self.tmp = tempfile.TemporaryDirectory()
    self.addCleanup(self.tmp.cleanup)
    self.root = Path(self.tmp.name)
    self.dev = self.root / 'dev'
    self.sys = self.root / 'sys'
    self.dev.mkdir()
    self.sys.mkdir()
    # Run the production script with only its filesystem roots redirected. Mock group
    # lookup because the test host need not have AGNOS's input/video groups.
    self.helper = self.root / 'helper.sh'
    self.helper.write_text(HELPER.read_text().replace('/dev/', str(self.dev) + '/').replace('/sys', str(self.sys)))
    bindir = self.root / 'bin'
    bindir.mkdir()
    chgrp = bindir / 'chgrp'
    chgrp.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$GROUP_LOG"\n')
    chgrp.chmod(0o755)
    self.env = os.environ | {'PATH': str(bindir) + ':' + os.environ['PATH'], 'GROUP_LOG': str(self.root / 'groups')}

  def device(self, subsystem, devname, devpath, index=0):
    node = self.dev / devname
    node.parent.mkdir(parents=True, exist_ok=True)
    node.touch()
    node.chmod(0o600)
    path = self.sys / devpath.lstrip('/')
    path.mkdir(parents=True, exist_ok=True)
    (path / 'uevent').write_text(f'DEVNAME={devname}\n')
    (path / 'index').write_text(f'{index}\n')
    class_entry = self.sys / 'class' / subsystem / Path(devname).name
    class_entry.parent.mkdir(parents=True, exist_ok=True)
    class_entry.symlink_to(path)
    return node

  def event(self, subsystem, devname, devpath, action='add'):
    subprocess.run(['/bin/sh', str(self.helper)], check=True,
                   env=self.env | {'ACTION': action, 'SUBSYSTEM': subsystem, 'DEVNAME': devname, 'DEVPATH': devpath})

  def reconcile(self):
    subprocess.run(['/bin/sh', str(self.helper), '--reconcile'], check=True, env=self.env)

  def test_late_input_and_renumbered_touchscreen(self):
    path = '/devices/platform/soc/894000.i2c/i2c-2/2-0017/input/input7/event7'
    node = self.device('input', 'input/event7', path)
    alias = self.dev / 'input/by-path/platform-894000.i2c-event'
    alias.parent.mkdir(parents=True)
    alias.symlink_to('../')  # Repair the invalid alias left by the former sweep.
    self.event('input', 'input/event7', path)
    self.assertEqual(node.stat().st_mode & 0o777, 0o666)
    self.assertEqual(alias.resolve(), node)
    node.unlink()
    path2 = path.replace('input7/event7', 'input8/event8')
    node2 = self.device('input', 'input/event8', path2)
    self.event('input', 'input/event8', path2)
    self.assertEqual(alias.resolve(), node2)

  def test_cameras_existing_and_added_after_reconciliation(self):
    self.reconcile()
    self.assertFalse((self.dev / 'v4l/by-path').exists())
    req_path = '/devices/platform/soc/soc:qcom,cam-req-mgr/video4linux/video9'
    req = self.device('video4linux', 'video9', req_path)
    self.event('video4linux', 'video9', req_path)
    self.assertEqual(req.stat().st_mode & 0o777, 0o660)
    self.assertIn('video ' + str(req), (self.root / 'groups').read_text())
    self.assertEqual((self.dev / 'v4l/by-path/platform-soc:qcom_cam-req-mgr-video-index0').resolve(), req)
    sync_path = '/devices/platform/cam_sync/video4linux/video12'
    sync = self.device('video4linux', 'video12', sync_path)
    media = self.device('media', 'media2', '/devices/platform/soc/media2')
    subdev = self.device('video4linux', 'v4l-subdev4', '/devices/platform/soc/video4linux/v4l-subdev4')
    self.reconcile()  # Nodes added before helper installation are reconciled too.
    self.assertEqual((self.dev / 'v4l/by-path/platform-cam_sync-video-index0').resolve(), sync)
    for node in (sync, media, subdev):
      self.assertEqual(node.stat().st_mode & 0o777, 0o660)

  def test_installation_gap_reconciles_touch_and_usb_without_replayed_events(self):
    path = '/devices/platform/soc/894000.i2c/i2c-2/2-0017/input/input5/event5'
    node = self.device('input', 'input/event5', path)
    usb = self.dev / 'bus/usb/001/002'
    usb.parent.mkdir(parents=True)
    usb.touch()
    usb.chmod(0o600)
    self.reconcile()
    self.assertEqual(node.stat().st_mode & 0o777, 0o666)
    self.assertEqual(usb.stat().st_mode & 0o777, 0o664)
    self.assertEqual((self.dev / 'input/by-path/platform-894000.i2c-event').resolve(), node)
    self.assertIn('input ' + str(node), (self.root / 'groups').read_text())

  def test_encoder_alias_uses_index_not_video_number(self):
    path = '/devices/platform/soc/aa00000.qcom,vidc/video4linux/video81'
    decoder = self.device('video4linux', 'video81', path)
    self.event('video4linux', 'video81', path)
    alias = self.dev / 'v4l/by-path/platform-aa00000.qcom_vidc-video-index1'
    self.assertFalse(alias.exists())
    enc_path = path.replace('video81', 'video82')
    encoder = self.device('video4linux', 'video82', enc_path, index=1)
    self.reconcile()
    self.assertEqual(alias.resolve(), encoder)
    self.assertEqual(decoder.stat().st_mode & 0o777, 0o660)

  def test_unrelated_or_disappearing_input_does_not_create_touch_alias(self):
    path = '/devices/platform/usb/input/input9/event9'
    node = self.device('input', 'input/event9', path)
    self.event('input', 'input/event9', path)
    node.unlink()
    self.event('input', 'input/event9', path)
    self.assertFalse((self.dev / 'input/by-path/platform-894000.i2c-event').exists())


if __name__ == '__main__':
  unittest.main()
