#!/usr/bin/env python3
"""Expose completed openpilot route segments as a read-only USB disk.

The FAT image is synthesized by nbdkit from a hard-link snapshot.  Keeping a
separate directory namespace is important: loggerd's deleter may unlink the
original route while a host is still copying it, but the snapshot link remains
valid until the USB session ends.
"""

from __future__ import annotations

import argparse
import dataclasses
import enum
import errno
import fcntl
import logging
import os
from pathlib import Path
import re
import signal
import stat
import struct
import subprocess
import threading
import time
import unicodedata
from collections.abc import Callable, Iterator, Sequence
from contextlib import contextmanager
from typing import Any


LOG = logging.getLogger("usb-storage")

MANAGED_SNAPSHOT_NAME = "usb-storage-snapshot"
MANAGED_MOUNT_DIRECTORY = "usb-storage"
MANAGED_MOUNT_NAME = "footage.img"
# nbdkit-floppy rejects files whose size cannot fit in its uint32_t field.
MAX_FAT_FILE_SIZE = (1 << 32) - 1
DEFAULT_STABILITY_AGE_NS = 2_000_000_000
# A configfs unbind/rebind can briefly report "not attached" even though the
# cable never moved. Require a stable disconnect before starting a new session
# so a persistent exporter failure cannot flap the composite USB device.
PHYSICAL_DETACH_DEBOUNCE_SECONDS = 2.0
# Match loggerd's current deleter safety floor. A connected hard-link snapshot
# can pin otherwise deleted footage, so release it as soon as either limit is
# reached rather than letting logging exhaust userdata.
MIN_FREE_BYTES = 5 * 1024**3
MIN_FREE_PERCENT = 10.0
LOG_ID_V2_PATTERN = r"[a-f0-9]{8}--[a-z0-9]{10}"
TIMESTAMP_PATTERN = r"[0-9]{4}-[0-9]{2}-[0-9]{2}--[0-9]{2}-[0-9]{2}-[0-9]{2}"
SEGMENT_NAME_RE = re.compile(
  rf"^(?:{LOG_ID_V2_PATTERN}|{TIMESTAMP_PATTERN}|[a-f0-9]{{16}}[|_](?:{TIMESTAMP_PATTERN}|{LOG_ID_V2_PATTERN}))--[0-9]+$",
)
WINDOWS_FORBIDDEN_CHARS = frozenset('<>:"/\\|?*')
WINDOWS_RESERVED_BASENAMES = frozenset({"CON", "PRN", "AUX", "NUL"} | {f"COM{number}" for number in range(1, 10)} | {f"LPT{number}" for number in range(1, 10)})
SECTOR_SIZE = 512
# nbdkit 1.36's floppy plugin fixes FAT32 clusters at 32 sectors.
FAT_CLUSTER_SIZE = 32 * SECTOR_SIZE
FAT32_MIN_DATA_CLUSTERS = 65_525
# Microsoft recommends staying at least 16 clusters above the FAT16/FAT32
# cutover because some FAT implementations classify near-boundary volumes
# incorrectly.
FAT32_COMPATIBLE_DATA_CLUSTERS = FAT32_MIN_DATA_CLUSTERS + 16
# Small exports need padding or operating systems classify nbdkit's FAT32
# volume as FAT16.  This exact size is accepted by nbdkit 1.36's size
# inversion and yields 65,541 data clusters; arbitrary sizes can trip an
# internal equality assertion in that plugin version.
MIN_COMPATIBLE_DISK_SIZE = 1_075_445_760
SUPPORTED_NBDKIT_FLOPPY_VERSION = "1.36.3"
FAT32_END_OF_CHAIN = 0x0FFFFFF8
FAT32_BAD_CLUSTER = 0x0FFFFFF7


class StorageError(RuntimeError):
  pass


class UnsafeTreeError(StorageError):
  pass


class LunUnavailableError(StorageError):
  pass


class LunBusyError(StorageError):
  pass


class ForeignLunError(StorageError):
  pass


class UdcUnavailableError(StorageError):
  pass


class SessionEnd(enum.StrEnum):
  EJECTED = "ejected"
  DETACHED = "detached"
  LOW_SPACE = "low-space"
  STOPPED = "stopped"


@dataclasses.dataclass(frozen=True)
class EntryRecord:
  relative_path: Path
  is_directory: bool
  device: int
  inode: int
  size: int
  mtime_ns: int


@dataclasses.dataclass(frozen=True)
class SnapshotResult:
  included: tuple[str, ...]
  excluded: tuple[tuple[str, str], ...]


def _validate_nbdkit_installation(
  runner: Callable[..., Any] = subprocess.run,
) -> None:
  command = ["/usr/bin/nbdkit", "--filter=cow", "floppy", "--dump-plugin"]
  try:
    result = runner(command, check=False, capture_output=True, text=True, timeout=5.0)
  except (OSError, subprocess.SubprocessError) as exc:
    raise StorageError(f"cannot inspect the installed nbdkit floppy exporter: {exc}") from exc
  if result.returncode != 0:
    raise StorageError(f"nbdkit floppy/COW probe failed with status {result.returncode}")

  fields: dict[str, str] = {}
  for line in result.stdout.splitlines():
    key, separator, value = line.partition("=")
    if separator:
      fields[key] = value
  if fields.get("name") != "floppy" or fields.get("cow_name") != "cow":
    raise StorageError("installed nbdkit is missing the expected floppy plugin or COW filter")
  if fields.get("version") != SUPPORTED_NBDKIT_FLOPPY_VERSION:
    raise StorageError(
      f"unsupported nbdkit floppy version {fields.get('version', 'unknown')!r}; expected {SUPPORTED_NBDKIT_FLOPPY_VERSION}",
    )


def _validate_portable_name(name: str) -> None:
  try:
    name.encode("utf-8", errors="strict")
    utf16_length = len(name.encode("utf-16-le", errors="strict")) // 2
  except UnicodeEncodeError as exc:
    raise UnsafeTreeError(f"filename is not valid Unicode: {name!r}") from exc

  if not name or utf16_length > 255:
    raise UnsafeTreeError(f"filename is too long for VFAT: {name!r}")
  if name.endswith((".", " ")):
    raise UnsafeTreeError(f"filename has a Windows-forbidden suffix: {name!r}")
  if any(unicodedata.category(character).startswith("C") or character in WINDOWS_FORBIDDEN_CHARS for character in name):
    raise UnsafeTreeError(f"filename contains a Windows-forbidden character: {name!r}")
  if name.split(".", maxsplit=1)[0].upper() in WINDOWS_RESERVED_BASENAMES:
    raise UnsafeTreeError(f"filename uses a reserved DOS basename: {name!r}")


def _portable_name_key(name: str) -> str:
  """Return a conservative key for names that collide on FAT/Windows."""
  _validate_portable_name(name)
  return unicodedata.normalize("NFC", name).casefold()


def _portable_segment_name(name: str) -> str:
  # Legacy route identifiers use '|' between dongle ID and timestamp.  The
  # openpilot route parser also accepts '_' there, and unlike '|', '_' is valid
  # on Windows.  Current counter/random route identifiers pass through intact.
  portable_name = name.replace("|", "_")
  _portable_name_key(portable_name)
  return portable_name


def _round_up(value: int, alignment: int) -> int:
  return ((value + alignment - 1) // alignment) * alignment


def _lfn_entry_count(name: str) -> int:
  _validate_portable_name(name)
  utf16_units = len(name.encode("utf-16-le", errors="strict")) // 2
  # nbdkit 1.36 intentionally emits one extra zero-padded LFN slot when the
  # length is an exact multiple of 13; mirror its loop exactly.
  return 1 + utf16_units // 13


def _snapshot_fat_data_size(root: Path) -> int:
  """Mirror nbdkit-floppy's directory and file cluster accounting."""
  metadata = root.lstat()
  if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
    raise StorageError("snapshot root is not a real directory")

  total = 0
  for directory, directory_names, file_names in os.walk(root, topdown=True, followlinks=False):
    directory_path = Path(directory)
    # Root has one volume-label entry; other directories have '.' and '..'.
    directory_entries = 1 if directory_path == root else 2
    for name in (*directory_names, *file_names):
      directory_entries += 1 + _lfn_entry_count(name)
    total += _round_up(directory_entries * 32, FAT_CLUSTER_SIZE)

    for directory_name in directory_names:
      child = directory_path / directory_name
      child_metadata = child.lstat()
      if not stat.S_ISDIR(child_metadata.st_mode) or stat.S_ISLNK(child_metadata.st_mode):
        raise StorageError(f"snapshot contains unsafe directory: {child}")
    for file_name in file_names:
      child = directory_path / file_name
      child_metadata = child.lstat()
      if not stat.S_ISREG(child_metadata.st_mode) or stat.S_ISLNK(child_metadata.st_mode):
        raise StorageError(f"snapshot contains unsafe file: {child}")
      if child_metadata.st_size == 0:
        # Recheck at the last prelaunch scan: a hard-linked source inode can be
        # truncated after snapshot construction, and nbdkit 1.36 would then
        # emit an invalid free first cluster for it.
        raise StorageError(f"snapshot contains an empty file unsupported by nbdkit floppy: {child}")
      total += _round_up(child_metadata.st_size, FAT_CLUSTER_SIZE)
  return total


def _nbdkit_layout(root: Path) -> tuple[int, int | None]:
  """Return (expected image size, optional nbdkit size= padding)."""
  used_clusters = _snapshot_fat_data_size(root) // FAT_CLUSTER_SIZE
  if used_clusters < FAT32_COMPATIBLE_DATA_CLUSTERS:
    return MIN_COMPATIBLE_DISK_SIZE, MIN_COMPATIBLE_DISK_SIZE

  # Without size=, nbdkit uses exactly the allocated directory/file clusters.
  # Omitting the option also avoids its broken size inversion for larger trees.
  fat_clusters = (used_clusters + 2 + 4095) // 4096
  expected_size = (65 + (2 * fat_clusters) + used_clusters) * FAT_CLUSTER_SIZE
  return expected_size, None


def _pread_exact(descriptor: int, length: int, offset: int) -> bytes:
  chunks = bytearray()
  while len(chunks) < length:
    chunk = os.pread(descriptor, length - len(chunks), offset + len(chunks))
    if not chunk:
      raise StorageError("unexpected end of virtual FAT32 image")
    chunks.extend(chunk)
  return bytes(chunks)


def _pwrite_exact(descriptor: int, data: bytes, offset: int) -> None:
  written = 0
  while written < len(data):
    count = os.pwrite(descriptor, data[written:], offset + written)
    if count <= 0:
      raise StorageError("short write while repairing virtual FAT32 image")
    written += count


def _repair_fat32_image(path: Path) -> None:
  """Repair nbdkit 1.36 FAT metadata that strict macOS checks reject."""
  flags = os.O_RDWR | os.O_CLOEXEC
  if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
  descriptor = os.open(path, flags)
  try:
    image_metadata = os.fstat(descriptor)
    if not stat.S_ISREG(image_metadata.st_mode) or image_metadata.st_size % SECTOR_SIZE:
      raise StorageError("virtual FAT32 image has an invalid file type or size")

    mbr = _pread_exact(descriptor, SECTOR_SIZE, 0)
    if mbr[510:512] != b"\x55\xaa":
      raise StorageError("virtual FAT32 image has no valid MBR signature")
    partition = mbr[446:462]
    if partition[4] != 0x0C or any(mbr[offset:offset + 16] != bytes(16) for offset in (462, 478, 494)):
      raise StorageError("virtual FAT32 image has an unexpected partition table")
    partition_lba, partition_sectors = struct.unpack_from("<II", partition, 8)
    partition_offset = partition_lba * SECTOR_SIZE
    partition_end = partition_offset + partition_sectors * SECTOR_SIZE
    if partition_lba != 2048 or partition_sectors == 0 or partition_end != image_metadata.st_size:
      raise StorageError("virtual FAT32 partition lies outside its image")

    boot = bytearray(_pread_exact(descriptor, SECTOR_SIZE, partition_offset))
    if boot[0:3] not in (bytes(3), b"\xeb\x58\x90") or boot[3:11] != b"MSWIN4.1" or boot[510:512] != b"\x55\xaa":
      raise StorageError("virtual FAT32 boot sector is not the expected nbdkit format")
    bytes_per_sector = struct.unpack_from("<H", boot, 11)[0]
    sectors_per_cluster = boot[13]
    reserved_sectors = struct.unpack_from("<H", boot, 14)[0]
    number_of_fats = boot[16]
    root_entries = struct.unpack_from("<H", boot, 17)[0]
    old_total_sectors = struct.unpack_from("<H", boot, 19)[0]
    media_descriptor = boot[21]
    old_sectors_per_fat = struct.unpack_from("<H", boot, 22)[0]
    sectors_per_track = struct.unpack_from("<H", boot, 24)[0]
    number_of_heads = struct.unpack_from("<H", boot, 26)[0]
    hidden_sectors = struct.unpack_from("<I", boot, 28)[0]
    total_sectors = struct.unpack_from("<I", boot, 32)[0]
    sectors_per_fat = struct.unpack_from("<I", boot, 36)[0]
    mirroring = struct.unpack_from("<H", boot, 40)[0]
    fat_version = struct.unpack_from("<H", boot, 42)[0]
    root_cluster = struct.unpack_from("<I", boot, 44)[0]
    fsinfo_sector = struct.unpack_from("<H", boot, 48)[0]
    backup_sector = struct.unpack_from("<H", boot, 50)[0]
    if (
      bytes_per_sector != SECTOR_SIZE
      or sectors_per_cluster != FAT_CLUSTER_SIZE // SECTOR_SIZE
      or reserved_sectors != 32
      or root_entries != 0
      or old_total_sectors != 0
      or media_descriptor != 0xF8
      or old_sectors_per_fat != 0
      or sectors_per_track not in (0, 63)
      or number_of_heads not in (0, 255)
      or number_of_fats != 2
      or hidden_sectors not in (0, partition_lba)
      or total_sectors != partition_sectors
      or sectors_per_fat == 0
      or mirroring != 0
      or fat_version != 0
      or root_cluster != 2
      or fsinfo_sector != 1
      or backup_sector != 6
      or boot[64] not in (0, 0x80)
      or boot[66] != 0x29
      or boot[82:90] != b"FAT32   "
    ):
      raise StorageError("virtual FAT32 image has unexpected filesystem geometry")

    fat_offset = partition_offset + reserved_sectors * SECTOR_SIZE
    data_sector = reserved_sectors + number_of_fats * sectors_per_fat
    if data_sector >= total_sectors:
      raise StorageError("virtual FAT32 data region is outside the partition")
    data_offset = partition_offset + data_sector * SECTOR_SIZE
    data_sectors = total_sectors - data_sector
    data_clusters = data_sectors // sectors_per_cluster
    max_cluster = data_clusters + 1
    fat_entry_capacity = sectors_per_fat * SECTOR_SIZE // 4
    if (
      data_sectors % sectors_per_cluster
      or sectors_per_fat % sectors_per_cluster
      or fat_entry_capacity < data_clusters + 2
      or data_clusters < FAT32_COMPATIBLE_DATA_CLUSTERS
      or root_cluster > max_cluster
    ):
      raise StorageError("virtual FAT32 image is too small or has an invalid root cluster")

    expected_jump = b"\xeb\x58\x90"
    boot[0:3] = expected_jump
    struct.pack_into("<H", boot, 24, 63)
    struct.pack_into("<H", boot, 26, 255)
    struct.pack_into("<I", boot, 28, partition_lba)
    boot[64] = 0x80
    backup = bytearray(_pread_exact(descriptor, SECTOR_SIZE, partition_offset + backup_sector * SECTOR_SIZE))
    if backup[3:] != bytearray(_pread_exact(descriptor, SECTOR_SIZE, partition_offset))[3:]:
      raise StorageError("virtual FAT32 backup boot sector does not match the primary")
    backup[:] = boot

    patches: list[tuple[int, bytes]] = [
      (partition_offset, bytes(boot)),
      (partition_offset + backup_sector * SECTOR_SIZE, bytes(backup)),
    ]
    seen_root_clusters: set[int] = set()
    seen_children: set[int] = set()
    cluster = root_cluster
    end_of_directory = False
    cluster_bytes = sectors_per_cluster * SECTOR_SIZE
    while not end_of_directory:
      if cluster in seen_root_clusters or not (2 <= cluster <= max_cluster):
        raise StorageError("virtual FAT32 root directory has an invalid cluster chain")
      seen_root_clusters.add(cluster)
      cluster_offset = data_offset + (cluster - 2) * cluster_bytes
      directory_data = _pread_exact(descriptor, cluster_bytes, cluster_offset)
      for entry_offset in range(0, cluster_bytes, 32):
        entry = directory_data[entry_offset:entry_offset + 32]
        if entry[0] == 0:
          end_of_directory = True
          break
        if entry[0] == 0xE5 or entry[11] == 0x0F or entry[11] & 0x08 or not entry[11] & 0x10:
          continue
        child_cluster = (struct.unpack_from("<H", entry, 20)[0] << 16) | struct.unpack_from("<H", entry, 26)[0]
        if child_cluster in seen_children or not (2 <= child_cluster <= max_cluster):
          raise StorageError("virtual FAT32 root contains an invalid child directory")
        seen_children.add(child_cluster)
        child_offset = data_offset + (child_cluster - 2) * cluster_bytes
        dot_entries = bytearray(_pread_exact(descriptor, 64, child_offset))
        dot_cluster = (struct.unpack_from("<H", dot_entries, 20)[0] << 16) | struct.unpack_from("<H", dot_entries, 26)[0]
        parent_cluster = (struct.unpack_from("<H", dot_entries, 52)[0] << 16) | struct.unpack_from("<H", dot_entries, 58)[0]
        if dot_entries[0:11] != b".          " or dot_entries[32:43] != b"..         " or not (dot_entries[11] & 0x10 and dot_entries[43] & 0x10):
          raise StorageError("virtual FAT32 child directory lacks valid dot entries")
        if dot_cluster != child_cluster or parent_cluster not in (0, root_cluster):
          raise StorageError("virtual FAT32 child directory has invalid dot clusters")
        struct.pack_into("<H", dot_entries, 52, 0)
        struct.pack_into("<H", dot_entries, 58, 0)
        patches.append((child_offset + 32, bytes(dot_entries[32:64])))

      if end_of_directory:
        break
      next_cluster = struct.unpack("<I", _pread_exact(descriptor, 4, fat_offset + cluster * 4))[0] & 0x0FFFFFFF
      if next_cluster >= FAT32_END_OF_CHAIN:
        break
      if next_cluster in (0, 1, FAT32_BAD_CLUSTER):
        raise StorageError("virtual FAT32 root directory has a broken FAT chain")
      cluster = next_cluster

    for offset, data in patches:
      _pwrite_exact(descriptor, data, offset)
    os.fsync(descriptor)
    for offset, data in patches:
      if _pread_exact(descriptor, len(data), offset) != data:
        raise StorageError("virtual FAT32 metadata repair did not persist")
  finally:
    os.close(descriptor)


def _entry_record(path: Path, relative_path: Path) -> EntryRecord:
  _validate_portable_name(path.name)
  metadata = path.lstat()
  mode = metadata.st_mode
  if stat.S_ISLNK(mode):
    raise UnsafeTreeError(f"contains symbolic link: {relative_path}")
  if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
    raise UnsafeTreeError(f"contains non-regular entry: {relative_path}")
  if path.name.endswith(".lock"):
    raise UnsafeTreeError(f"contains active lock: {relative_path}")
  if stat.S_ISREG(mode) and metadata.st_size >= MAX_FAT_FILE_SIZE:
    raise UnsafeTreeError(f"contains file too large for FAT32: {relative_path}")
  return EntryRecord(
    relative_path=relative_path,
    is_directory=stat.S_ISDIR(mode),
    device=metadata.st_dev,
    inode=metadata.st_ino,
    size=metadata.st_size,
    mtime_ns=metadata.st_mtime_ns,
  )


def _chmod_directory(path: Path, mode: int) -> None:
  """Change a real directory by descriptor, never following a symlink."""
  if not hasattr(os, "O_DIRECTORY") or not hasattr(os, "O_NOFOLLOW"):
    raise StorageError("secure directory chmod is unsupported on this platform")
  descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW)
  try:
    if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
      raise StorageError(f"managed path is not a directory: {path}")
    os.fchmod(descriptor, mode)
  finally:
    os.close(descriptor)


def _scan_tree(root: Path) -> tuple[EntryRecord, ...]:
  root_metadata = root.lstat()
  if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(root_metadata.st_mode):
    raise UnsafeTreeError("segment root is not a real directory")

  records: list[EntryRecord] = []

  def scan(directory: Path, relative_directory: Path) -> None:
    try:
      entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
    except OSError as exc:
      raise UnsafeTreeError(f"cannot scan {relative_directory or Path('.')}: {exc}") from exc

    portable_names: dict[str, str] = {}
    children: list[tuple[Path, EntryRecord]] = []
    for entry in entries:
      relative_path = relative_directory / entry.name
      path = directory / entry.name
      try:
        record = _entry_record(path, relative_path)
      except OSError as exc:
        raise UnsafeTreeError(f"cannot inspect {relative_path}: {exc}") from exc
      if not record.is_directory and record.size == 0:
        # nbdkit 1.36's floppy plugin gives empty files a free first cluster,
        # producing an invalid FAT chain. There is no payload to recover, so
        # omit only the empty artifact and retain useful siblings.
        LOG.warning("omitting empty file unsupported by nbdkit floppy: %s", relative_path)
        continue
      key = _portable_name_key(entry.name)
      if key in portable_names:
          location = relative_directory or Path(".")
          raise UnsafeTreeError(
            f"contains FAT/Windows-colliding names in {location}: {portable_names[key]!r} and {entry.name!r}",
        )
      portable_names[key] = entry.name
      children.append((path, record))

    for path, record in children:
      records.append(record)
      if record.is_directory:
        scan(path, record.relative_path)

  scan(root, Path())
  return tuple(records)


class SnapshotBuilder:
  """Build and remove the one narrowly named directory this service owns."""

  def __init__(
    self,
    source: str | os.PathLike[str],
    snapshot: str | os.PathLike[str],
    *,
    wall_clock_ns: Callable[[], int] = time.time_ns,
    stability_age_ns: int = DEFAULT_STABILITY_AGE_NS,
  ):
    source_path = Path(source)
    snapshot_path = Path(snapshot)
    if not source_path.is_absolute() or not snapshot_path.is_absolute():
      raise StorageError("source and snapshot paths must be absolute")

    # realdata is created by openpilot and may not exist when this boot service
    # starts. Resolve as much as possible now, then validate it before building.
    self.requested_source = source_path
    self.source = source_path.resolve(strict=False)
    self.requested_snapshot_parent = snapshot_path.parent
    snapshot_parent = self.requested_snapshot_parent.resolve(strict=True)
    self.snapshot = snapshot_parent / snapshot_path.name
    if stability_age_ns <= 0:
      raise StorageError("segment stability age must be positive")
    self.wall_clock_ns = wall_clock_ns
    self.stability_age_ns = stability_age_ns
    self._validate_managed_path()

  def _validate_managed_path(self) -> None:
    if self.snapshot.name != MANAGED_SNAPSHOT_NAME:
      raise StorageError(f"refusing unmanaged snapshot path (basename must be {MANAGED_SNAPSHOT_NAME!r})")
    parent_metadata = self.snapshot.parent.lstat()
    if not stat.S_ISDIR(parent_metadata.st_mode) or stat.S_ISLNK(parent_metadata.st_mode):
      raise StorageError("snapshot parent must be a real directory")
    if self.snapshot.parent == Path("/"):
      raise StorageError("snapshot must not be placed directly below the filesystem root")
    if self.requested_snapshot_parent.resolve(strict=True) != self.snapshot.parent:
      raise StorageError("snapshot parent resolution changed after service start")
    if self.source == self.snapshot or self.snapshot.is_relative_to(self.source) or self.source.is_relative_to(self.snapshot):
      raise StorageError("source and snapshot trees must not contain each other")

  def _validate_build_paths(self) -> None:
    self._validate_managed_path()
    requested_metadata = self.requested_source.lstat()
    if stat.S_ISLNK(requested_metadata.st_mode):
      raise StorageError("source path must not be a symbolic link")
    if self.requested_source.resolve(strict=True) != self.source:
      raise StorageError("source path resolution changed after service start")
    source_metadata = self.source.lstat()
    parent_metadata = self.snapshot.parent.lstat()
    if not stat.S_ISDIR(source_metadata.st_mode) or stat.S_ISLNK(source_metadata.st_mode):
      raise StorageError("source must be a real directory")
    if source_metadata.st_dev != parent_metadata.st_dev:
      raise StorageError("snapshot and source must be on the same filesystem")

  def source_is_ready(self) -> bool:
    try:
      self._validate_build_paths()
      return True
    except FileNotFoundError:
      return False

  def _validate_existing_snapshot(self) -> None:
    self._validate_managed_path()
    try:
      metadata = self.snapshot.lstat()
    except FileNotFoundError:
      return
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
      raise StorageError("managed snapshot path exists but is not a real directory")
    if os.path.ismount(self.snapshot):
      raise StorageError("refusing to remove a mounted snapshot directory")

    # Reject nested mounts before a bottom-up walk could cross into one. This
    # check is deliberately separate from deletion so validation completes
    # before the first unlink.
    for directory, directory_names, _ in os.walk(self.snapshot, topdown=True, followlinks=False):
      directory_path = Path(directory)
      for directory_name in directory_names:
        child = directory_path / directory_name
        metadata = child.lstat()
        if not stat.S_ISLNK(metadata.st_mode) and os.path.ismount(child):
          raise StorageError(f"refusing to remove nested mount: {child}")

  def _remove_snapshot_tree(self) -> None:
    self._validate_existing_snapshot()
    if not self.snapshot.exists():
      return

    for directory, directory_names, file_names in os.walk(self.snapshot, topdown=False, followlinks=False):
      directory_path = Path(directory)
      _chmod_directory(directory_path, 0o700)
      for file_name in file_names:
        (directory_path / file_name).unlink()
      for directory_name in directory_names:
        child = directory_path / directory_name
        metadata = child.lstat()
        if stat.S_ISLNK(metadata.st_mode):
          child.unlink()
        else:
          _chmod_directory(child, 0o700)
          child.rmdir()
    self.snapshot.rmdir()

  def cleanup(self) -> None:
    self._remove_snapshot_tree()

  def _candidate_segments(self) -> Iterator[Path]:
    try:
      top_entries = sorted(os.scandir(self.source), key=lambda entry: entry.name)
    except OSError as exc:
      raise StorageError(f"cannot list realdata: {exc}") from exc

    for entry in top_entries:
      entry_path = self.source / entry.name
      try:
        metadata = entry_path.lstat()
      except OSError:
        continue
      if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        continue

      if SEGMENT_NAME_RE.fullmatch(entry.name):
        yield entry_path

  @staticmethod
  def _make_directories(destination: Path, records: tuple[EntryRecord, ...]) -> None:
    destination.mkdir(parents=True, mode=0o700)
    for record in records:
      if record.is_directory:
        (destination / record.relative_path).mkdir(mode=0o700)

  @staticmethod
  def _link_files(source: Path, destination: Path, records: tuple[EntryRecord, ...]) -> None:
    for record in records:
      if record.is_directory:
        continue
      source_file = source / record.relative_path
      destination_file = destination / record.relative_path
      before = _entry_record(source_file, record.relative_path)
      if before != record:
        raise UnsafeTreeError(f"changed while snapshotting: {record.relative_path}")
      os.link(source_file, destination_file, follow_symlinks=False)
      linked_metadata = destination_file.lstat()
      if not stat.S_ISREG(linked_metadata.st_mode) or linked_metadata.st_dev != record.device or linked_metadata.st_ino != record.inode:
        raise UnsafeTreeError(f"hard-link verification failed: {record.relative_path}")

  @staticmethod
  def _freeze_directories(destination: Path) -> None:
    directories = [Path(root) for root, _, _ in os.walk(destination, followlinks=False)]
    for directory in reversed(directories):
      _chmod_directory(directory, 0o555)

  @staticmethod
  def _remove_candidate(destination: Path) -> None:
    if not destination.exists():
      return
    for root, directory_names, file_names in os.walk(destination, topdown=False, followlinks=False):
      root_path = Path(root)
      _chmod_directory(root_path, 0o700)
      for file_name in file_names:
        (root_path / file_name).unlink()
      for directory_name in directory_names:
        child = root_path / directory_name
        if child.is_symlink():
          child.unlink()
        else:
          _chmod_directory(child, 0o700)
          child.rmdir()
    destination.rmdir()

  def build(self) -> SnapshotResult:
    self._validate_build_paths()
    source_before = self.source.lstat()
    self._remove_snapshot_tree()
    self.snapshot.mkdir(mode=0o700)
    included: list[str] = []
    excluded: list[tuple[str, str]] = []

    try:
      candidates: dict[str, list[tuple[str, Path]]] = {}
      for source_segment in self._candidate_segments():
        try:
          destination_name = _portable_segment_name(source_segment.name)
        except UnsafeTreeError as exc:
          excluded.append((source_segment.name, str(exc)))
          continue
        collision_key = _portable_name_key(destination_name)
        candidates.setdefault(collision_key, []).append((destination_name, source_segment))

      for mapped_segments in candidates.values():
        if len(mapped_segments) != 1:
          reason = f"portable segment name collides as {mapped_segments[0][0]!r}"
          excluded.extend((source_segment.name, reason) for _destination_name, source_segment in mapped_segments)
          continue

        destination_name, source_segment = mapped_segments[0]
        relative_segment = Path(destination_name)
        destination_segment = self.snapshot / relative_segment
        try:
          root_before = source_segment.lstat()
          first_manifest = _scan_tree(source_segment)
          if not any(not record.is_directory for record in first_manifest):
            raise UnsafeTreeError("contains no exportable non-empty files")
          newest_mtime_ns = max((root_before.st_mtime_ns, *(record.mtime_ns for record in first_manifest)))
          if self.wall_clock_ns() - newest_mtime_ns < self.stability_age_ns:
            raise UnsafeTreeError("segment tree is too recent to be stable")
          self._make_directories(destination_segment, first_manifest)
          self._link_files(source_segment, destination_segment, first_manifest)
          second_manifest = _scan_tree(source_segment)
          if second_manifest != first_manifest:
            raise UnsafeTreeError("tree changed while snapshotting")
          root_after = source_segment.lstat()
          if root_after.st_dev != root_before.st_dev or root_after.st_ino != root_before.st_ino or root_after.st_mtime_ns != root_before.st_mtime_ns:
            raise UnsafeTreeError("segment directory changed while snapshotting")
          included.append(str(relative_segment))
        except (OSError, UnsafeTreeError) as exc:
          self._remove_candidate(destination_segment)
          excluded.append((str(relative_segment), str(exc)))

      # Remove any empty directory left by a rejected candidate.
      for root, _, _ in os.walk(self.snapshot, topdown=False, followlinks=False):
        root_path = Path(root)
        if root_path != self.snapshot and not any(root_path.iterdir()):
          root_path.rmdir()
      source_after = self.source.lstat()
      if source_after.st_dev != source_before.st_dev or source_after.st_ino != source_before.st_ino:
        raise UnsafeTreeError("realdata root changed while snapshotting")
      self._freeze_directories(self.snapshot)
    except BaseException:
      self._remove_snapshot_tree()
      raise

    return SnapshotResult(tuple(included), tuple(excluded))


class StorageManager:
  DISCONNECTED_UDC_STATES = frozenset({"not attached"})
  CONFIGURED_UDC_STATES = frozenset({"configured", "suspended"})

  def __init__(
    self,
    *,
    source: str | os.PathLike[str],
    snapshot: str | os.PathLike[str],
    mount: str | os.PathLike[str],
    lun: str | os.PathLike[str],
    udc_state: str | os.PathLike[str],
    gadget_lock: str | os.PathLike[str],
    gadget_helper: str | os.PathLike[str] = "/usr/comma/usb_gadget.sh",
    ready_timeout: float = 20.0,
    stop_timeout: float = 5.0,
    poll_interval: float = 0.1,
    idle_poll_interval: float = 1.0,
    process_factory: Callable[..., Any] = subprocess.Popen,
    command_runner: Callable[..., Any] = subprocess.run,
    clock: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
    snapshot_wall_clock_ns: Callable[[], int] = time.time_ns,
    stability_age_ns: int = DEFAULT_STABILITY_AGE_NS,
    image_repairer: Callable[[Path], None] = _repair_fat32_image,
    filesystem_stats: Callable[[Path], Any] = os.statvfs,
    installation_validator: Callable[[], None] = _validate_nbdkit_installation,
  ):
    self.snapshot_builder = SnapshotBuilder(
      source,
      snapshot,
      wall_clock_ns=snapshot_wall_clock_ns,
      stability_age_ns=stability_age_ns,
    )
    self.mount = Path(mount)
    self.lun = Path(lun)
    self.udc_state = Path(udc_state)
    self.gadget_lock = Path(gadget_lock)
    self.gadget_helper = Path(gadget_helper)
    if not self.mount.is_absolute() or not self.lun.is_absolute() or not self.udc_state.is_absolute():
      raise StorageError("mount, LUN, and UDC state paths must be absolute")
    if self.mount.name != MANAGED_MOUNT_NAME or self.mount.parent.name != MANAGED_MOUNT_DIRECTORY:
      raise StorageError(f"refusing unmanaged FUSE path (expected .../{MANAGED_MOUNT_DIRECTORY}/{MANAGED_MOUNT_NAME})")
    if self.lun.name != "file" or self.lun.parent.name != "lun.0":
      raise StorageError("refusing unexpected configfs LUN path")
    if not self.gadget_lock.is_absolute():
      raise StorageError("gadget lock path must be absolute")
    if not self.gadget_helper.is_absolute():
      raise StorageError("gadget helper path must be absolute")
    if min(ready_timeout, stop_timeout, poll_interval, idle_poll_interval) <= 0:
      raise StorageError("timeouts and poll interval must be positive")

    self.ready_timeout = ready_timeout
    self.stop_timeout = stop_timeout
    self.poll_interval = poll_interval
    self.idle_poll_interval = idle_poll_interval
    self.process_factory = process_factory
    self.command_runner = command_runner
    self.clock = clock
    self.sleep = sleep
    self.image_repairer = image_repairer
    self.filesystem_stats = filesystem_stats
    self.installation_validator = installation_validator
    self.installation_validated = False
    # Directory/filename mode mounts FUSE over mount.parent, hiding everything
    # in it. Keep readiness state next to (not inside) that mount directory.
    self.pidfile = self.mount.parent.with_suffix(".pid")
    self.process: Any | None = None
    self.export_started = False
    self.forced_unbound = False

  @contextmanager
  def _gadget_locked(self) -> Iterator[None]:
    flags = os.O_RDWR | os.O_CREAT | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
      flags |= os.O_NOFOLLOW
    descriptor = os.open(self.gadget_lock, flags, 0o600)
    try:
      if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        raise StorageError("gadget lock is not a regular file")
      fcntl.flock(descriptor, fcntl.LOCK_EX)
      yield
    finally:
      fcntl.flock(descriptor, fcntl.LOCK_UN)
      os.close(descriptor)

  def _open_lun(self, flags: int) -> int:
    if hasattr(os, "O_NOFOLLOW"):
      flags |= os.O_NOFOLLOW
    try:
      metadata = self.lun.lstat()
    except FileNotFoundError as exc:
      raise LunUnavailableError("configfs LUN file does not exist") from exc
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
      raise StorageError("configfs LUN path is not a regular file")
    return os.open(self.lun, flags | os.O_CLOEXEC)

  def _read_lun_unlocked(self) -> str:
    descriptor = self._open_lun(os.O_RDONLY)
    try:
      return os.read(descriptor, 4096).decode("utf-8", errors="strict").strip()
    finally:
      os.close(descriptor)

  def _write_lun_unlocked(self, value: str) -> None:
    descriptor = self._open_lun(os.O_WRONLY | os.O_TRUNC)
    try:
      data = f"{value}\n".encode()
      if os.write(descriptor, data) != len(data):
        raise StorageError("short write to configfs LUN")
    finally:
      os.close(descriptor)

  def _read_lun(self) -> str:
    with self._gadget_locked():
      return self._read_lun_unlocked()

  def _validate_lun_policy_unlocked(self) -> None:
    for attribute in ("ro", "removable"):
      attribute_path = self.lun.parent / attribute
      flags = os.O_RDONLY | os.O_CLOEXEC
      if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
      try:
        metadata = attribute_path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
          raise StorageError(f"USB LUN {attribute} attribute is not a regular file")
        descriptor = os.open(attribute_path, flags)
      except FileNotFoundError as exc:
        raise LunUnavailableError(f"USB LUN {attribute} attribute does not exist") from exc
      try:
        if os.read(descriptor, 32).decode("ascii", errors="strict").strip() != "1":
          raise StorageError(f"refusing USB LUN with {attribute}=0")
      finally:
        os.close(descriptor)

  def _set_lun(self) -> None:
    with self._gadget_locked():
      self._validate_lun_policy_unlocked()
      current = self._read_lun_unlocked()
      if current not in ("", str(self.mount)):
        raise StorageError(f"LUN is owned by another backing file: {current}")
      self._write_lun_unlocked(str(self.mount))
      if self._read_lun_unlocked() != str(self.mount):
        raise StorageError("configfs LUN did not retain the requested backing file")
      self._validate_lun_policy_unlocked()

  def _clear_lun(self) -> None:
    deadline = self.clock() + self.stop_timeout
    while True:
      try:
        with self._gadget_locked():
          current = self._read_lun_unlocked()
          if current == str(self.mount):
            self._write_lun_unlocked("")
            if self._read_lun_unlocked() == "":
              return
          elif current:
            # Never clear a backing file installed by a different manager.
            raise ForeignLunError(f"LUN is owned by another backing file: {current}")
          else:
            return
      except LunUnavailableError:
        # Configfs may disappear after UDC teardown. With no LUN attribute,
        # nothing can still hold our FUSE file as a mass-storage backing file.
        return
      except OSError as exc:
        if exc.errno not in (errno.EAGAIN, errno.EBUSY):
          raise
      if self.clock() >= deadline:
        raise LunBusyError("timed out releasing the configfs LUN")
      self.sleep(self.poll_interval)

  def _read_udc_state(self) -> str:
    try:
      metadata = self.udc_state.lstat()
      if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise StorageError("UDC state path is not a regular file")
      return self.udc_state.read_text().strip().lower()
    except FileNotFoundError as exc:
      raise UdcUnavailableError("UDC state is not available") from exc
    except OSError as exc:
      raise StorageError(f"cannot read UDC state: {exc}") from exc

  def _ensure_child_running(self) -> None:
    if self.process is None:
      raise StorageError("nbdfuse was not started")
    return_code = self.process.poll()
    if return_code is not None:
      raise StorageError(f"nbdfuse exited unexpectedly with status {return_code}")

  def _prepare_mount(self) -> None:
    if not self.mount.parent.exists():
      self.mount.parent.mkdir(parents=True, mode=0o700)
    parent_metadata = self.mount.parent.lstat()
    if not stat.S_ISDIR(parent_metadata.st_mode) or stat.S_ISLNK(parent_metadata.st_mode):
      raise StorageError("nbdfuse mount parent is not a real directory")
    if os.path.ismount(self.mount.parent):
      raise StorageError("refusing to replace an active nbdfuse mount")
    try:
      mount_metadata = self.mount.lstat()
    except FileNotFoundError:
      pass
    else:
      if not stat.S_ISREG(mount_metadata.st_mode) or stat.S_ISLNK(mount_metadata.st_mode):
        raise StorageError("nbdfuse output path is not a safe stale file")
      # nbdfuse creates this virtual file. A regular file visible while the
      # parent is not mounted is a stale, exactly scoped artifact.
      self.mount.unlink()
    try:
      pid_metadata = self.pidfile.lstat()
    except FileNotFoundError:
      pass
    else:
      if not stat.S_ISREG(pid_metadata.st_mode) or stat.S_ISLNK(pid_metadata.st_mode):
        raise StorageError("nbdfuse pidfile path is unsafe")
      self.pidfile.unlink()

  def _start_export(self) -> None:
    if not self.installation_validated:
      self.installation_validator()
      self.installation_validated = True
    self._prepare_mount()
    disk_size, size_argument = _nbdkit_layout(self.snapshot_builder.snapshot)
    command = [
      "/usr/bin/nbdfuse",
      "-P",
      str(self.pidfile),
      str(self.mount),
      "--command",
      "/usr/bin/nbdkit",
      "-s",
      "--exit-with-parent",
      "--filter=cow",
      "floppy",
      f"dir={self.snapshot_builder.snapshot}",
      "label=COMMA",
    ]
    if size_argument is not None:
      command.append(f"size={size_argument}")
    environment = os.environ.copy()
    # nbdkit-cow creates an unlinked sparse overlay. Keep its few repaired
    # blocks on userdata rather than AGNOS's 128 MiB /var tmpfs.
    environment["TMPDIR"] = str(self.snapshot_builder.snapshot.parent)
    self.process = self.process_factory(command, close_fds=True, env=environment)
    self.export_started = True

    deadline = self.clock() + self.ready_timeout
    while self.clock() < deadline:
      self._ensure_child_running()
      try:
        pid_text = self.pidfile.read_text().strip()
        mount_metadata = self.mount.lstat()
        ready = int(pid_text) == self.process.pid and stat.S_ISREG(mount_metadata.st_mode) and not stat.S_ISLNK(mount_metadata.st_mode)
        ready = ready and mount_metadata.st_size == disk_size
      except (FileNotFoundError, OSError, ValueError):
        ready = False
      if ready:
        self.image_repairer(self.mount)
        return
      self.sleep(self.poll_interval)
    raise StorageError("timed out waiting for nbdfuse readiness")

  def _wait_for_configured(self, stop_event: threading.Event) -> bool:
    while not stop_event.is_set():
      try:
        if self._read_udc_state() in self.CONFIGURED_UDC_STATES:
          return True
      except UdcUnavailableError:
        # The UDC may appear after this boot service starts.
        pass
      self.sleep(self.idle_poll_interval)
    return False

  def _wait_for_source_while_attached(self, stop_event: threading.Event) -> bool:
    while not stop_event.is_set():
      try:
        state = self._read_udc_state()
      except UdcUnavailableError:
        return False
      if state in self.DISCONNECTED_UDC_STATES:
        return False
      if state in self.CONFIGURED_UDC_STATES and self.snapshot_builder.source_is_ready() and self._has_export_capacity():
        return True
      self.sleep(self.idle_poll_interval)
    return False

  def _has_export_capacity(self) -> bool:
    try:
      filesystem = self.filesystem_stats(self.snapshot_builder.source)
      if filesystem.f_blocks <= 0 or filesystem.f_frsize <= 0:
        return False
      available_bytes = filesystem.f_bavail * filesystem.f_frsize
      available_percent = 100.0 * filesystem.f_bavail / filesystem.f_blocks
      return available_bytes > MIN_FREE_BYTES and available_percent > MIN_FREE_PERCENT
    except OSError:
      return False

  def _wait_for_physical_detach(
    self,
    stop_event: threading.Event,
    *,
    require_reconfigured: bool = False,
  ) -> bool:
    detached_since: float | None = None
    reconfigured = not require_reconfigured
    while not stop_event.is_set():
      try:
        state = self._read_udc_state()
        detached = state in self.DISCONNECTED_UDC_STATES
      except UdcUnavailableError:
        # A disappearing UDC is also a physical/configfs detachment.
        state = None
        detached = True

      now = self.clock()
      if not reconfigured:
        # When teardown had to unbind and reconstruct the gadget, even a long
        # "not attached" interval may only be slow host re-enumeration. Arm
        # physical-detach detection only after that rebind reaches a configured
        # state; the next stable disconnect is then unambiguous.
        reconfigured = state in self.CONFIGURED_UDC_STATES
        detached_since = None
      elif detached:
        if detached_since is None:
          detached_since = now
        elif now - detached_since >= PHYSICAL_DETACH_DEBOUNCE_SECONDS:
          return True
      else:
        detached_since = None
      self.sleep(self.idle_poll_interval)
    return False

  def monitor(self, stop_event: threading.Event) -> SessionEnd:
    while not stop_event.is_set():
      self._ensure_child_running()
      try:
        lun = self._read_lun()
      except LunUnavailableError:
        return SessionEnd.DETACHED
      if lun != str(self.mount):
        return SessionEnd.EJECTED
      try:
        state = self._read_udc_state()
      except UdcUnavailableError:
        return SessionEnd.DETACHED
      if state in self.DISCONNECTED_UDC_STATES:
        return SessionEnd.DETACHED
      if not self._has_export_capacity():
        return SessionEnd.LOW_SPACE
      self.sleep(self.poll_interval)
    return SessionEnd.STOPPED

  def _run_gadget_helper(self, action: str) -> None:
    if action not in ("unbind", "ensure-requested-personality"):
      raise StorageError(f"invalid gadget helper action: {action}")
    # usb_gadget.sh takes the shared flock itself. Never invoke it from within
    # _gadget_locked(), or both processes would deadlock.
    result = self.command_runner(
      [str(self.gadget_helper), action],
      check=False,
      timeout=self.stop_timeout,
    )
    if getattr(result, "returncode", 0) != 0:
      raise StorageError(f"gadget helper {action} failed with status {result.returncode}")

  def _release_lun_with_fallback(self) -> None:
    try:
      self._clear_lun()
    except LunBusyError:
      LOG.warning("host prevented media removal; forcing a bounded UDC unbind")
      self._run_gadget_helper("unbind")
      self.forced_unbound = True
      self._clear_lun()

  def _unmount(self) -> None:
    if not self.export_started:
      return
    result = self.command_runner(
      ["/usr/bin/fusermount3", "-u", str(self.mount.parent)],
      check=False,
      timeout=self.stop_timeout,
    )
    if getattr(result, "returncode", 0) != 0:
      raise StorageError(f"fusermount3 failed with status {result.returncode}")

  def _stop_child(self) -> None:
    if self.process is None:
      return
    process = self.process
    try:
      process.wait(timeout=self.stop_timeout)
    except subprocess.TimeoutExpired:
      process.terminate()
      try:
        process.wait(timeout=self.stop_timeout)
      except subprocess.TimeoutExpired:
        process.kill()
        try:
          process.wait(timeout=self.stop_timeout)
        except subprocess.TimeoutExpired as exc:
          raise StorageError("nbdfuse did not stop after SIGKILL") from exc
    self.process = None
    self.export_started = False
    try:
      self.pidfile.unlink()
    except FileNotFoundError:
      pass

  def teardown(self, *, rebind: bool = True) -> bool:
    """Release session state and report whether the gadget was self-rebound."""
    # This order is a safety invariant: configfs must release the backing file
    # before FUSE disappears, and the hard-link namespace must outlive nbdkit.
    try:
      self._release_lun_with_fallback()
    except BaseException as exc:
      # If configfs still owns our path, tearing down FUSE would leave the USB
      # function backed by a disappearing file. Keep the read-only export and
      # snapshot alive; UDC orchestration can unbind and retry this service.
      raise StorageError("refusing to tear down an attached LUN") from exc
    # Each operation is intentionally gated on the previous one succeeding.
    # A failed unmount or child stop leaves all later backing state intact.
    self._unmount()
    self._stop_child()
    self.snapshot_builder.cleanup()

    if self.forced_unbound and rebind:
      # Another serialized gadget transition may have failed after changing
      # descriptors or links while this manager was cleaning up. Reconstruct
      # the complete requested personality rather than raw-binding whatever
      # partial configfs state happens to remain.
      self._run_gadget_helper("ensure-requested-personality")
      self.forced_unbound = False
      return True
    return False

  def run(self, stop_event: threading.Event) -> int:
    completed_sessions = 0
    # Recover a stale configfs reference before accepting any host. This never
    # scans or pins realdata and may safely force an unbind if PREVENT is stale.
    self._release_lun_with_fallback()
    # ExecStartPre attempts a lazy stale unmount, but its failure is ignored so
    # boot can proceed. Verify it is truly gone and remove only our exact stale
    # virtual-file and pid artifacts before deleting the snapshot they used.
    self._prepare_mount()
    self.snapshot_builder.cleanup()
    if self.forced_unbound:
      self._run_gadget_helper("ensure-requested-personality")
      self.forced_unbound = False

    while self._wait_for_configured(stop_event):
      if not self._wait_for_source_while_attached(stop_event):
        continue

      snapshot: SnapshotResult | None = None
      end = SessionEnd.DETACHED
      media_attached = False
      failure: Exception | None = None
      self_rebound = False
      try:
        snapshot = self.snapshot_builder.build()
        if stop_event.is_set():
          end = SessionEnd.STOPPED
        elif self._read_udc_state() not in self.CONFIGURED_UDC_STATES:
          end = SessionEnd.DETACHED
        else:
          self._start_export()
          self._set_lun()
          media_attached = True
          end = self.monitor(stop_event)
      except Exception as exc:
        failure = exc
        LOG.exception("USB storage session failed safely; waiting for physical detach before retry")
      finally:
        try:
          self_rebound = self.teardown(rebind=not stop_event.is_set())
        except BaseException as teardown_failure:
          if failure is None:
            raise
          LOG.exception("teardown also failed after storage session error")
          # An incomplete teardown may leave configfs referencing the export.
          # Exit so systemd's stop wrapper can force the gadget safe instead
          # of continuing with uncertain backing-file ownership.
          raise teardown_failure from failure

      if failure is not None:
        if not self._wait_for_physical_detach(stop_event, require_reconfigured=self_rebound):
          break
        continue

      if media_attached and snapshot is not None:
        completed_sessions += 1
        LOG.info(
          "session %s: exported %d segments, excluded %d",
          end,
          len(snapshot.included),
          len(snapshot.excluded),
        )
        for segment, reason in snapshot.excluded:
          LOG.warning("excluded %s: %s", segment, reason)

      if stop_event.is_set() or end == SessionEnd.STOPPED:
        break
      if end in (SessionEnd.EJECTED, SessionEnd.LOW_SPACE) and not self._wait_for_physical_detach(stop_event):
        break

    return completed_sessions


def _build_parser() -> argparse.ArgumentParser:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--source", default="/data/media/0/realdata")
  parser.add_argument("--snapshot", default="/data/tmp/usb-storage-snapshot")
  parser.add_argument("--mount", default="/run/usb-storage/footage.img")
  parser.add_argument(
    "--lun",
    default="/config/usb_gadget/g1/functions/mass_storage.0/lun.0/file",
  )
  parser.add_argument("--udc-state", default="/sys/class/udc/a600000.dwc3/state")
  parser.add_argument("--gadget-lock", default="/run/lock/comma-usb-gadget.lock")
  parser.add_argument("--gadget-helper", default="/usr/comma/usb_gadget.sh")
  parser.add_argument("--ready-timeout", type=float, default=20.0)
  parser.add_argument("--stop-timeout", type=float, default=5.0)
  parser.add_argument("--idle-poll-interval", type=float, default=1.0)
  return parser


def main(argv: Sequence[str] | None = None) -> int:
  logging.basicConfig(level=logging.INFO, format="%(name)s: %(levelname)s: %(message)s")
  arguments = _build_parser().parse_args(argv)
  stop_event = threading.Event()

  def request_stop(_signal_number: int, _frame: Any) -> None:
    stop_event.set()

  previous_handlers = {handled_signal: signal.signal(handled_signal, request_stop) for handled_signal in (signal.SIGINT, signal.SIGTERM)}
  try:
    manager = StorageManager(
      source=arguments.source,
      snapshot=arguments.snapshot,
      mount=arguments.mount,
      lun=arguments.lun,
      udc_state=arguments.udc_state,
      gadget_lock=arguments.gadget_lock,
      gadget_helper=arguments.gadget_helper,
      ready_timeout=arguments.ready_timeout,
      stop_timeout=arguments.stop_timeout,
      idle_poll_interval=arguments.idle_poll_interval,
    )
    completed_sessions = manager.run(stop_event)
    LOG.info("stopped after %d completed storage sessions", completed_sessions)
    return 0
  except StorageError:
    LOG.exception("USB storage session failed safely")
    return 1
  finally:
    for handled_signal, previous_handler in previous_handlers.items():
      signal.signal(handled_signal, previous_handler)


if __name__ == "__main__":
  raise SystemExit(main())
