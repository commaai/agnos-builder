#!/usr/bin/env python3

from __future__ import annotations

import errno
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest  # noqa: TID251 - these tests intentionally use only the standard library


COMMA_DIR = Path(__file__).parents[1] / "root" / "usr" / "comma"
sys.path.insert(0, str(COMMA_DIR))

import usb_storage  # noqa: E402, RUF100


class SnapshotBuilderTest(unittest.TestCase):
  def setUp(self) -> None:
    self.temporary_directory = tempfile.TemporaryDirectory()
    self.root = Path(self.temporary_directory.name)
    self.source = self.root / "realdata"
    self.source.mkdir()
    self.snapshot = self.root / usb_storage.MANAGED_SNAPSHOT_NAME
    self.snapshot_time_ns = time.time_ns() + (3 * usb_storage.DEFAULT_STABILITY_AGE_NS)

  def tearDown(self) -> None:
    # Snapshot directories intentionally become read-only. Builder cleanup also
    # exercises the guarded permission restoration used on the device.
    if self.snapshot.exists():
      usb_storage.SnapshotBuilder(self.source, self.snapshot).cleanup()
    self.temporary_directory.cleanup()

  def make_segment(self, name: str) -> Path:
    segment = self.source / name
    segment.mkdir(parents=True)
    return segment

  def builder(self) -> usb_storage.SnapshotBuilder:
    return usb_storage.SnapshotBuilder(
      self.source,
      self.snapshot,
      wall_clock_ns=lambda: self.snapshot_time_ns,
    )

  def test_snapshot_is_hard_link_and_survives_original_unlink(self) -> None:
    segment = self.make_segment("00000001--abc123def0--0")
    (segment / "nested").mkdir()
    original = segment / "nested" / "fcamera.hevc"
    original.write_bytes(b"finished footage")

    result = self.builder().build()
    linked = self.snapshot / segment.name / "nested" / original.name

    self.assertEqual(result.included, (segment.name,))
    self.assertEqual(result.excluded, ())
    self.assertEqual(original.stat().st_ino, linked.stat().st_ino)
    self.assertEqual(original.stat().st_dev, linked.stat().st_dev)
    self.assertFalse(stat.S_IMODE(self.snapshot.stat().st_mode) & stat.S_IWUSR)

    original.unlink()
    self.assertEqual(linked.read_bytes(), b"finished footage")

  def test_active_lock_excludes_entire_segment(self) -> None:
    finished = self.make_segment("00000001--abc123def0--0")
    (finished / "rlog.zst").write_bytes(b"done")
    active = self.make_segment("00000001--abc123def0--1")
    (active / "fcamera.hevc").write_bytes(b"partial")
    (active / "rlog.lock").touch()

    result = self.builder().build()

    self.assertEqual(result.included, (finished.name,))
    self.assertEqual(result.excluded[0][0], active.name)
    self.assertIn("active lock", result.excluded[0][1])
    self.assertFalse((self.snapshot / active.name).exists())

  def test_symlink_oversize_and_nonregular_trees_are_excluded(self) -> None:
    symlink_segment = self.make_segment("00000001--abc123def0--0")
    target = self.root / "private"
    target.write_text("must not leak")
    (symlink_segment / "camera").symlink_to(target)

    oversize_segment = self.make_segment("00000001--abc123def0--1")
    with (oversize_segment / "fcamera.hevc").open("wb") as oversized:
      oversized.truncate(usb_storage.MAX_FAT_FILE_SIZE)

    fifo_segment = self.make_segment("00000001--abc123def0--2")
    os.mkfifo(fifo_segment / "unexpected.pipe")

    result = self.builder().build()
    reasons = dict(result.excluded)

    self.assertEqual(result.included, ())
    self.assertIn("symbolic link", reasons[symlink_segment.name])
    self.assertIn("too large", reasons[oversize_segment.name])
    self.assertIn("non-regular", reasons[fifo_segment.name])
    self.assertEqual(list(self.snapshot.iterdir()), [])

  def test_empty_file_excludes_entire_segment(self) -> None:
    segment = self.make_segment("00000001--abc123def0--0")
    (segment / "rlog.zst").write_bytes(b"complete log")
    (segment / "empty.hevc").touch()

    result = self.builder().build()

    self.assertEqual(result.included, ())
    self.assertIn("empty file unsupported", result.excluded[0][1])
    self.assertFalse((self.snapshot / segment.name).exists())

  def test_unrelated_and_nested_directories_are_ignored(self) -> None:
    route = self.source / "dongle|2026-08-22--12-00-00"
    nested = route / "0"
    nested.mkdir(parents=True)
    (nested / "qlog.zst").write_bytes(b"must not export")
    unrelated = self.source / "boot"
    unrelated.mkdir()
    (unrelated / "bootlog.zst").write_bytes(b"must not export")

    result = self.builder().build()

    self.assertEqual(result.included, ())
    self.assertEqual(result.excluded, ())
    self.assertEqual(list(self.snapshot.iterdir()), [])

  def test_windows_and_vfat_unsafe_names_are_rejected(self) -> None:
    unsafe_names = (
      "bad?.hevc",
      "bad<name",
      "trailing.",
      "trailing ",
      "CON",
      "con.txt",
      "COM9.log",
      "LPT1",
      "control\x01name",
      "delete\x7fname",
      "control\x85name",
      "a" * 256,
      "😀" * 128,
      "invalid-surrogate-\udcff",
    )
    for name in unsafe_names:
      with self.subTest(name=repr(name)):
        with self.assertRaises(usb_storage.UnsafeTreeError):
          usb_storage._validate_portable_name(name)

    for name in ("fcamera.hevc", "00000001--abc123def0--0", "café.txt"):
      with self.subTest(valid_name=name):
        usb_storage._validate_portable_name(name)

  def test_unsafe_component_excludes_entire_segment(self) -> None:
    segment = self.make_segment("00000001--abc123def0--0")
    (segment / "CON.txt").write_bytes(b"reserved name")

    result = self.builder().build()

    self.assertEqual(result.included, ())
    self.assertIn("reserved DOS", result.excluded[0][1])
    self.assertFalse((self.snapshot / segment.name).exists())

  def test_unrecognized_top_level_segment_name_is_ignored(self) -> None:
    segment = self.make_segment("bad:route--0")
    (segment / "rlog.zst").write_bytes(b"data")

    result = self.builder().build()

    self.assertEqual(result.included, ())
    self.assertEqual(result.excluded, ())

  def test_legacy_route_separator_is_exported_with_portable_name(self) -> None:
    segment = self.make_segment("a2a0ccea32023010|2026-08-23--12-34-56--0")
    (segment / "rlog.zst").write_bytes(b"legacy route")

    result = self.builder().build()
    portable_name = segment.name.replace("|", "_")

    self.assertEqual(result.included, (portable_name,))
    self.assertEqual((self.snapshot / portable_name / "rlog.zst").read_bytes(), b"legacy route")
    self.assertFalse((self.snapshot / segment.name).exists())

  def test_portable_segment_name_collision_excludes_both_sources(self) -> None:
    legacy = self.make_segment("a2a0ccea32023010|2026-08-23--12-34-56--0")
    alternate = self.make_segment("a2a0ccea32023010_2026-08-23--12-34-56--0")
    (legacy / "rlog.zst").write_bytes(b"legacy")
    (alternate / "rlog.zst").write_bytes(b"alternate")

    result = self.builder().build()

    self.assertEqual(result.included, ())
    self.assertEqual({name for name, _reason in result.excluded}, {legacy.name, alternate.name})
    self.assertTrue(all("collides" in reason for _name, reason in result.excluded))
    self.assertEqual(list(self.snapshot.iterdir()), [])

  def test_just_unlocked_segment_is_excluded_until_stability_age(self) -> None:
    now_ns = time.time_ns()
    recent = self.make_segment("00000001--abc123def0--0")
    (recent / "rlog.zst").write_bytes(b"final compressed bytes")
    lock = recent / "rlog.lock"
    lock.touch()
    lock.unlink()

    aged = self.make_segment("00000001--abc123def0--1")
    aged_file = aged / "rlog.zst"
    aged_file.write_bytes(b"stable bytes")
    aged_mtime_ns = now_ns - usb_storage.DEFAULT_STABILITY_AGE_NS - 1
    os.utime(aged_file, ns=(aged_mtime_ns, aged_mtime_ns))
    os.utime(aged, ns=(aged_mtime_ns, aged_mtime_ns))

    recent_file = self.make_segment("00000001--abc123def0--2")
    (recent_file / "rlog.zst").write_bytes(b"still flushing")
    os.utime(recent_file, ns=(aged_mtime_ns, aged_mtime_ns))

    result = usb_storage.SnapshotBuilder(
      self.source,
      self.snapshot,
      wall_clock_ns=lambda: now_ns,
    ).build()
    reasons = dict(result.excluded)

    self.assertEqual(result.included, (aged.name,))
    self.assertIn("too recent", reasons[recent.name])
    self.assertIn("too recent", reasons[recent_file.name])
    self.assertFalse((self.snapshot / recent.name).exists())
    self.assertTrue((self.snapshot / aged.name / "rlog.zst").is_file())

  def test_refuses_any_broad_or_unmanaged_cleanup_destination(self) -> None:
    for unsafe in (self.root, self.source, self.root / "some-other-name"):
      with self.subTest(unsafe=unsafe):
        with self.assertRaises(usb_storage.StorageError):
          usb_storage.SnapshotBuilder(self.source, unsafe)

  def test_refuses_symlink_at_managed_destination(self) -> None:
    victim = self.root / "victim"
    victim.mkdir()
    self.snapshot.symlink_to(victim, target_is_directory=True)

    with self.assertRaises(usb_storage.StorageError):
      usb_storage.SnapshotBuilder(self.source, self.snapshot).build()
    self.assertTrue(victim.is_dir())
    self.snapshot.unlink()

  def test_source_replaced_by_symlink_after_start_is_refused(self) -> None:
    builder = self.builder()
    original = self.root / "original-realdata"
    self.source.rename(original)
    self.source.symlink_to(original, target_is_directory=True)

    with self.assertRaisesRegex(usb_storage.StorageError, "symbolic link"):
      builder.build()

    self.source.unlink()
    original.rename(self.source)

  def test_snapshot_parent_redirect_after_start_is_refused(self) -> None:
    snapshot_parent = self.root / "snapshot-parent"
    snapshot_parent.mkdir()
    requested_snapshot = snapshot_parent / usb_storage.MANAGED_SNAPSHOT_NAME
    builder = usb_storage.SnapshotBuilder(self.source, requested_snapshot)
    original_parent = self.root / "original-snapshot-parent"
    replacement_parent = self.root / "replacement-snapshot-parent"
    replacement_parent.mkdir()
    snapshot_parent.rename(original_parent)
    snapshot_parent.symlink_to(replacement_parent, target_is_directory=True)

    with self.assertRaisesRegex(usb_storage.StorageError, "real directory|resolution changed"):
      builder.cleanup()

    snapshot_parent.unlink()
    original_parent.rename(snapshot_parent)


def make_nbdkit_fat32_image(path: Path) -> tuple[int, int]:
  image_size = usb_storage.MIN_COMPATIBLE_DISK_SIZE
  partition_lba = 2048
  partition_sectors = (image_size // usb_storage.SECTOR_SIZE) - partition_lba
  total_clusters = image_size // usb_storage.FAT_CLUSTER_SIZE
  fat_clusters = (total_clusters - 63 + 4095) // 4096
  sectors_per_fat = fat_clusters * (usb_storage.FAT_CLUSTER_SIZE // usb_storage.SECTOR_SIZE)
  partition_offset = partition_lba * usb_storage.SECTOR_SIZE
  data_offset = partition_offset + (32 + 2 * sectors_per_fat) * usb_storage.SECTOR_SIZE

  mbr = bytearray(usb_storage.SECTOR_SIZE)
  mbr[446 + 4] = 0x0C
  struct.pack_into("<II", mbr, 446 + 8, partition_lba, partition_sectors)
  mbr[510:512] = b"\x55\xaa"

  boot = bytearray(usb_storage.SECTOR_SIZE)
  boot[3:11] = b"MSWIN4.1"
  struct.pack_into("<H", boot, 11, usb_storage.SECTOR_SIZE)
  boot[13] = usb_storage.FAT_CLUSTER_SIZE // usb_storage.SECTOR_SIZE
  struct.pack_into("<H", boot, 14, 32)
  boot[16] = 2
  boot[21] = 0xF8
  struct.pack_into("<I", boot, 32, partition_sectors)
  struct.pack_into("<I", boot, 36, sectors_per_fat)
  struct.pack_into("<I", boot, 44, 2)
  struct.pack_into("<H", boot, 48, 1)
  struct.pack_into("<H", boot, 50, 6)
  boot[66] = 0x29
  boot[71:82] = b"COMMA      "
  boot[82:90] = b"FAT32   "
  boot[510:512] = b"\x55\xaa"

  fat = bytearray(usb_storage.FAT_CLUSTER_SIZE)
  for cluster, value in enumerate((0x0FFFFFF8, 0xFFFFFFFF, 0x0FFFFFFF, 0x0FFFFFFF, 0x0FFFFFFF)):
    struct.pack_into("<I", fat, cluster * 4, value)

  root = bytearray(usb_storage.FAT_CLUSTER_SIZE)
  root[0:11] = b"COMMA      "
  root[11] = 0x08
  root[32:43] = b"SEGMENT    "
  root[43] = 0x10
  struct.pack_into("<H", root, 32 + 26, 3)

  child = bytearray(usb_storage.FAT_CLUSTER_SIZE)
  child[0:11] = b".          "
  child[11] = 0x10
  struct.pack_into("<H", child, 26, 3)
  child[32:43] = b"..         "
  child[43] = 0x10
  struct.pack_into("<H", child, 32 + 26, 2)
  child[64:75] = b"NESTED     "
  child[75] = 0x10
  struct.pack_into("<H", child, 64 + 26, 4)

  nested = bytearray(usb_storage.FAT_CLUSTER_SIZE)
  nested[0:11] = b".          "
  nested[11] = 0x10
  struct.pack_into("<H", nested, 26, 4)
  nested[32:43] = b"..         "
  nested[43] = 0x10
  struct.pack_into("<H", nested, 32 + 26, 3)

  with path.open("wb") as image:
    image.truncate(image_size)
    for offset, data in (
      (0, mbr),
      (partition_offset, boot),
      (partition_offset + 6 * usb_storage.SECTOR_SIZE, boot),
      (partition_offset + 32 * usb_storage.SECTOR_SIZE, fat),
      (partition_offset + (32 + sectors_per_fat) * usb_storage.SECTOR_SIZE, fat),
      (data_offset, root),
      (data_offset + usb_storage.FAT_CLUSTER_SIZE, child),
      (data_offset + 2 * usb_storage.FAT_CLUSTER_SIZE, nested),
    ):
      image.seek(offset)
      image.write(data)
  return partition_offset, data_offset


class Fat32CompatibilityTest(unittest.TestCase):
  def setUp(self) -> None:
    self.temporary_directory = tempfile.TemporaryDirectory()
    self.root = Path(self.temporary_directory.name)

  def tearDown(self) -> None:
    self.temporary_directory.cleanup()

  def test_layout_pads_small_fat32_and_uses_natural_large_size(self) -> None:
    self.assertEqual(
      usb_storage._nbdkit_layout(self.root),
      (usb_storage.MIN_COMPATIBLE_DISK_SIZE, usb_storage.MIN_COMPATIBLE_DISK_SIZE),
    )

    boundary = self.root / "boundary.bin"
    with boundary.open("wb") as sparse_file:
      # The root directory consumes one cluster, so this puts the complete
      # snapshot one cluster below the conservative FAT32 boundary.
      sparse_file.truncate((usb_storage.FAT32_COMPATIBLE_DATA_CLUSTERS - 2) * usb_storage.FAT_CLUSTER_SIZE)
    self.assertEqual(
      usb_storage._nbdkit_layout(self.root),
      (usb_storage.MIN_COMPATIBLE_DISK_SIZE, usb_storage.MIN_COMPATIBLE_DISK_SIZE),
    )

    with boundary.open("wb") as sparse_file:
      sparse_file.truncate((usb_storage.FAT32_COMPATIBLE_DATA_CLUSTERS - 1) * usb_storage.FAT_CLUSTER_SIZE)
    boundary_size, boundary_argument = usb_storage._nbdkit_layout(self.root)
    boundary_fat_clusters = (usb_storage.FAT32_COMPATIBLE_DATA_CLUSTERS + 2 + 4095) // 4096
    self.assertIsNone(boundary_argument)
    self.assertEqual(
      boundary_size,
      (65 + 2 * boundary_fat_clusters + usb_storage.FAT32_COMPATIBLE_DATA_CLUSTERS) * usb_storage.FAT_CLUSTER_SIZE,
    )

    large = self.root / "large.hevc"
    boundary.unlink()
    with large.open("wb") as sparse_file:
      sparse_file.truncate(3 * 1024**3)
    used_clusters = usb_storage._snapshot_fat_data_size(self.root) // usb_storage.FAT_CLUSTER_SIZE
    disk_size, size_argument = usb_storage._nbdkit_layout(self.root)
    total_clusters = disk_size // usb_storage.FAT_CLUSTER_SIZE
    fat_clusters = (used_clusters + 2 + 4095) // 4096

    self.assertIsNone(size_argument)
    self.assertGreater(disk_size, 3 * 1024**3)
    self.assertEqual(total_clusters - 65 - 2 * fat_clusters, used_clusters)

  def test_layout_rejects_file_truncated_after_snapshot(self) -> None:
    footage = self.root / "rlog.zst"
    footage.write_bytes(b"complete")
    self.assertEqual(
      usb_storage._nbdkit_layout(self.root),
      (usb_storage.MIN_COMPATIBLE_DISK_SIZE, usb_storage.MIN_COMPATIBLE_DISK_SIZE),
    )

    footage.write_bytes(b"")

    with self.assertRaisesRegex(usb_storage.StorageError, "empty file unsupported"):
      usb_storage._nbdkit_layout(self.root)

  def test_repairs_primary_backup_and_root_child_dotdot_idempotently(self) -> None:
    image = self.root / "footage.img"
    partition_offset, data_offset = make_nbdkit_fat32_image(image)

    usb_storage._repair_fat32_image(image)
    usb_storage._repair_fat32_image(image)

    with image.open("rb") as repaired:
      repaired.seek(partition_offset)
      primary = repaired.read(usb_storage.SECTOR_SIZE)
      repaired.seek(partition_offset + 6 * usb_storage.SECTOR_SIZE)
      backup = repaired.read(usb_storage.SECTOR_SIZE)
      repaired.seek(data_offset + usb_storage.FAT_CLUSTER_SIZE + 32)
      dotdot = repaired.read(32)
      repaired.seek(data_offset + 2 * usb_storage.FAT_CLUSTER_SIZE + 32)
      nested_dotdot = repaired.read(32)
    self.assertEqual(primary, backup)
    self.assertEqual(primary[0:3], b"\xeb\x58\x90")
    self.assertEqual(struct.unpack_from("<I", primary, 28)[0], 2048)
    self.assertEqual(primary[64], 0x80)
    self.assertEqual(struct.unpack_from("<H", dotdot, 20)[0], 0)
    self.assertEqual(struct.unpack_from("<H", dotdot, 26)[0], 0)
    self.assertEqual(struct.unpack_from("<H", nested_dotdot, 20)[0], 0)
    self.assertEqual(struct.unpack_from("<H", nested_dotdot, 26)[0], 3)

  def test_invalid_child_is_rejected_before_any_repair_write(self) -> None:
    image = self.root / "footage.img"
    partition_offset, data_offset = make_nbdkit_fat32_image(image)
    with image.open("r+b") as malformed:
      malformed.seek(data_offset + usb_storage.FAT_CLUSTER_SIZE)
      malformed.write(b"X")

    with self.assertRaisesRegex(usb_storage.StorageError, "dot entries"):
      usb_storage._repair_fat32_image(image)

    with image.open("rb") as unchanged:
      unchanged.seek(partition_offset)
      self.assertEqual(unchanged.read(3), bytes(3))


class FakeProcess:
  def __init__(self, *, pid: int = 4242, events: list[str] | None = None):
    self.pid = pid
    self.returncode: int | None = None
    self.events = events if events is not None else []

  def poll(self) -> int | None:
    return self.returncode

  def wait(self, timeout: float | None = None) -> int:
    self.events.append("stop-child")
    if self.returncode is None:
      self.returncode = 0
    return self.returncode

  def terminate(self) -> None:
    self.events.append("terminate-child")
    self.returncode = -15

  def kill(self) -> None:
    self.events.append("kill-child")
    self.returncode = -9


class ManagerTestBase(unittest.TestCase):
  def setUp(self) -> None:
    self.temporary_directory = tempfile.TemporaryDirectory()
    self.root = Path(self.temporary_directory.name)
    self.source = self.root / "realdata"
    self.source.mkdir()
    self.snapshot = self.root / usb_storage.MANAGED_SNAPSHOT_NAME
    self.mount = self.root / "run" / "usb-storage" / "footage.img"
    self.lun = self.root / "config" / "lun.0" / "file"
    self.lun.parent.mkdir(parents=True)
    self.lun.write_text("\n")
    (self.lun.parent / "ro").write_text("1\n")
    (self.lun.parent / "removable").write_text("1\n")
    self.udc_state = self.root / "udc-state"
    self.udc_state.write_text("configured\n")
    self.gadget_lock = self.root / "gadget.lock"

  def tearDown(self) -> None:
    if self.snapshot.exists():
      usb_storage.SnapshotBuilder(self.source, self.snapshot).cleanup()
    self.temporary_directory.cleanup()

  def make_manager(self, **overrides: object) -> usb_storage.StorageManager:
    arguments: dict[str, object] = {
      "source": self.source,
      "snapshot": self.snapshot,
      "mount": self.mount,
      "lun": self.lun,
      "udc_state": self.udc_state,
      "gadget_lock": self.gadget_lock,
    }
    arguments.update(overrides)
    return usb_storage.StorageManager(**arguments)


class StorageManagerTest(ManagerTestBase):
  def test_nbdfuse_command_uses_cow_repair_and_exact_virtual_size(self) -> None:
    captured: list[list[str]] = []
    captured_environment: list[dict[str, str]] = []
    repaired: list[Path] = []

    def process_factory(command: list[str], **kwargs: object) -> FakeProcess:
      captured.append(command)
      captured_environment.append(kwargs["env"])  # type: ignore[arg-type]
      process = FakeProcess()
      self.mount.parent.mkdir(parents=True, exist_ok=True)
      with self.mount.open("wb") as virtual_disk:
        virtual_disk.truncate(usb_storage.MIN_COMPATIBLE_DISK_SIZE)
      (self.mount.parent.with_suffix(".pid")).write_text(str(process.pid))
      return process

    manager = self.make_manager(process_factory=process_factory, image_repairer=repaired.append)
    manager.snapshot_builder.build()
    manager._start_export()

    self.assertEqual(
      captured[0],
      [
        "/usr/bin/nbdfuse",
        "-P",
        str(self.mount.parent.with_suffix(".pid")),
        str(self.mount),
        "--command",
        "/usr/bin/nbdkit",
        "-s",
        "--exit-with-parent",
        "--filter=cow",
        "floppy",
        f"dir={self.snapshot.resolve()}",
        "label=COMMA",
        f"size={usb_storage.MIN_COMPATIBLE_DISK_SIZE}",
      ],
    )
    self.assertEqual(captured_environment[0]["TMPDIR"], str(manager.snapshot_builder.snapshot.parent))
    self.assertEqual(repaired, [self.mount])
    self.assertTrue(manager.export_started)

  def test_nbdfuse_readiness_rejects_empty_or_unaligned_virtual_disk(self) -> None:
    for invalid_size in (0, 513):
      with self.subTest(invalid_size=invalid_size):
        current_time = [0.0]

        def process_factory(_command: list[str], *, size: int = invalid_size, **_kwargs: object) -> FakeProcess:
          process = FakeProcess()
          self.mount.parent.mkdir(parents=True, exist_ok=True)
          with self.mount.open("wb") as virtual_disk:
            virtual_disk.truncate(size)
          self.mount.parent.with_suffix(".pid").write_text(str(process.pid))
          return process

        manager = self.make_manager(
          process_factory=process_factory,
          image_repairer=lambda _path: None,
          ready_timeout=0.2,
          poll_interval=0.1,
          clock=lambda now=current_time: now[0],
          sleep=lambda seconds, now=current_time: now.__setitem__(0, now[0] + seconds),
        )
        manager.snapshot_builder.build()

        with self.assertRaisesRegex(usb_storage.StorageError, "readiness"):
          manager._start_export()

        manager.process = None
        manager.export_started = False
        self.mount.unlink()
        manager.pidfile.unlink()

  def test_lun_writes_require_existing_file_and_preserve_foreign_owner(self) -> None:
    manager = self.make_manager()
    manager._set_lun()
    self.assertEqual(self.lun.read_text().strip(), str(self.mount))

    self.lun.write_text("/some/other/backing.img\n")
    with self.assertRaises(usb_storage.ForeignLunError):
      manager._clear_lun()
    self.assertEqual(self.lun.read_text().strip(), "/some/other/backing.img")
    with self.assertRaises(usb_storage.StorageError):
      manager._set_lun()

    self.lun.unlink()
    with self.assertRaises(usb_storage.StorageError):
      manager._set_lun()
    self.assertFalse(self.lun.exists())

  def test_set_lun_requires_successful_readback(self) -> None:
    class DroppingLunManager(usb_storage.StorageManager):
      def _write_lun_unlocked(inner_self, _value: str) -> None:
        pass

    manager = DroppingLunManager(
      source=self.source,
      snapshot=self.snapshot,
      mount=self.mount,
      lun=self.lun,
      udc_state=self.udc_state,
      gadget_lock=self.gadget_lock,
    )

    with self.assertRaisesRegex(usb_storage.StorageError, "retain"):
      manager._set_lun()

  def test_set_lun_requires_read_only_removable_policy(self) -> None:
    manager = self.make_manager()
    for attribute in ("ro", "removable"):
      with self.subTest(attribute=attribute):
        (self.lun.parent / attribute).write_text("0\n")
        with self.assertRaisesRegex(usb_storage.StorageError, attribute):
          manager._set_lun()
        self.assertEqual(self.lun.read_text().strip(), "")
        (self.lun.parent / attribute).write_text("1\n")

  def test_teardown_order_is_clear_unmount_stop_then_snapshot_remove(self) -> None:
    events: list[str] = []

    class OrderedManager(usb_storage.StorageManager):
      def _clear_lun(inner_self) -> None:
        events.append("clear-lun")
        super()._clear_lun()

    def command_runner(command: list[str], **_kwargs: object) -> types.SimpleNamespace:
      self.assertEqual(command, ["/usr/bin/fusermount3", "-u", str(self.mount.parent)])
      events.append("unmount")
      try:
        self.mount.unlink()
      except FileNotFoundError:
        pass
      return types.SimpleNamespace(returncode=0)

    manager = OrderedManager(
      source=self.source,
      snapshot=self.snapshot,
      mount=self.mount,
      lun=self.lun,
      udc_state=self.udc_state,
      gadget_lock=self.gadget_lock,
      command_runner=command_runner,
    )
    segment = self.source / "00000001--abc123def0--0"
    segment.mkdir()
    (segment / "rlog.zst").write_bytes(b"data")
    manager.snapshot_builder.build()
    original_cleanup = manager.snapshot_builder.cleanup

    def cleanup() -> None:
      events.append("remove-snapshot")
      original_cleanup()

    manager.snapshot_builder.cleanup = cleanup  # type: ignore[method-assign]
    self.mount.parent.mkdir(parents=True)
    self.mount.touch()
    manager.process = FakeProcess(events=events)
    manager.export_started = True
    manager._set_lun()

    manager.teardown()

    self.assertEqual(events, ["clear-lun", "unmount", "stop-child", "remove-snapshot"])
    self.assertEqual(self.lun.read_text().strip(), "")
    self.assertFalse(self.snapshot.exists())

  def test_child_shutdown_escalates_with_finite_timeouts(self) -> None:
    events: list[str] = []

    class StubbornProcess(FakeProcess):
      def wait(self, timeout: float | None = None) -> int:
        events.append("wait")
        if len([event for event in events if event == "wait"]) < 3:
          raise subprocess.TimeoutExpired("nbdfuse", timeout)
        self.returncode = -9
        return self.returncode

      def terminate(self) -> None:
        events.append("terminate")

      def kill(self) -> None:
        events.append("kill")

    manager = self.make_manager(stop_timeout=0.25)
    manager.process = StubbornProcess()
    manager._stop_child()

    self.assertEqual(events, ["wait", "terminate", "wait", "kill", "wait"])

  def test_lun_clear_retries_busy_until_kernel_releases_media(self) -> None:
    current_time = [0.0]

    class BusyManager(usb_storage.StorageManager):
      attempts = 0

      def _write_lun_unlocked(inner_self, value: str) -> None:
        if value == "":
          inner_self.attempts += 1
          if inner_self.attempts < 3:
            raise OSError(errno.EBUSY, "host prevents media removal")
        super()._write_lun_unlocked(value)

    manager = BusyManager(
      source=self.source,
      snapshot=self.snapshot,
      mount=self.mount,
      lun=self.lun,
      udc_state=self.udc_state,
      gadget_lock=self.gadget_lock,
      stop_timeout=1.0,
      poll_interval=0.1,
      clock=lambda: current_time[0],
      sleep=lambda seconds: current_time.__setitem__(0, current_time[0] + seconds),
    )
    self.lun.write_text(f"{self.mount}\n")

    manager._clear_lun()

    self.assertEqual(manager.attempts, 3)
    self.assertEqual(self.lun.read_text().strip(), "")

  def test_teardown_leaves_export_alive_when_lun_cannot_be_cleared(self) -> None:
    events: list[str] = []

    class RefusingManager(usb_storage.StorageManager):
      def _clear_lun(inner_self) -> None:
        events.append("clear-lun")
        raise usb_storage.StorageError("busy")

      def _unmount(inner_self) -> None:
        events.append("unsafe-unmount")

    manager = RefusingManager(
      source=self.source,
      snapshot=self.snapshot,
      mount=self.mount,
      lun=self.lun,
      udc_state=self.udc_state,
      gadget_lock=self.gadget_lock,
    )
    manager.snapshot_builder.build()
    manager.process = FakeProcess(events=events)
    manager.export_started = True

    with self.assertRaisesRegex(usb_storage.StorageError, "attached LUN"):
      manager.teardown()

    self.assertEqual(events, ["clear-lun"])
    self.assertIsNotNone(manager.process)
    self.assertTrue(self.snapshot.exists())

  def test_busy_lun_fallback_preserves_full_teardown_and_rebind_order(self) -> None:
    events: list[str] = []

    class FallbackManager(usb_storage.StorageManager):
      clear_attempts = 0

      def _clear_lun(inner_self) -> None:
        inner_self.clear_attempts += 1
        events.append("clear-lun")
        if inner_self.clear_attempts == 1:
          raise usb_storage.LunBusyError("prevented")

      def _run_gadget_helper(inner_self, action: str) -> None:
        events.append(action)

      def _unmount(inner_self) -> None:
        events.append("unmount")

      def _stop_child(inner_self) -> None:
        events.append("stop-child")
        inner_self.process = None
        inner_self.export_started = False

    manager = FallbackManager(
      source=self.source,
      snapshot=self.snapshot,
      mount=self.mount,
      lun=self.lun,
      udc_state=self.udc_state,
      gadget_lock=self.gadget_lock,
    )
    manager.snapshot_builder.build()
    original_cleanup = manager.snapshot_builder.cleanup

    def cleanup() -> None:
      events.append("remove-snapshot")
      original_cleanup()

    manager.snapshot_builder.cleanup = cleanup  # type: ignore[method-assign]
    manager.process = FakeProcess()
    manager.export_started = True

    manager.teardown()

    self.assertEqual(
      events,
      ["clear-lun", "unbind", "clear-lun", "unmount", "stop-child", "remove-snapshot", "bind"],
    )
    self.assertFalse(manager.forced_unbound)

  def test_nonzero_unmount_is_fail_closed(self) -> None:
    events: list[str] = []

    def failing_unmount(command: list[str], **_kwargs: object) -> types.SimpleNamespace:
      events.append("unmount")
      self.assertEqual(command, ["/usr/bin/fusermount3", "-u", str(self.mount.parent)])
      return types.SimpleNamespace(returncode=1)

    manager = self.make_manager(command_runner=failing_unmount)
    manager.snapshot_builder.build()
    manager.process = FakeProcess(events=events)
    manager.export_started = True
    self.lun.write_text(f"{self.mount}\n")

    with self.assertRaisesRegex(usb_storage.StorageError, "fusermount3"):
      manager.teardown()

    self.assertEqual(events, ["unmount"])
    self.assertIsNotNone(manager.process)
    self.assertTrue(self.snapshot.exists())

  def test_prepare_mount_removes_only_exact_stale_runtime_files(self) -> None:
    manager = self.make_manager()
    self.mount.parent.mkdir(parents=True)
    self.mount.write_text("stale virtual file")
    manager.pidfile.write_text("999")
    unrelated = self.mount.parent / "keep-me"
    unrelated.write_text("keep")

    manager._prepare_mount()

    self.assertFalse(self.mount.exists())
    self.assertFalse(manager.pidfile.exists())
    self.assertEqual(unrelated.read_text(), "keep")


class ScriptedMonitorManager(usb_storage.StorageManager):
  def __init__(self, *, udc_states: list[str], lun_values: list[str], **kwargs: object):
    self._udc_states = iter(udc_states)
    self._lun_values = iter(lun_values)
    self._last_udc = udc_states[-1]
    self._last_lun = lun_values[-1] if lun_values else ""
    super().__init__(**kwargs)
    self.process = FakeProcess()

  def _read_udc_state(self) -> str:
    try:
      self._last_udc = next(self._udc_states)
    except StopIteration:
      pass
    return self._last_udc

  def _read_lun(self) -> str:
    try:
      self._last_lun = next(self._lun_values)
    except StopIteration:
      pass
    return self._last_lun


class StorageMonitorTest(ManagerTestBase):
  def scripted_manager(
    self,
    *,
    udc_states: list[str],
    lun_values: list[str],
    sleep: object | None = None,
  ) -> ScriptedMonitorManager:
    healthy_filesystem = types.SimpleNamespace(
      f_bavail=20 * 1024**3 // 4096,
      f_frsize=4096,
      f_blocks=100 * 1024**3 // 4096,
    )
    return ScriptedMonitorManager(
      source=self.source,
      snapshot=self.snapshot,
      mount=self.mount,
      lun=self.lun,
      udc_state=self.udc_state,
      gadget_lock=self.gadget_lock,
      udc_states=udc_states,
      lun_values=lun_values,
      sleep=sleep or (lambda _seconds: None),
      filesystem_stats=lambda _path: healthy_filesystem,
    )

  def test_detects_host_eject(self) -> None:
    manager = self.scripted_manager(
      udc_states=["configured"],
      lun_values=[str(self.mount), ""],
    )

    self.assertEqual(manager.monitor(threading.Event()), usb_storage.SessionEnd.EJECTED)

  def test_detects_detach_after_configuration(self) -> None:
    manager = self.scripted_manager(
      udc_states=["configured", "not attached"],
      lun_values=[str(self.mount)],
    )

    self.assertEqual(manager.monitor(threading.Event()), usb_storage.SessionEnd.DETACHED)

  def test_low_space_ends_session(self) -> None:
    stats = types.SimpleNamespace(
      f_bavail=usb_storage.MIN_FREE_BYTES // 4096,
      f_frsize=4096,
      f_blocks=10 * (usb_storage.MIN_FREE_BYTES // 4096),
    )
    manager = self.scripted_manager(
      udc_states=["configured"],
      lun_values=[str(self.mount)],
    )
    manager.filesystem_stats = lambda _path: stats

    self.assertEqual(manager.monitor(threading.Event()), usb_storage.SessionEnd.LOW_SPACE)

  def test_space_stat_failure_is_fail_closed(self) -> None:
    manager = self.scripted_manager(
      udc_states=["configured"],
      lun_values=[str(self.mount)],
    )
    manager.filesystem_stats = lambda _path: (_ for _ in ()).throw(OSError("statvfs failed"))

    self.assertEqual(manager.monitor(threading.Event()), usb_storage.SessionEnd.LOW_SPACE)

  def test_wait_for_attach_is_idle_until_stopped(self) -> None:
    stop_event = threading.Event()
    manager = self.scripted_manager(
      udc_states=["attached"],
      lun_values=[str(self.mount)],
      sleep=lambda _seconds: stop_event.set(),
    )

    self.assertFalse(manager._wait_for_configured(stop_event))

  def test_run_does_not_build_snapshot_before_attach(self) -> None:
    stop_event = threading.Event()
    self.udc_state.write_text("not attached\n")
    self.snapshot.mkdir()
    (self.snapshot / "stale-link").write_bytes(b"stale")
    manager = self.make_manager(sleep=lambda _seconds: stop_event.set())
    self.mount.parent.mkdir(parents=True)
    self.mount.write_text("stale virtual file")
    manager.pidfile.write_text("999")

    self.assertEqual(manager.run(stop_event), 0)
    self.assertFalse(self.snapshot.exists())
    self.assertFalse(self.mount.exists())
    self.assertFalse(manager.pidfile.exists())

  def test_missing_realdata_at_service_start_is_not_fatal(self) -> None:
    self.source.rmdir()
    stop_event = threading.Event()
    manager = self.make_manager(sleep=lambda _seconds: stop_event.set())

    self.assertFalse(manager._wait_for_source_while_attached(stop_event))
    self.assertFalse(self.snapshot.exists())

  def test_eject_and_low_space_latch_before_reinsertion(self) -> None:
    events: list[str] = []
    stop_event = threading.Event()

    class LifecycleManager(usb_storage.StorageManager):
      wait_count = 0
      session_ends = iter((usb_storage.SessionEnd.EJECTED, usb_storage.SessionEnd.LOW_SPACE))

      def _wait_for_configured(inner_self, event: threading.Event) -> bool:
        inner_self.wait_count += 1
        events.append("wait-configured")
        if inner_self.wait_count <= 2:
          return True
        event.set()
        return False

      def _wait_for_source_while_attached(inner_self, _event: threading.Event) -> bool:
        events.append("source-ready")
        return True

      def _read_udc_state(inner_self) -> str:
        return "configured"

      def _start_export(inner_self) -> None:
        events.append("start-export")

      def _set_lun(inner_self) -> None:
        events.append("set-lun")

      def monitor(inner_self, _event: threading.Event) -> usb_storage.SessionEnd:
        end = next(inner_self.session_ends)
        events.append(f"monitor-{end}")
        return end

      def teardown(inner_self, *, rebind: bool = True) -> None:
        events.append("teardown")
        inner_self.snapshot_builder.cleanup()

      def _wait_for_physical_detach(inner_self, _event: threading.Event) -> bool:
        events.append("eject-latch-until-detach")
        return True

    manager = LifecycleManager(
      source=self.source,
      snapshot=self.snapshot,
      mount=self.mount,
      lun=self.lun,
      udc_state=self.udc_state,
      gadget_lock=self.gadget_lock,
      snapshot_wall_clock_ns=lambda: time.time_ns() + (3 * usb_storage.DEFAULT_STABILITY_AGE_NS),
    )
    segment = self.source / "00000001--abc123def0--0"
    segment.mkdir()
    (segment / "qlog.zst").write_bytes(b"data")

    self.assertEqual(manager.run(stop_event), 2)
    self.assertEqual(events.count("start-export"), 2)
    self.assertEqual(events.count("set-lun"), 2)
    self.assertEqual(events.count("teardown"), 2)
    self.assertEqual(events.count("eject-latch-until-detach"), 2)
    first_teardown = events.index("teardown")
    latch = events.index("eject-latch-until-detach")
    second_start = events.index("start-export", first_teardown + 1)
    self.assertLess(first_teardown, latch)
    self.assertLess(latch, second_start)


if __name__ == "__main__":
  unittest.main()
