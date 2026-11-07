import copy
import hashlib
import os
import random
import struct
import tempfile
import unittest
from pathlib import Path

from flash_images import BLOCK_SIZE, FILL, MAGIC, RAW
from lz4_images import MAX_DECODED_BYTES, encode_lz4, verify_lz4


def sparse(path, chunks):
  blocks = sum(len(value) // BLOCK_SIZE if kind == RAW else value for kind, value in chunks)
  with path.open('wb') as output:
    output.write(struct.pack('<IHHHHIIII', MAGIC, 1, 0, 28, 12, BLOCK_SIZE, blocks, len(chunks), 0))
    for kind, value in chunks:
      if kind == RAW:
        assert len(value) % BLOCK_SIZE == 0
        output.write(struct.pack('<HHII', kind, 0, len(value) // BLOCK_SIZE, 12 + len(value)))
        output.write(value)
      else:
        output.write(struct.pack('<HHII', kind, 0, value, 16))
        output.write(bytes(4))


def frames(path, metadata):
  data = path.read_bytes()
  result = []
  offset, wire = 0, metadata['stream']['first_frame_bytes']
  while wire:
    header = struct.unpack_from('<IIII', data, offset)
    result.append((offset, wire, header))
    offset += wire
    wire = header[0]
  assert offset == len(data)
  return result


class Lz4ImagesTest(unittest.TestCase):
  def setUp(self):
    self.directory = tempfile.TemporaryDirectory()
    self.addCleanup(self.directory.cleanup)
    self.source = Path(self.directory.name) / 'source.img'
    self.target = Path(self.directory.name) / 'payload.lz4'

  def encode(self, chunks, block_size=MAX_DECODED_BYTES):
    sparse(self.source, chunks)
    return encode_lz4(self.source, self.target, block_size)

  def malformed(self, metadata, mutate, pattern):
    changed = bytearray(self.target.read_bytes())
    mutate(changed)
    self.target.write_bytes(changed)
    with self.assertRaisesRegex(ValueError, pattern):
      verify_lz4(self.source, self.target, metadata)

  def test_compressed_and_raw_frames_with_holes(self):
    raw = random.Random(10).randbytes(BLOCK_SIZE * 2)
    metadata = self.encode([(FILL, 3), (RAW, b'a' * BLOCK_SIZE), (FILL, 5), (RAW, raw), (FILL, 7)])
    self.assertEqual(metadata['stream']['extents'], [[3, 1], [9, 2]])
    self.assertEqual(metadata['stream']['num_partition_sectors'], 18)
    self.assertEqual(metadata['stream']['data_sectors'], 3)
    encoded = frames(self.target, metadata)
    self.assertEqual([header[3] for _, _, header in encoded], [0, 1])
    self.assertEqual(encoded[0][2][0], encoded[1][1])
    self.assertEqual(encoded[1][2][0], 0)
    self.assertEqual(metadata['hash'], hashlib.sha256(self.target.read_bytes()).hexdigest())

  def test_adjacent_source_ranges_form_one_frame(self):
    metadata = self.encode([(RAW, b'a' * BLOCK_SIZE), (RAW, b'b' * BLOCK_SIZE), (RAW, b'c' * BLOCK_SIZE)])
    self.assertEqual(metadata['stream']['extents'], [[0, 3]])
    encoded = frames(self.target, metadata)
    self.assertEqual(len(encoded), 1)
    self.assertEqual(encoded[0][2][2], 3 * BLOCK_SIZE)

  def test_maximum_frame_and_extent_boundaries(self):
    metadata = self.encode([(RAW, b'a' * (MAX_DECODED_BYTES + BLOCK_SIZE)), (FILL, 1), (RAW, b'b' * (BLOCK_SIZE * 2))])
    encoded = frames(self.target, metadata)
    self.assertEqual([header[2] for _, _, header in encoded], [MAX_DECODED_BYTES, BLOCK_SIZE, BLOCK_SIZE * 2])
    self.assertEqual(metadata['stream']['extents'], [[0, 257], [258, 2]])

  def test_large_zero_holes_are_symbolically_verified(self):
    hole_sectors = 96 * 1024 * 1024 * 1024 // BLOCK_SIZE
    metadata = self.encode([(FILL, hole_sectors), (RAW, b'z' * BLOCK_SIZE), (FILL, hole_sectors)])
    self.assertEqual(metadata['stream']['extents'], [[hole_sectors, 1]])
    self.assertEqual(metadata['stream']['num_partition_sectors'], 2 * hole_sectors + 1)
    self.assertLess(self.source.stat().st_size, 5000)
    self.assertEqual(metadata['file_size'], BLOCK_SIZE)

  def test_maximum_incompressible_frame(self):
    metadata = self.encode([(RAW, random.Random(11).randbytes(MAX_DECODED_BYTES))])
    self.assertEqual(frames(self.target, metadata)[0][2], (0, MAX_DECODED_BYTES, MAX_DECODED_BYTES, 1))
    self.assertEqual(metadata['file_size'], MAX_DECODED_BYTES + BLOCK_SIZE)

  def test_small_block_size(self):
    metadata = self.encode([(RAW, b'a' * (BLOCK_SIZE * 3))], BLOCK_SIZE)
    self.assertEqual(len(frames(self.target, metadata)), 3)

  def test_parallel_context_reuse_is_independent_and_deterministic(self):
    contents = b''.join(bytes([i]) * BLOCK_SIZE for i in range(24))
    first = self.encode([(RAW, contents)], BLOCK_SIZE)
    expected = self.target.read_bytes()
    second = encode_lz4(self.source, self.target, BLOCK_SIZE)
    self.assertEqual(first, second)
    self.assertEqual(self.target.read_bytes(), expected)
    self.assertEqual(len(frames(self.target, second)), 24)

  def test_invalid_block_sizes_do_not_touch_source(self):
    sparse(self.source, [(RAW, b'a' * BLOCK_SIZE)])
    before = self.source.read_bytes()
    for size in [0, -1, 4095, MAX_DECODED_BYTES + BLOCK_SIZE, True]:
      with self.subTest(size=size), self.assertRaisesRegex(ValueError, 'invalid block size'):
        encode_lz4(self.source, self.target, size)
    with self.assertRaisesRegex(ValueError, 'must differ'):
      encode_lz4(self.source, self.source)
    os.link(self.source, self.target)
    with self.assertRaisesRegex(ValueError, 'must differ'):
      encode_lz4(self.source, self.target)
    self.assertEqual(self.source.read_bytes(), before)

  def test_empty_payload_rejected(self):
    sparse(self.source, [(FILL, 4)])
    with self.assertRaisesRegex(ValueError, 'extent count'):
      encode_lz4(self.source, self.target)

  def test_zero_hole_and_extent_metadata_rejected(self):
    metadata = self.encode([(FILL, 2), (RAW, b'a' * BLOCK_SIZE), (FILL, 4)])
    for key, value in [('sector_size', 512), ('num_partition_sectors', 8), ('data_sectors', 2), ('extents', [[1, 1]])]:
      altered = copy.deepcopy(metadata)
      altered['stream'][key] = value
      with self.subTest(key=key), self.assertRaisesRegex(ValueError, f'{key} differs'):
        verify_lz4(self.source, self.target, altered)

  def test_raw_content_corruption_rejected(self):
    metadata = self.encode([(RAW, random.Random(12).randbytes(BLOCK_SIZE))])
    self.malformed(metadata, lambda data: data.__setitem__(16, data[16] ^ 1), 'decoded content differs')

  def test_lz4_content_corruption_rejected(self):
    metadata = self.encode([(RAW, b'a' * BLOCK_SIZE)])
    self.malformed(metadata, lambda data: data.__setitem__(16, 0), 'invalid LZ4 block|decoded content differs')

  def test_header_bounds_and_chain_rejected(self):
    mutations = [(0, BLOCK_SIZE, 'frame chain'), (4, 0, 'encoded size'), (4, BLOCK_SIZE + 1, 'encoded size'),
                 (8, 0, 'decoded size'), (8, MAX_DECODED_BYTES + BLOCK_SIZE, 'decoded size'),
                 (12, 2, 'flags'), (12, 1, 'RAW size')]
    for offset, value, pattern in mutations:
      metadata = self.encode([(RAW, b'a' * BLOCK_SIZE)])
      with self.subTest(offset=offset, value=value):
        self.malformed(metadata, lambda data: struct.pack_into('<I', data, offset, value), pattern)

  def test_noncanonical_frame_size_rejected(self):
    metadata = self.encode([(RAW, b'a' * BLOCK_SIZE)])
    with self.target.open('ab') as target:
      target.write(bytes(BLOCK_SIZE))
    metadata['file_size'] *= 2
    metadata['stream']['compressed_bytes'] *= 2
    metadata['stream']['first_frame_bytes'] *= 2
    with self.assertRaisesRegex(ValueError, 'noncanonical wire size'):
      verify_lz4(self.source, self.target, metadata)

  def test_frame_must_not_cross_extent(self):
    metadata = self.encode([(RAW, b'a' * BLOCK_SIZE), (FILL, 1), (RAW, b'a' * BLOCK_SIZE)])
    self.malformed(metadata, lambda data: struct.pack_into('<I', data, 8, BLOCK_SIZE * 2), 'crosses extent')

  def test_truncated_and_extra_file_rejected(self):
    for change in [-1, 1]:
      metadata = self.encode([(RAW, b'a' * BLOCK_SIZE)])
      data = self.target.read_bytes()
      self.target.write_bytes(data[:-1] if change < 0 else data + b'x')
      with self.subTest(change=change), self.assertRaisesRegex(ValueError, 'file size differs'):
        verify_lz4(self.source, self.target, metadata)

  def test_first_frame_invalid(self):
    metadata = self.encode([(RAW, b'a' * BLOCK_SIZE)])
    for wire in [0, 1, MAX_DECODED_BYTES + 2 * BLOCK_SIZE, True]:
      metadata['stream']['first_frame_bytes'] = wire
      with self.subTest(wire=wire), self.assertRaisesRegex(ValueError, 'invalid frame size'):
        verify_lz4(self.source, self.target, metadata)

  def test_padding_is_ignored_by_decoder_but_covered_by_hash(self):
    metadata = self.encode([(RAW, b'a' * BLOCK_SIZE)])
    data = bytearray(self.target.read_bytes())
    data[-1] = 123
    self.target.write_bytes(data)
    with self.assertRaisesRegex(ValueError, 'SHA256 mismatch'):
      verify_lz4(self.source, self.target, metadata)
    del metadata['hash']
    self.assertEqual(verify_lz4(self.source, self.target, metadata), hashlib.sha256(data).hexdigest())


if __name__ == '__main__':
  unittest.main()
