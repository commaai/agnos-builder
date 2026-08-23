#!/usr/bin/env python3
"""Exercise the installed Noble nbdkit/FAT tools against production code."""

from __future__ import annotations

import hashlib
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

REQUIRED_TOOLS = ("nbdkit", "nbdcopy", "fsck.fat", "mdir", "mcopy", "dd")


def require_tools() -> None:
  missing = [tool for tool in REQUIRED_TOOLS if shutil.which(tool) is None]
  if missing:
    raise RuntimeError(f"missing integration-test tools: {', '.join(missing)}")


def build_snapshot(
  root: Path,
  *,
  segment_name: str,
  payload_size: int,
  extra_files: dict[str, bytes] | None = None,
) -> tuple[Path, str, bytes | None]:
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
  for name, contents in (extra_files or {}).items():
    (segment / name).write_bytes(contents)

  snapshot = root / usb_storage.MANAGED_SNAPSHOT_NAME
  result = usb_storage.SnapshotBuilder(
    source,
    snapshot,
    wall_clock_ns=lambda: time.time_ns() + 10 * usb_storage.DEFAULT_STABILITY_AGE_NS,
  ).build()
  if len(result.included) != 1 or result.excluded:
    raise RuntimeError(f"unexpected snapshot result: {result}")
  return snapshot, result.included[0], expected


def materialize_and_check(
  root: Path,
  snapshot: Path,
  *,
  extracted_path: str,
  expected_contents: bytes,
  require_multicluster_root: bool = False,
) -> None:
  with tempfile.TemporaryDirectory(prefix="materialized-", dir=root) as temporary_directory:
    materialized_root = Path(temporary_directory)
    disk = materialized_root / "disk.img"
    expected_size, size_argument = usb_storage._nbdkit_layout(snapshot)
    environment = os.environ.copy()
    environment.update({"TMPDIR": str(materialized_root), "OUTPUT_IMAGE": str(disk)})
    command = [
      "/usr/bin/nbdkit",
      "--filter=cow",
      "floppy",
      f"dir={snapshot}",
      "label=COMMA",
    ]
    if size_argument is not None:
      command.append(f"size={size_argument}")
    command.extend([
      "--run",
      'exec /usr/bin/nbdcopy --sparse=4096 "$uri" "$OUTPUT_IMAGE"',
    ])
    subprocess.run(
      command,
      check=True,
      env=environment,
    )
    if disk.stat().st_size != expected_size:
      raise RuntimeError("nbdkit image size differs from the production layout")

    usb_storage._repair_fat32_image(disk)
    partition = materialized_root / "partition.img"
    subprocess.run(
      ["dd", f"if={disk}", f"of={partition}", "bs=1M", "skip=1", "conv=sparse", "status=none"],
      check=True,
    )
    subprocess.run(["fsck.fat", "-n", "-v", str(partition)], check=True)

    offset_image = f"{disk}@@1048576"
    listing = subprocess.run(["mdir", "-i", offset_image, "::"], check=True, capture_output=True, text=True)
    exported_segment = extracted_path.split("/", maxsplit=1)[0]
    if exported_segment not in listing.stdout:
      raise RuntimeError("mtools did not preserve the requested exported segment")
    extracted = materialized_root / "extracted.bin"
    subprocess.run(
      ["mcopy", "-i", offset_image, f"::/{extracted_path}", str(extracted)],
      check=True,
    )
    expected_digest = hashlib.sha256(expected_contents).digest()
    if hashlib.sha256(extracted.read_bytes()).digest() != expected_digest:
      raise RuntimeError("mtools extraction did not preserve the fixture hash")

    if require_multicluster_root:
      with disk.open("rb") as image:
        image.seek(446 + 8)
        partition_lba = int.from_bytes(image.read(4), "little")
        image.seek(partition_lba * usb_storage.SECTOR_SIZE + 14)
        reserved_sectors = int.from_bytes(image.read(2), "little")
        image.seek(partition_lba * usb_storage.SECTOR_SIZE + 44)
        root_cluster = int.from_bytes(image.read(4), "little")
        fat_offset = (partition_lba + reserved_sectors) * usb_storage.SECTOR_SIZE
        image.seek(fat_offset + root_cluster * 4)
        next_root_cluster = int.from_bytes(image.read(4), "little") & 0x0FFFFFFF
      if not 2 <= next_root_cluster < usb_storage.FAT32_END_OF_CHAIN:
        raise RuntimeError("installed nbdkit image did not create a multi-cluster FAT root directory")


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

  materialize_and_check(
    small_root,
    snapshot,
    extracted_path=f"{exported_segment}/fcamera.hevc",
    expected_contents=expected,
  )


def run_natural_size_check(root: Path) -> None:
  large_root = root / "natural"
  large_root.mkdir()
  proof_name = "proof.bin"
  proof_contents = b"natural-size nbdkit repair and extraction proof\x00\xff"
  # Root directory, segment directory, and proof file consume three clusters.
  # The sparse camera file fills the rest of the conservative boundary exactly.
  payload_size = (usb_storage.FAT32_COMPATIBLE_DATA_CLUSTERS - 3) * usb_storage.FAT_CLUSTER_SIZE
  snapshot, exported_segment, _expected = build_snapshot(
    large_root,
    segment_name="00000001--abc123def0--0",
    payload_size=payload_size,
    extra_files={proof_name: proof_contents},
  )
  expected_size, size_argument = usb_storage._nbdkit_layout(snapshot)
  if size_argument is not None or expected_size != usb_storage.MIN_COMPATIBLE_DISK_SIZE:
    raise RuntimeError("natural-size fixture did not hit the exact unpadded boundary")
  sparse_payload = large_root / "realdata" / exported_segment / "fcamera.hevc"
  sparse_metadata = sparse_payload.stat()
  if sparse_metadata.st_size != payload_size or sparse_metadata.st_blocks != 0:
    raise RuntimeError("natural-size fixture payload was not created as a hole-only sparse file")

  materialize_and_check(
    large_root,
    snapshot,
    extracted_path=f"{exported_segment}/{proof_name}",
    expected_contents=proof_contents,
  )


def run_multicluster_root_check(root: Path) -> None:
  multicluster_root = root / "multicluster-root"
  source = multicluster_root / "realdata"
  source.mkdir(parents=True)
  segment_count = 172
  marker_name = "marker.bin"
  late_marker = b"late FAT root-chain entry\x00\xff"
  late_segment = ""
  root_entries = 1  # volume label

  for index in range(segment_count):
    segment_name = f"{index:08x}--abc123def0--0"
    segment = source / segment_name
    segment.mkdir()
    contents = late_marker if index == segment_count - 1 else f"segment {index}\n".encode()
    (segment / marker_name).write_bytes(contents)
    root_entries += 1 + usb_storage._lfn_entry_count(segment_name)
    late_segment = segment_name

  if root_entries * 32 <= usb_storage.FAT_CLUSTER_SIZE:
    raise RuntimeError("multi-cluster fixture did not exceed one FAT root-directory cluster")

  snapshot = multicluster_root / usb_storage.MANAGED_SNAPSHOT_NAME
  result = usb_storage.SnapshotBuilder(
    source,
    snapshot,
    wall_clock_ns=lambda: time.time_ns() + 10 * usb_storage.DEFAULT_STABILITY_AGE_NS,
  ).build()
  if len(result.included) != segment_count or result.excluded:
    raise RuntimeError(f"unexpected multi-cluster snapshot result: {result}")
  if result.included[-1] != late_segment:
    raise RuntimeError("multi-cluster fixture did not preserve the expected late segment name")

  materialize_and_check(
    multicluster_root,
    snapshot,
    extracted_path=f"{late_segment}/{marker_name}",
    expected_contents=late_marker,
    require_multicluster_root=True,
  )


def main() -> None:
  require_tools()
  usb_storage._validate_nbdkit_installation()
  with tempfile.TemporaryDirectory(prefix="usb-storage-nbdkit-") as temporary_directory:
    root = Path(temporary_directory)
    run_small_image_check(root)
    run_natural_size_check(root)
    run_multicluster_root_check(root)
  print("installed nbdkit/FAT integration checks passed")


if __name__ == "__main__":
  main()
