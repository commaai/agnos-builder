import struct
import tempfile
import unittest
from pathlib import Path

from flash_images import BLOCK_SIZE, FILL, MAGIC, RAW, optimize_image, stream_index


def expand(path):
  data = path.read_bytes()
  _, _, _, _, _, block_size, blocks, count, _ = struct.unpack_from('<IHHHHIIII', data)
  output, offset, programs = bytearray(), 28, 0
  for _ in range(count):
    kind, _, chunk_blocks, size = struct.unpack_from('<HHII', data, offset)
    chunk = data[offset + 12:offset + size]
    output.extend(chunk if kind == RAW else chunk * (chunk_blocks * block_size // 4))
    programs += kind == RAW
    offset += size
  assert offset == len(data) and len(output) == blocks * block_size
  return output, programs


class TestFlashImages(unittest.TestCase):
  def check_image(self, data, gap=256 * 1024):
    with tempfile.TemporaryDirectory() as directory:
      source, target = Path(directory) / 'input.img', Path(directory) / 'output.img'
      source.write_bytes(data)
      optimize_image(source, target, gap)
      return expand(target)

  def test_raw_images_preserve_padding_and_zero_sectors(self):
    for data in (bytes(8192), b'X' * 4096 + bytes(1024 * 1024) + b'Y' * 123):
      expanded, _ = self.check_image(data)
      self.assertEqual(expanded, data + bytes((-len(data)) % BLOCK_SIZE))

  def test_small_zero_gaps_reduce_program_commands(self):
    data = b'X' * BLOCK_SIZE + bytes(BLOCK_SIZE) + b'Y' * BLOCK_SIZE
    self.assertEqual(self.check_image(data, 0), (data, 2))
    self.assertEqual(self.check_image(data, BLOCK_SIZE), (data, 1))

  def test_sparse_nonzero_fills_preserved(self):
    header = struct.pack('<IHHHHIIII', MAGIC, 1, 0, 28, 12, BLOCK_SIZE, 3, 3, 0)
    data = header + b''.join(struct.pack('<HHII', FILL, 0, 1, 16) + fill for fill in (b'ABCD', bytes(4), b'WXYZ'))
    expected = b'ABCD' * 1024 + bytes(BLOCK_SIZE) + b'WXYZ' * 1024
    self.assertEqual(self.check_image(data), (expected, 1))

  def test_undefined_sectors_are_not_replaced_with_zeros(self):
    data = struct.pack('<IHHHHIIII', MAGIC, 1, 0, 28, 12, BLOCK_SIZE, 1, 1, 0)
    data += struct.pack('<HHII', 0xCAC3, 0, 1, 12)
    with self.assertRaises(AssertionError):
      self.check_image(data)

  def test_truncated_sparse_payload_rejected(self):
    data = struct.pack('<IHHHHIIII', MAGIC, 1, 0, 28, 12, BLOCK_SIZE, 1, 1, 0)
    data += struct.pack('<HHII', RAW, 0, 1, 12 + BLOCK_SIZE) + b'X' * 100
    with self.assertRaises(AssertionError):
      self.check_image(data)

  def test_stream_index_matches_encoded_payload_and_target_sectors(self):
    with tempfile.TemporaryDirectory() as directory:
      source, target = Path(directory) / 'input.img', Path(directory) / 'output.img'
      source.write_bytes(bytes(BLOCK_SIZE) + b'X' * BLOCK_SIZE + bytes(BLOCK_SIZE) + b'Y' * BLOCK_SIZE)
      optimize_image(source, target, 0)
      index = stream_index(target)
      self.assertEqual(index['extents'], [[1, 1], [3, 1]])
      self.assertEqual(index['num_partition_sectors'], 4)
      self.assertEqual(index['data_sectors'], 2)
      encoded = target.read_bytes()
      payload = b''.join(encoded[start:start + size] for start, size in index['source_ranges'])
      self.assertEqual(payload, b'X' * BLOCK_SIZE + b'Y' * BLOCK_SIZE)


if __name__ == '__main__':
  unittest.main()
