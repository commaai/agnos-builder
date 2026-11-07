import hashlib
import lzma
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import package_ota
from lz4_images import verify_lz4


class TestFlashArchives(unittest.TestCase):
  def test_independent_frames_preserve_order_hashes_and_short_tail(self):
    contents = bytes(range(256)) * 32 + b'last partial frame'
    with tempfile.TemporaryDirectory() as directory:
      source, target = Path(directory) / 'input.img', Path(directory) / 'frames.zst'
      source.write_bytes(contents)
      sizes, hashes = package_ota.compress_chunks(source, target, chunk_size=4096, workers=2)
      encoded = target.read_bytes()
      self.assertEqual(sum(sizes), len(encoded))
      self.assertEqual(len(sizes), 3)
      offset = 0
      for index, size in enumerate(sizes):
        expected = contents[index * 4096:(index + 1) * 4096]
        decoded = subprocess.check_output(['zstd', '-q', '-dc'], input=encoded[offset:offset + size])
        self.assertEqual(decoded, expected)
        self.assertEqual(hashes[index], hashlib.sha256(expected).hexdigest())
        offset += size
      self.assertEqual(subprocess.check_output(['zstd', '-q', '-dc', str(target)]), contents)

  def test_archive_names_change_with_compressed_bytes(self):
    with tempfile.TemporaryDirectory() as directory:
      temporary = Path(directory) / 'temporary.zst'
      temporary.write_bytes(b'first encoding')
      first = package_ota.name_archive(temporary, 'system')
      temporary.write_bytes(b'second encoding')
      second = package_ota.name_archive(temporary, 'system')
      self.assertNotEqual(first.name, second.name)
      self.assertEqual(first.read_bytes(), b'first encoding')
      self.assertEqual(second.read_bytes(), b'second encoding')

  def test_small_flash_archive_reuses_one_frame_and_keeps_legacy_xz(self):
    contents = b'X' * 4096 + bytes(1024 * 1024) + b'Y' * 123
    with tempfile.TemporaryDirectory() as directory:
      root = Path(directory)
      source = root / 'fixture.img'
      source.write_bytes(contents)
      with patch.object(package_ota, 'OTA_OUTPUT_DIR', root):
        entry = package_ota.Partition('fixture', source, True, True, True, False)
        metadata = package_ota.process_file(entry)
      self.assertEqual(metadata['hash'], hashlib.sha256(contents).hexdigest())
      self.assertEqual(lzma.decompress((root / Path(metadata['url']).name).read_bytes()), contents)
      flash = metadata['flash']
      archive = (root / Path(flash['zstd_url']).name).read_bytes()
      decoded = subprocess.check_output(['zstd', '-q', '-dc'], input=archive)
      self.assertEqual(hashlib.sha256(decoded).hexdigest(), flash['hash'])
      self.assertEqual(flash['chunk_hashes'], [flash['hash']])
      self.assertEqual(flash['zstd_frame_sizes'], [len(archive)])
      self.assertEqual(flash['zstd_chunked_url'], flash['zstd_url'])
      self.assertIn(hashlib.sha256(archive).hexdigest(), flash['zstd_url'])

  def test_large_flash_archive_indexes_each_native_hash_chunk(self):
    contents = b'\x13\x37' * ((package_ota.HASH_CHUNK_SIZE + 4096) // 2)
    with tempfile.TemporaryDirectory() as directory:
      root = Path(directory)
      source = root / 'fixture.img'
      source.write_bytes(contents)
      with patch.object(package_ota, 'OTA_OUTPUT_DIR', root):
        metadata = package_ota.process_file(package_ota.Partition('fixture', source, True, True, True, False))
      flash = metadata['flash']
      self.assertNotEqual(flash['zstd_url'], flash['zstd_chunked_url'])
      archive = (root / Path(flash['zstd_chunked_url']).name).read_bytes()
      self.assertEqual(len(flash['zstd_frame_sizes']), 2)
      self.assertEqual(sum(flash['zstd_frame_sizes']), len(archive))
      self.assertEqual(flash['zstd_chunked_size'], len(archive))
      self.assertIn(hashlib.sha256(archive).hexdigest(), flash['zstd_chunked_url'])
      offset = 0
      for size, digest in zip(flash['zstd_frame_sizes'], flash['chunk_hashes']):
        decoded = subprocess.check_output(['zstd', '-q', '-dc'], input=archive[offset:offset + size])
        self.assertEqual(hashlib.sha256(decoded).hexdigest(), digest)
        offset += size

  def test_lz4_companion_keeps_logical_contents_and_original_archives(self):
    contents = b'A' * 4096 + bytes(16384) + b'B' * 8192
    with tempfile.TemporaryDirectory() as directory:
      root = Path(directory)
      source = root / 'system.img'
      source.write_bytes(contents)
      with patch.object(package_ota, 'OTA_OUTPUT_DIR', root):
        metadata = package_ota.process_file(package_ota.Partition('system', source, True, True, False, True))
      flash, lz4 = metadata['flash'], metadata['flash']['lz4']
      self.assertEqual(metadata['hash'], hashlib.sha256(contents).hexdigest())
      self.assertEqual(lzma.decompress((root / Path(metadata['url']).name).read_bytes()), contents)
      self.assertEqual(flash['stream']['extents'], [[0, 1], [5, 2]])
      self.assertEqual(lz4['stream']['extents'], [[0, 7]])
      self.assertEqual(lz4['hash_raw'], flash['hash_raw'])
      encoded = subprocess.check_output(['zstd', '-q', '-dc', str(root / Path(lz4['zstd_url']).name)])
      self.assertEqual(hashlib.sha256(encoded).hexdigest(), lz4['hash'])
      self.assertEqual(len(encoded), lz4['file_size'])
      self.assertEqual(lz4['file_size'], lz4['stream']['compressed_bytes'])
      coarse, wire = root / 'coarse.img', root / 'wire.lz4'
      package_ota.optimize_image(source, coarse)
      wire.write_bytes(encoded)
      self.assertEqual(verify_lz4(coarse, wire, lz4), lz4['hash'])


if __name__ == '__main__':
  unittest.main()
