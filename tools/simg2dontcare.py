#!/usr/bin/env python3
import argparse
import sys
import struct
from enum import IntEnum

# https://android.googlesource.com/platform/system/core/+/master/libsparse/sparse_format.h
class ChunkType(IntEnum):
  RAW = 0xCAC1
  FILL = 0xCAC2
  DONT_CARE = 0xCAC3
  CRC32 = 0xCAC4

ChunkHeader = struct.Struct("<2H2I")


def process_image(input_image: str, output_image: str) -> None:
  with open(input_image, "rb") as inf, open(output_image, "wb") as outf:
    dat = inf.read(28)
    outf.write(dat)

    header = struct.unpack("<I4H4I", dat)

    magic = header[0]
    major_version = header[1]
    minor_version = header[2]
    file_hdr_sz = header[3]
    chunk_hdr_sz = header[4]
    total_chunks = header[7]
    image_checksum = header[8]

    assert magic == 0xED26FF3A
    assert major_version == 1 and minor_version == 0
    assert file_hdr_sz == 28
    assert chunk_hdr_sz == 12

    for _ in range(1, total_chunks+1):
      header_bin = inf.read(12)

      header = ChunkHeader.unpack(header_bin)
      chunk_type = ChunkType(header[0])
      chunk_sz = header[2]
      total_sz = header[3]
      data_sz = total_sz - 12

      # replace fill 0s with DONT_CARE chunks
      if chunk_type == ChunkType.FILL:
        assert data_sz == 4
        fill_bin = inf.read(4)
        fill = struct.unpack("<I", fill_bin)[0]
        if fill == 0:
          # https://coral.googlesource.com/img2simg/+/refs/heads/master/libsparse/output_file.c#351
          dat = ChunkHeader.pack(ChunkType.DONT_CARE, 0, chunk_sz, ChunkHeader.size)
          outf.write(dat)
          continue
        else:
          inf.seek(inf.tell() - data_sz)

      # pass through other chunk types
      outf.write(header_bin)
      dat = inf.read(data_sz)
      outf.write(dat)


if __name__ == "__main__":
  parser = argparse.ArgumentParser(description="Replace FILL 0 chunks in a sparse image with DONT_CARE chunks",
                                   formatter_class=argparse.ArgumentDefaultsHelpFormatter)
  parser.add_argument("input_image", nargs="?", help="Input sparse image")
  parser.add_argument("output_image", nargs="?", help="Output sparse image")
  args = parser.parse_args(sys.argv[1:])

  if args.input_image is None or args.output_image is None:
    parser.print_help()
    exit(1)

  process_image(args.input_image, args.output_image)
