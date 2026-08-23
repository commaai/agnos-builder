#!/usr/bin/env python3
"""Exercise the installed Noble nbdkit/FAT tools against production code."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


COMMA_DIR = Path(__file__).parents[1] / "root" / "usr" / "comma"
SPEC = importlib.util.spec_from_file_location("usb_storage", COMMA_DIR / "usb_storage.py")
if SPEC is None or SPEC.loader is None:
  raise RuntimeError("cannot load usb_storage.py")
usb_storage = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = usb_storage
SPEC.loader.exec_module(usb_storage)

REQUIRED_TOOLS = ("nbdkit", "nbdcopy", "nbdinfo", "fsck.fat", "mdir", "mcopy", "dd")


def require_tools() -> None:
  missing = [tool for tool in REQUIRED_TOOLS if shutil.which(tool) is None]
  if missing:
    raise RuntimeError(f"missing integration-test tools: {', '.join(missing)}")


def build_snapshot(root: Path, *, segment_name: str, payload_size: int) -> tuple[Path, str, bytes | None]:
  source = root / "realdata"
  source.mkdir(parents=True)
  segment = source / segment_name
  segment.mkdir()
  payload = segment / "fcamera.hevc"
  expected: bytes | None = None
  if payload_size <= 1024 * 1024:
    expected = (b"comma USB storage integration\x00\xff" * 64)[:payload_size]
    payload.write_bytes(expected)
  else:
    with payload.open("wb") as stream:
      stream.truncate(payload_size)

  snapshot = root / usb_storage.MANAGED_SNAPSHOT_NAME
  result = usb_storage.SnapshotBuilder(
    source,
    snapshot,
    wall_clock_ns=lambda: time.time_ns() + 10 * usb_storage.DEFAULT_STABILITY_AGE_NS,
  ).build()
  if len(result.included) != 1 or result.excluded:
    raise RuntimeError(f"unexpected snapshot result: {result}")
  return snapshot, result.included[0], expected


def run_small_image_check(root: Path) -> None:
  small_root = root / "small"
  small_root.mkdir()
  snapshot, exported_segment, expected = build_snapshot(
    small_root,
    segment_name="a2a0ccea32023010|2026-08-23--12-34-56--0",
    payload_size=2048,
  )
  if expected is None:
    raise RuntimeError("small fixture was not materialized")

  disk = small_root / "disk.img"
  environment = os.environ.copy()
  environment.update({"TMPDIR": str(small_root), "OUTPUT_IMAGE": str(disk)})
  subprocess.run(
    [
      "/usr/bin/nbdkit",
      "--filter=cow",
      "floppy",
      f"dir={snapshot}",
      "label=COMMA",
      f"size={usb_storage.MIN_COMPATIBLE_DISK_SIZE}",
      "--run",
      'exec /usr/bin/nbdcopy --sparse=1048576 "$uri" "$OUTPUT_IMAGE"',
    ],
    check=True,
    env=environment,
  )
  expected_size, _size_argument = usb_storage._nbdkit_layout(snapshot)
  if disk.stat().st_size != expected_size:
    raise RuntimeError("nbdkit image size differs from the production layout")

  usb_storage._repair_fat32_image(disk)
  partition = small_root / "partition.img"
  subprocess.run(
    ["dd", f"if={disk}", f"of={partition}", "bs=1M", "skip=1", "conv=sparse", "status=none"],
    check=True,
  )
  subprocess.run(["fsck.fat", "-n", "-v", str(partition)], check=True)

  offset_image = f"{disk}@@1048576"
  listing = subprocess.run(["mdir", "-i", offset_image, "::"], check=True, capture_output=True, text=True)
  if exported_segment not in listing.stdout:
    raise RuntimeError("mtools did not preserve the exported segment name")
  extracted = small_root / "extracted.hevc"
  subprocess.run(
    ["mcopy", "-i", offset_image, f"::/{exported_segment}/fcamera.hevc", str(extracted)],
    check=True,
  )
  if extracted.read_bytes() != expected:
    raise RuntimeError("mtools extraction did not preserve fixture bytes")


def run_natural_size_check(root: Path) -> None:
  large_root = root / "natural"
  large_root.mkdir()
  # Root directory + segment directory consume two clusters. The sparse file
  # fills the rest of the conservative FAT32 boundary exactly.
  payload_size = (usb_storage.FAT32_COMPATIBLE_DATA_CLUSTERS - 2) * usb_storage.FAT_CLUSTER_SIZE
  snapshot, _exported_segment, _expected = build_snapshot(
    large_root,
    segment_name="00000001--abc123def0--0",
    payload_size=payload_size,
  )
  expected_size, size_argument = usb_storage._nbdkit_layout(snapshot)
  if size_argument is not None or expected_size != usb_storage.MIN_COMPATIBLE_DISK_SIZE:
    raise RuntimeError("natural-size fixture did not hit the exact unpadded boundary")

  environment = os.environ.copy()
  environment.update({"TMPDIR": str(large_root), "EXPECTED_SIZE": str(expected_size)})
  subprocess.run(
    [
      "/usr/bin/nbdkit",
      "--filter=cow",
      "floppy",
      f"dir={snapshot}",
      "label=COMMA",
      "--run",
      'test "$(/usr/bin/nbdinfo --size "$uri")" = "$EXPECTED_SIZE"',
    ],
    check=True,
    env=environment,
  )


def main() -> None:
  require_tools()
  usb_storage._validate_nbdkit_installation()
  with tempfile.TemporaryDirectory(prefix="usb-storage-nbdkit-") as temporary_directory:
    root = Path(temporary_directory)
    run_small_image_check(root)
    run_natural_size_check(root)
  print("installed nbdkit/FAT integration checks passed")


if __name__ == "__main__":
  main()
