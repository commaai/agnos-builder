import random
import struct
import tempfile
import unittest
from pathlib import Path

from flash_images import BLOCK_SIZE, FILL, RAW
from sparse_equivalence import BUFFER_BYTES, verify_sparse_equal
from test_lz4_images import sparse


class SparseEquivalenceTest(unittest.TestCase):
  def setUp(self):
    directory = tempfile.TemporaryDirectory()
    self.addCleanup(directory.cleanup)
    self.left, self.right = [Path(directory.name) / name for name in ('left.img', 'right.img')]

  def compare(self, left, right):
    sparse(self.left, left)
    sparse(self.right, right)
    return verify_sparse_equal(self.left, self.right)

  def test_adjacent_raw_headers_and_uneven_chunks(self):
    raw = random.Random(2).randbytes(2 * BUFFER_BYTES + 3 * BLOCK_SIZE)
    left = [(RAW, raw[:BLOCK_SIZE]), (RAW, raw[BLOCK_SIZE:])]
    right = [(RAW, raw[:BUFFER_BYTES]), (RAW, raw[BUFFER_BYTES:-BLOCK_SIZE]), (RAW, raw[-BLOCK_SIZE:])]
    self.assertTrue(self.compare(left, right))
    self.assertTrue(verify_sparse_equal(self.right, self.left))

  def test_bridged_zero_holes_and_leading_trailing_zeros(self):
    a, b = b'a' * BLOCK_SIZE, b'b' * BLOCK_SIZE
    left = [(FILL, 3), (RAW, a), (FILL, 5), (RAW, b), (FILL, 7)]
    right = [(RAW, bytes(BLOCK_SIZE * 3) + a + bytes(BLOCK_SIZE * 5) + b + bytes(BLOCK_SIZE * 7))]
    self.assertTrue(self.compare(left, right))
    self.assertTrue(verify_sparse_equal(self.right, self.left))

  def test_large_matching_holes_and_zero_only_images(self):
    huge = 96 * 1024 * 1024 * 1024 // BLOCK_SIZE
    self.assertTrue(self.compare([(FILL, huge), (FILL, huge)], [(FILL, huge * 2)]))
    self.assertTrue(self.compare([(FILL, huge), (RAW, b'a' * BLOCK_SIZE), (FILL, huge)],
                                 [(FILL, huge), (RAW, b'a' * BLOCK_SIZE), (FILL, huge)]))

  def test_bridged_gap_corruption_rejected(self):
    left = [(RAW, b'a' * BLOCK_SIZE), (FILL, 1), (RAW, b'b' * BLOCK_SIZE)]
    for index in [0, BLOCK_SIZE, BLOCK_SIZE * 2, BLOCK_SIZE * 3 - 1]:
      raw = bytearray(b'a' * BLOCK_SIZE + bytes(BLOCK_SIZE) + b'b' * BLOCK_SIZE)
      raw[index] ^= 1
      with self.subTest(index=index), self.assertRaisesRegex(ValueError, 'expanded contents differ'):
        self.compare(left, [(RAW, raw)])

  def test_raw_corruption_after_buffer_boundary_rejected(self):
    raw = b'a' * (BUFFER_BYTES * 2 + BLOCK_SIZE)
    bad = bytearray(raw)
    bad[BUFFER_BYTES + 3] = 12
    with self.assertRaisesRegex(ValueError, f'logical byte {BUFFER_BYTES}'):
      self.compare([(RAW, raw)], [(RAW, bad)])

  def test_different_logical_sizes_rejected(self):
    with self.assertRaisesRegex(ValueError, 'logical sizes differ'):
      self.compare([(FILL, 5)], [(FILL, 6)])

  def test_relocated_payload_rejected(self):
    with self.assertRaisesRegex(ValueError, 'expanded contents differ'):
      self.compare([(FILL, 1), (RAW, b'a' * BLOCK_SIZE), (FILL, 2)], [(FILL, 2), (RAW, b'a' * BLOCK_SIZE), (FILL, 1)])

  def test_undefined_nonzero_or_truncated_sources_rejected(self):
    sparse(self.left, [(FILL, 1)])
    for kind, fill in [(FILL, 1), (0xCAC3, 0)]:
      data = bytearray(self.left.read_bytes())
      struct.pack_into('<H', data, 28, kind)
      struct.pack_into('<I', data, 40, fill)
      self.right.write_bytes(data)
      with self.subTest(kind=kind, fill=fill), self.assertRaises(AssertionError):
        verify_sparse_equal(self.left, self.right)
    sparse(self.right, [(RAW, b'a' * BLOCK_SIZE)])
    self.right.write_bytes(self.right.read_bytes()[:-1])
    with self.assertRaises(AssertionError):
      verify_sparse_equal(self.left, self.right)


if __name__ == '__main__':
  unittest.main()
