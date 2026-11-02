import ctypes
import hashlib
import struct
from pathlib import Path

from flash_images import stream_index

SECTOR_SIZE = 4096
HEADER_SIZE = 16
MAX_DECODED_BYTES = 1024 * 1024
MAX_WIRE_BYTES = MAX_DECODED_BYTES + SECTOR_SIZE


def check(condition, message):
  if not condition:
    raise ValueError(f"Native LZ4: {message}")


def codec():
  lib = ctypes.CDLL('liblz4.so.1')
  lib.LZ4_compressBound.argtypes = [ctypes.c_int]
  lib.LZ4_compressBound.restype = ctypes.c_int
  lib.LZ4_compress_default.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
  lib.LZ4_compress_default.restype = ctypes.c_int
  lib.LZ4_decompress_safe.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
  lib.LZ4_decompress_safe.restype = ctypes.c_int
  return lib


def source_index(source):
  index = stream_index(source)
  check(index['sector_size'] == SECTOR_SIZE, 'unsupported sector size')
  check(0 < len(index['extents']) <= 4096, 'unsupported extent count')
  check(index['data_sectors'] > 0, 'empty payload')
  check(sum(size for _, size in index['source_ranges']) == index['data_sectors'] * SECTOR_SIZE, 'source payload size differs')
  return index


class PayloadReader:
  def __init__(self, source, ranges):
    self.source = source
    self.ranges = ranges
    self.index = 0
    self.offset = 0

  def readinto(self, destination):
    position = 0
    while position < len(destination):
      check(self.index < len(self.ranges), 'source ranges exhausted')
      start, size = self.ranges[self.index]
      count = min(size - self.offset, len(destination) - position)
      self.source.seek(start + self.offset)
      got = self.source.readinto(destination[position:position + count])
      check(got == count, 'truncated source payload')
      position += count
      self.offset += count
      if self.offset == size:
        self.index += 1
        self.offset = 0

  def finish(self):
    check(self.index == len(self.ranges) and self.offset == 0, 'unused source payload')


def write_frames(source, target, index, block_size):
  lib = codec()
  raw_buffer = ctypes.create_string_buffer(block_size)
  compressed_buffer = ctypes.create_string_buffer(lib.LZ4_compressBound(block_size))
  raw = memoryview(raw_buffer).cast('B')
  compressed = memoryview(compressed_buffer).cast('B')
  previous = None
  first = wire_bytes = 0
  with source.open('rb') as src, target.open('wb') as dst:
    payload = PayloadReader(src, index['source_ranges'])
    for _, sectors in index['extents']:
      remaining = sectors * SECTOR_SIZE
      while remaining:
        count = min(block_size, remaining)
        payload.readinto(raw[:count])
        encoded = lib.LZ4_compress_default(raw_buffer, compressed_buffer, count, len(compressed_buffer))
        check(0 < encoded <= len(compressed_buffer), 'compression failed')
        flags = int(encoded >= count)
        encoded = count if flags else encoded
        wire = (HEADER_SIZE + encoded + SECTOR_SIZE - 1) // SECTOR_SIZE * SECTOR_SIZE
        if previous is None:
          first = wire
        else:
          dst.seek(previous)
          dst.write(struct.pack('<I', wire))
          dst.seek(wire_bytes)
        previous = wire_bytes
        dst.write(struct.pack('<IIII', 0, encoded, count, flags))
        dst.write(raw[:encoded] if flags else compressed[:encoded])
        dst.write(bytes(wire - HEADER_SIZE - encoded))
        wire_bytes += wire
        remaining -= count
    payload.finish()
  return {
    'sector_size': SECTOR_SIZE,
    'num_partition_sectors': index['num_partition_sectors'],
    'data_sectors': index['data_sectors'],
    'extents': index['extents'],
    'compressed_bytes': wire_bytes,
    'first_frame_bytes': first,
  }


def verify_lz4(source, target, metadata):
  """Compare decoded bytes and the complete zero-hole layout with the sparse source."""
  source, target = Path(source), Path(target)
  index = source_index(source)
  stream = metadata['stream']
  for key in ['sector_size', 'num_partition_sectors', 'data_sectors', 'extents']:
    check(stream[key] == index[key], f'{key} differs from source, including its zero holes')
  compressed_bytes = stream['compressed_bytes']
  check(type(compressed_bytes) is int and compressed_bytes > 0 and compressed_bytes % SECTOR_SIZE == 0, 'invalid compressed size')
  check(compressed_bytes <= 2 * index['data_sectors'] * SECTOR_SIZE, 'compressed size exceeds payload bound')
  check(target.stat().st_size == metadata['file_size'] == compressed_bytes, 'encoded file size differs')
  lib = codec()
  libc = ctypes.CDLL(None)
  libc.memcmp.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]
  libc.memcmp.restype = ctypes.c_int
  wire_buffer = ctypes.create_string_buffer(MAX_WIRE_BYTES)
  decoded_buffer = ctypes.create_string_buffer(MAX_DECODED_BYTES)
  wire_view = memoryview(wire_buffer).cast('B')
  digest = hashlib.sha256()
  wire = stream['first_frame_bytes']
  consumed = decoded_total = extent_index = 0
  extent_remaining = index['extents'][0][1] * SECTOR_SIZE
  with source.open('rb') as src, target.open('rb') as encoded_file:
    payload = PayloadReader(src, index['source_ranges'])
    while True:
      check(type(wire) is int and SECTOR_SIZE <= wire <= MAX_WIRE_BYTES and wire % SECTOR_SIZE == 0, 'invalid frame size')
      check(wire <= compressed_bytes - consumed, 'frame exceeds compressed size')
      check(encoded_file.readinto(wire_view[:wire]) == wire, 'truncated frame')
      digest.update(wire_view[:wire])
      next_wire, encoded, decoded, flags = struct.unpack_from('<IIII', wire_view)
      check(0 < decoded <= MAX_DECODED_BYTES and decoded % SECTOR_SIZE == 0, 'invalid decoded size')
      check(0 < encoded <= decoded, 'invalid encoded size')
      check(flags in (0, 1) and (flags == 0 or encoded == decoded), 'invalid frame flags or RAW size')
      check((HEADER_SIZE + encoded + SECTOR_SIZE - 1) // SECTOR_SIZE * SECTOR_SIZE == wire, 'noncanonical wire size')
      check(decoded <= extent_remaining, 'frame crosses extent boundary')
      if flags:
        ctypes.memmove(decoded_buffer, ctypes.byref(wire_buffer, HEADER_SIZE), decoded)
      else:
        result = lib.LZ4_decompress_safe(ctypes.byref(wire_buffer, HEADER_SIZE), decoded_buffer, encoded, decoded)
        check(result == decoded, 'invalid LZ4 block or decoded size')
      # Reuse the encoded buffer once decoding and hashing are complete.
      payload.readinto(wire_view[:decoded])
      check(libc.memcmp(wire_buffer, decoded_buffer, decoded) == 0, 'decoded content differs from source')
      consumed += wire
      decoded_total += decoded
      extent_remaining -= decoded
      if extent_remaining == 0:
        extent_index += 1
        extent_remaining = index['extents'][extent_index][1] * SECTOR_SIZE if extent_index < len(index['extents']) else 0
      final = consumed == compressed_bytes
      check((next_wire == 0) == final, 'frame chain differs from compressed size')
      check((extent_index == len(index['extents'])) == final, 'frame chain differs from source extents')
      if final:
        break
      wire = next_wire
    payload.finish()
    check(decoded_total == index['data_sectors'] * SECTOR_SIZE and not encoded_file.read(1), 'payload total or EOF differs')
  actual = digest.hexdigest()
  check('hash' not in metadata or actual == metadata['hash'], 'encoded SHA256 mismatch')
  return actual


def encode_lz4(source, target, block_size=MAX_DECODED_BYTES):
  """Encode and independently verify an optimized sparse image using about 2 MiB of buffers."""
  source, target = Path(source), Path(target)
  check(source.resolve() != target.resolve() and not (target.exists() and source.samefile(target)), 'source and target must differ')
  check(type(block_size) is int and 0 < block_size <= MAX_DECODED_BYTES and block_size % SECTOR_SIZE == 0, 'invalid block size')
  index = source_index(source)
  stream = write_frames(source, target, index, block_size)
  metadata = {'file_size': stream['compressed_bytes'], 'stream': stream}
  metadata['hash'] = verify_lz4(source, target, metadata)
  return metadata
