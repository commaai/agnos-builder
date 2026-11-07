#!/usr/bin/env python3
"""Replace img2simg -s holes with zero fills, preserving manifest hash/size semantics."""
import struct
import sys


def fill_holes(source, dest):
  header = source.read(28)
  magic, major, minor, file_hdr_sz, chunk_hdr_sz, _, _, chunks, _ = struct.unpack('<I4H4I', header)
  assert (magic, major, minor, file_hdr_sz, chunk_hdr_sz) == (0xED26FF3A, 1, 0, 28, 12)
  dest.write(header)
  for _ in range(chunks):
    header = source.read(12)
    chunk_type, reserved, blocks, size = struct.unpack('<2H2I', header)
    if chunk_type == 0xCAC3:  # DONT_CARE: holes in the raw file read as zero.
      assert size == 12
      dest.write(struct.pack('<2H2I', 0xCAC2, reserved, blocks, 16))
      dest.write(b'\x00' * 4)
    else:
      assert chunk_type in (0xCAC1, 0xCAC2)
      dest.write(header)
      assert size >= 12
      remaining = size - 12
      while remaining:
        data = source.read(min(remaining, 1024 * 1024))
        assert data
        dest.write(data)
        remaining -= len(data)
  assert not source.read(1)


if __name__ == '__main__':
  with open(sys.argv[1], 'rb') as source, open(sys.argv[2], 'wb') as dest:
    fill_holes(source, dest)
