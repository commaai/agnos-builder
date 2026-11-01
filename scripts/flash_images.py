import mmap
import struct

BLOCK_SIZE = 4096
RAW = 0xCAC1
FILL = 0xCAC2
MAGIC = 0xED26FF3A


def stream_index(source):
  """Index the RAW payload of a fully defined optimized sparse image."""
  ranges, extents = [], []
  with open(source, 'rb') as src:
    magic, major, minor, file_header, chunk_header, block_size, blocks, count, _ = struct.unpack('<IHHHHIIII', src.read(28))
    assert (magic, major, minor, file_header, chunk_header, block_size) == (MAGIC, 1, 0, 28, 12, BLOCK_SIZE)
    offset = 0
    for _ in range(count):
      kind, _, chunk_blocks, total = struct.unpack('<HHII', src.read(12))
      assert chunk_blocks > 0
      if kind == RAW:
        assert total == 12 + chunk_blocks * BLOCK_SIZE
        ranges.append([src.tell(), chunk_blocks * BLOCK_SIZE])
        if extents and extents[-1][0] + extents[-1][1] == offset:
          extents[-1][1] += chunk_blocks
        else:
          extents.append([offset, chunk_blocks])
        src.seek(total - 12, 1)
      else:
        assert kind == FILL and total == 16 and src.read(4) == bytes(4)
      offset += chunk_blocks
    assert offset == blocks and src.tell() == source.stat().st_size
  return {
    "sector_size": BLOCK_SIZE,
    "num_partition_sectors": blocks,
    "data_sectors": sum(length for _, length in extents),
    "extents": extents,
    "source_ranges": ranges,
  }


def optimize_image(source, target, max_gap=256 * 1024):
  """Keep exact sector contents while reducing zero writes and program commands."""
  segments, ranges = [], []

  def add_range(start, end):
    if ranges and start - ranges[-1][1] <= max_gap:
      ranges[-1][1] = end
    else:
      ranges.append([start, end])

  with open(source, 'rb') as src:
    header = src.read(28)
    sparse = struct.unpack_from('<I', header)[0] == MAGIC
    if sparse:
      _, major, minor, file_header, chunk_header, block_size, blocks, count, _ = struct.unpack('<IHHHHIIII', header)
      assert (major, minor, file_header, chunk_header, block_size) == (1, 0, 28, 12, BLOCK_SIZE)
      size = 0
      for _ in range(count):
        kind, _, chunk_blocks, total = struct.unpack('<HHII', src.read(12))
        assert kind in (RAW, FILL), 'Only fully defined sparse images can be coalesced'
        length, offset = chunk_blocks * BLOCK_SIZE, src.tell()
        value = src.read(4) if kind == FILL else None
        assert total == 12 + (length if kind == RAW else 4)
        segments.append((size, size + length, kind, offset, value))
        if kind == RAW or value != bytes(4):
          add_range(size, size + length)
        size += length
        src.seek(offset + total - 12)
      assert size == blocks * BLOCK_SIZE
      assert not src.read(1)
    else:
      with mmap.mmap(src.fileno(), 0, access=mmap.ACCESS_READ) as data:
        size = (len(data) + BLOCK_SIZE - 1) // BLOCK_SIZE * BLOCK_SIZE
        zero = bytes(BLOCK_SIZE)
        for offset in range(0, len(data), BLOCK_SIZE):
          if data[offset:offset + BLOCK_SIZE].ljust(BLOCK_SIZE, b'\0') != zero:
            add_range(offset, offset + BLOCK_SIZE)
      segments.append((0, size, RAW, 0, None))

    chunks, offset = [], 0
    for start, end in ranges:
      if start > offset:
        chunks.append((offset, start, FILL))
      for raw_start in range(start, end, (0xffffffff - 12) // BLOCK_SIZE * BLOCK_SIZE):
        chunks.append((raw_start, min(end, raw_start + (0xffffffff - 12) // BLOCK_SIZE * BLOCK_SIZE), RAW))
      offset = end
    if offset < size:
      chunks.append((offset, size, FILL))

    segment = 0
    with open(target, 'wb') as dst:
      dst.write(struct.pack('<IHHHHIIII', MAGIC, 1, 0, 28, 12, BLOCK_SIZE, size // BLOCK_SIZE, len(chunks), 0))
      for start, end, kind in chunks:
        dst.write(struct.pack('<HHII', kind, 0, (end - start) // BLOCK_SIZE, 16 if kind == FILL else 12 + end - start))
        if kind == FILL:
          dst.write(bytes(4))
          continue
        offset = start
        while offset < end:
          while segments[segment][1] <= offset:
            segment += 1
          seg_start, seg_end, seg_kind, file_offset, value = segments[segment]
          count = min(end - offset, seg_end - offset, 1024 * 1024)
          if seg_kind == RAW:
            src.seek(file_offset + offset - seg_start)
            data = src.read(count)
            if sparse:
              assert len(data) == count
            else:
              data = data.ljust(count, b'\0')
          else:
            data = value * (count // 4)
          dst.write(data)
          offset += count
