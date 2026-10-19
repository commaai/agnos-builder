import argparse
from contextlib import ExitStack
import importlib.machinery
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import uuid
import zlib


PATH = Path(__file__).resolve().parents[1] / 'userspace/abctl.py'
SPEC = importlib.util.spec_from_loader('abctl', importlib.machinery.SourceFileLoader('abctl', str(PATH)))
abctl = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(abctl)


def make_disk(path, names, sector=4096, entry_size=128, count=128, nondefault=False):
  last = 255
  entries = bytearray(count * entry_size)
  for i, name in enumerate(names):
    offset = i * entry_size
    entries[offset:offset + 16] = uuid.UUID(abctl.BASIC).bytes_le
    entries[offset + 16:offset + 32] = uuid.UUID(int=i + 1).bytes_le
    struct.pack_into('<QQQ', entries, offset + 32, 64 + i * 2, 65 + i * 2, 0x1122334455667788)
    encoded = name.encode('utf-16le')
    entries[offset + 56:offset + 56 + len(encoded)] = encoded
    if entry_size > 128:
      entries[offset + 128:offset + entry_size] = bytes([0xA5]) * (entry_size - 128)
  disk = bytearray(b'\xCC' * ((last + 1) * sector))
  blocks = (len(entries) + sector - 1) // sector
  starts = (3 if nondefault else 2, last - blocks - (1 if nondefault else 0))
  for lba, start in zip((1, last), starts, strict=True):
    header = bytearray(sector)
    struct.pack_into('<8sIIIIQQQQ16sQIII', header, 0, b'EFI PART', 0x10000, 92, 0, 0,
                     lba, last if lba == 1 else 1, 64, 191, bytes(range(16)), start, count, entry_size, zlib.crc32(entries))
    struct.pack_into('<I', header, 16, zlib.crc32(header[:92]))
    disk[lba * sector:(lba + 1) * sector] = header
    disk[start * sector:start * sector + len(entries)] = entries
  path.write_bytes(disk)
  return starts


def tables(path, sector):
  data = path.read_bytes()
  result = []
  for lba in (1, len(data) // sector - 1):
    header = bytearray(data[lba * sector:(lba + 1) * sector])
    size, crc = struct.unpack_from('<II', header, 12)
    struct.pack_into('<I', header, 16, 0)
    assert zlib.crc32(header[:size]) == crc
    start, count, entry_size, crc = struct.unpack_from('<QIII', header, 72)
    entries = data[start * sector:start * sector + count * entry_size]
    assert zlib.crc32(entries) == crc
    result.append(entries)
  assert result[0] == result[1]
  return result[0]


class TestGPT(unittest.TestCase):
  def test_geometry_and_unchanged_bytes(self):
    for sector in (512, 4096):
      for entry_size in (128, 256):
        for nondefault in (False, True):
          with self.subTest(sector=sector, entry_size=entry_size, nondefault=nondefault), tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'disk'
            # Keep the 512-byte fixture's arrays outside its usable LBAs.
            count = 16
            starts = make_disk(path, ['boot_a', 'boot_b', 'untouched'], sector, entry_size, count, nondefault)
            before = path.read_bytes()
            with ExitStack() as stack:
              disk = abctl.GPT(stack, path, True, sector)
              disk.update('boot_a', abctl.UNBOOTABLE, abctl.SUCCESS, abctl.TYPES['boot'][0])
              disk.write()
            entries = tables(path, sector)
            self.assertEqual(entries[entry_size:], before[starts[0] * sector + entry_size:starts[0] * sector + count * entry_size])
            after = path.read_bytes()
            allowed = set()
            for start in starts:
              allowed.update(range(start * sector, start * sector + 16))
              allowed.update(range(start * sector + 48, start * sector + 56))
            for lba in (1, 255):
              allowed.update(range(lba * sector + 16, lba * sector + 20))
              allowed.update(range(lba * sector + 88, lba * sector + 92))
            self.assertTrue(all(a == b or i in allowed for i, (a, b) in enumerate(zip(before, after, strict=True))))

  def test_corruption_and_recovery(self):
    for lba in (1, 255):
      for damage in ('header', 'entries'):
        with self.subTest(lba=lba, damage=damage), tempfile.TemporaryDirectory() as tmp:
          path = Path(tmp) / 'disk'
          starts = make_disk(path, ['boot_a', 'boot_b'], nondefault=True)
          data = bytearray(path.read_bytes())
          offset = lba * 4096 if damage == 'header' else starts[lba == 255] * 4096
          data[offset] ^= 1
          path.write_bytes(data)
          with ExitStack() as stack:
            disk = abctl.GPT(stack, path, True, 4096)
            self.assertEqual(path.read_bytes(), data, 'reading fallback must not write')
            disk.update('boot_a', set_bits=abctl.SUCCESS)
            disk.write()
          entries = tables(path, 4096)
          self.assertTrue(struct.unpack_from('<Q', entries, 48)[0] & abctl.SUCCESS)

  def test_no_valid_copy(self):
    with tempfile.TemporaryDirectory() as tmp, ExitStack() as stack:
      path = Path(tmp) / 'disk'
      make_disk(path, ['boot_a', 'boot_b'])
      data = bytearray(path.read_bytes())
      data[4096] = data[255 * 4096] = 0
      path.write_bytes(data)
      with self.assertRaisesRegex(ValueError, 'neither GPT'):
        abctl.GPT(stack, path, True, 4096)
      self.assertEqual(path.read_bytes(), data)

  def test_bootloader_can_update_only_primary(self):
    # ABL clears the old XBL slot's ACTIVE bit in the primary GPT only.
    with tempfile.TemporaryDirectory() as tmp, ExitStack() as stack:
      path = Path(tmp) / 'disk'
      make_disk(path, ['xbl_a', 'xbl_b'])
      disk = abctl.GPT(stack, path, True, 4096)
      disk.update('xbl_a', abctl.ACTIVE)
      disk.write_copy(1)
      primary = bytes(disk.entries)
      stack.close()
      with ExitStack() as reopened:
        disk = abctl.GPT(reopened, path, True, 4096)
        self.assertEqual(disk.valid_copies, {1, disk.last})
        self.assertEqual(disk.entries, primary)
        disk.write()
      self.assertEqual(tables(path, 4096), primary)

  def test_interrupted_writes(self):
    # Simulate failure before every array/header write and flush. The other GPT
    # copy must remain valid and readable at every interruption point.
    for failure in range(24):
      with self.subTest(failure=failure % 8, damaged_copy=failure // 8), tempfile.TemporaryDirectory() as tmp, ExitStack() as stack:
        path = Path(tmp) / 'disk'
        make_disk(path, ['boot_a', 'boot_b'])
        if failure // 8:
          data = bytearray(path.read_bytes())
          data[(1 if failure // 8 == 1 else 255) * 4096] = 0
          path.write_bytes(data)
        disk = abctl.GPT(stack, path, True, 4096)
        disk.update('boot_a', set_bits=abctl.SUCCESS)
        real_write, real_sync = abctl.os.pwrite, abctl.os.fsync
        calls = 0

        def interrupt(func):
          def run(*args):
            nonlocal calls
            calls += 1
            if calls == failure % 8 + 1:
              raise OSError('power loss')
            return func(*args)
          return run

        with patch.object(abctl.os, 'pwrite', interrupt(real_write)), patch.object(abctl.os, 'fsync', interrupt(real_sync)):
          with self.assertRaises(OSError):
            disk.write()
        # Release the original lock before opening another descriptor.
        stack.close()
        with ExitStack() as recovery:
          self.assertIn('boot_a', abctl.GPT(recovery, path, sector_size=4096).partitions)

  def test_invalid_geometry(self):
    for start, count, size in ((64, 128, 128), (2, 0xFFFFFFFF, 128), (2, 128, 127)):
      with self.subTest(start=start, count=count, size=size), tempfile.TemporaryDirectory() as tmp, ExitStack() as stack:
        path = Path(tmp) / 'disk'
        make_disk(path, ['boot_a'])
        data = bytearray(path.read_bytes())
        for lba in (1, 255):
          offset = lba * 4096
          struct.pack_into('<QII', data, offset + 72, start, count, size)
          struct.pack_into('<I', data, offset + 16, 0)
          struct.pack_into('<I', data, offset + 16, zlib.crc32(data[offset:offset + 92]))
        path.write_bytes(data)
        with self.assertRaises(ValueError):
          abctl.GPT(stack, path, True, 4096)
        self.assertEqual(path.read_bytes(), data)

  def test_ufs_does_not_depend_on_partition_links(self):
    # Slot writes trigger udev reprobes; by-partlabel/xbl_a may be absent.
    with ExitStack() as stack, patch.object(abctl.Path, 'iterdir', return_value=iter([Path('sg4')])), \
         patch.object(abctl.Path, 'resolve', side_effect=FileNotFoundError), \
         patch('builtins.open', unittest.mock.mock_open()) as opened:
      abctl.boot_lun(stack)
      opened.assert_called_once_with('/dev/sg4', 'r+b', buffering=0)


class TestSlots(unittest.TestCase):
  def setUp(self):
    self.tmp = tempfile.TemporaryDirectory()
    self.addCleanup(self.tmp.cleanup)
    self.paths = [Path(self.tmp.name) / letter for letter in 'abce']
    names = [['system_a', 'system_b'], ['xbl_a', 'xbl_config_a'], ['xbl_b', 'xbl_config_b'],
             [f'{name}_{slot}' for name in abctl.TYPES if name not in ('system', 'xbl', 'xbl_config') for slot in 'ab']]
    for path, parts in zip(self.paths, names, strict=True):
      make_disk(path, parts)
    self.lun = 1
    real_gpt = abctl.GPT

    def disk(stack, path, writable=False):
      return real_gpt(stack, self.paths[3] if path == '/dev/sde' else path, writable, 4096)

    def lun_query(f, value=None):
      if value is not None:
        self.lun = value
      return self.lun

    for mock in (patch.object(abctl, 'GPT', disk), patch.object(abctl, 'DISKS', self.paths[1:]),
                 patch.object(abctl, 'boot_lun', return_value=None), patch.object(abctl, 'query_lun', side_effect=lun_query)):
      mock.start()
      self.addCleanup(mock.stop)

  def attributes(self, name):
    for path in self.paths:
      entries = tables(path, 4096)
      for offset in range(0, len(entries), 128):
        if entries[offset + 56:offset + 128].decode('utf-16le').rstrip('\0') == name:
          return struct.unpack_from('<Q', entries, offset + 48)[0], uuid.UUID(bytes_le=entries[offset:offset + 16])
    raise AssertionError(name)

  def test_switch_both_directions(self):
    for slot in 'bab':
      abctl.change_slot('set_active', slot)
      self.assertEqual(self.lun, 1 if slot == 'a' else 2)
      for name, guids in abctl.TYPES.items():
        flags, guid = self.attributes(f'{name}_{slot}')
        self.assertEqual(flags & (abctl.PRIORITY | abctl.ACTIVE | abctl.RETRIES), abctl.PRIORITY | abctl.ACTIVE | abctl.RETRIES)
        self.assertFalse(flags & (abctl.SUCCESS | abctl.UNBOOTABLE))
        other_flags, other_guid = self.attributes(f'{name}_{"b" if slot == "a" else "a"}')
        self.assertEqual(other_flags & abctl.PRIORITY, 1 << 48)
        if guids:
          self.assertEqual(str(guid), guids[0])
          self.assertEqual(str(other_guid), guids[1])

  def test_success_and_unbootable(self):
    abctl.change_slot('set_success', 'a')
    self.assertTrue(self.attributes('boot_a')[0] & abctl.SUCCESS)
    abctl.change_slot('set_unbootable', 'a')
    flags = self.attributes('boot_a')[0]
    self.assertTrue(flags & abctl.UNBOOTABLE)
    self.assertFalse(flags & (abctl.SUCCESS | abctl.RETRIES | abctl.ACTIVE | abctl.PRIORITY))

  def test_missing_partition_does_not_write(self):
    make_disk(self.paths[1], ['xbl_a'])  # Missing xbl_config_a counterpart.
    before = [p.read_bytes() for p in self.paths]
    with self.assertRaisesRegex(ValueError, 'incomplete partition pair'):
      abctl.change_slot('set_active', 'a')
    self.assertEqual([p.read_bytes() for p in self.paths], before)
    self.assertEqual(self.lun, 1)

  def test_ufs_preflight_failure_does_not_write(self):
    before = [p.read_bytes() for p in self.paths]
    with patch.object(abctl, 'query_lun', side_effect=OSError('ioctl failed')), self.assertRaises(OSError):
      abctl.change_slot('set_active', 'b')
    self.assertEqual([p.read_bytes() for p in self.paths], before)

  def test_boot_slot(self):
    for slot in 'ab':
      with patch.object(abctl.Path, 'read_text', return_value=f'console=ttyMSM0 androidboot.slot_suffix=_{slot}\n'):
        self.assertEqual(abctl.boot_slot(), slot)
    with patch.object(abctl.Path, 'read_text', return_value='root=/dev/sda6'), self.assertRaises(ValueError):
      abctl.boot_slot()


  def test_cli_rejects_invalid_slot(self):
    for option in ('--set_active', '--set_unbootable'):
      with patch.object(abctl.sys, 'argv', ['abctl', option, '2']), patch.object(argparse.ArgumentParser, 'error', side_effect=ValueError):
        with self.assertRaises(ValueError):
          abctl.main()


if __name__ == '__main__':
  unittest.main()
