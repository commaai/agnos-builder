import ctypes
from pathlib import Path

from flash_images import stream_index

BUFFER_BYTES = 512 * 1024


def check(condition, message):
  if not condition:
    raise ValueError(f'Sparse equivalence: {message}')


def segments(index):
  """Yield (source offset or None for zeros, length) over every logical byte."""
  sector_size = index['sector_size']
  position = range_index = 0
  for start, sectors in index['extents']:
    check(start >= position and sectors > 0, 'invalid source extents')
    if start > position:
      yield None, (start - position) * sector_size
    remaining = sectors * sector_size
    while remaining:
      check(range_index < len(index['source_ranges']), 'missing RAW source range')
      offset, length = index['source_ranges'][range_index]
      check(0 < length <= remaining, 'RAW source range crosses an extent')
      yield offset, length
      remaining -= length
      range_index += 1
    position = start + sectors
  check(range_index == len(index['source_ranges']), 'unused RAW source range')
  check(position <= index['num_partition_sectors'], 'source exceeds logical size')
  if position < index['num_partition_sectors']:
    yield None, (index['num_partition_sectors'] - position) * sector_size


def verify_sparse_equal(first, second):
  """Prove fully defined sparse images expand identically using 1 MiB of buffers.

  Matching zero-FILL holes are skipped symbolically. RAW bytes are compared
  directly, including any zero sectors included in coalesced RAW extents.
  """
  first, second = Path(first), Path(second)
  indexes = [stream_index(first), stream_index(second)]
  check(indexes[0]['sector_size'] == indexes[1]['sector_size'], 'sector sizes differ')
  check(indexes[0]['num_partition_sectors'] == indexes[1]['num_partition_sectors'], 'logical sizes differ')
  remaining_total = indexes[0]['num_partition_sectors'] * indexes[0]['sector_size']
  sources = [iter(segments(index)) for index in indexes]
  current = [next(source, None) for source in sources]
  buffers = [ctypes.create_string_buffer(BUFFER_BYTES) for _ in range(2)]
  views = [memoryview(buffer).cast('B') for buffer in buffers]
  libc = ctypes.CDLL(None)
  libc.memcmp.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]
  libc.memcmp.restype = ctypes.c_int
  logical_offset = 0
  with first.open('rb') as left, second.open('rb') as right:
    files = [left, right]
    while remaining_total:
      check(all(segment is not None for segment in current), 'truncated logical image')
      overlap = min(current[0][1], current[1][1])
      check(0 < overlap <= remaining_total, 'invalid segment length')
      if current[0][0] is not None or current[1][0] is not None:
        compared = 0
        while compared < overlap:
          count = min(BUFFER_BYTES, overlap - compared)
          for i in range(2):
            offset = current[i][0]
            if offset is None:
              ctypes.memset(buffers[i], 0, count)
            else:
              files[i].seek(offset + compared)
              check(files[i].readinto(views[i][:count]) == count, 'truncated RAW source')
          check(libc.memcmp(buffers[0], buffers[1], count) == 0,
                f'expanded contents differ at logical byte {logical_offset + compared}')
          compared += count
      remaining_total -= overlap
      logical_offset += overlap
      for i in range(2):
        offset, length = current[i]
        current[i] = next(sources[i], None) if length == overlap else (None if offset is None else offset + overlap, length - overlap)
    check(current == [None, None], 'trailing logical contents')
  return True
