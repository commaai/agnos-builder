#!/usr/bin/env python3
"""Remove only a stopped USB storage service's narrowly owned artifacts."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import stat
import subprocess
import sys
from collections.abc import Callable, Sequence
from typing import Any

from usb_storage import MANAGED_MOUNT_DIRECTORY, MANAGED_MOUNT_NAME, SnapshotBuilder, StorageError


def _decode_mountinfo_field(value: str) -> str:
  for encoded, decoded in ((r"\040", " "), (r"\011", "\t"), (r"\012", "\n"), (r"\134", "\\")):
    value = value.replace(encoded, decoded)
  return value


def _mountinfo_entries(
  mountpoint: Path,
  *,
  mountinfo: Path = Path("/proc/self/mountinfo"),
) -> tuple[tuple[str, str], ...]:
  """Return (filesystem type, source) for exact stacked mounts at mountpoint."""
  try:
    lines = mountinfo.read_text().splitlines()
  except OSError as exc:
    raise StorageError(f"cannot inspect kernel mount table: {exc}") from exc

  entries: list[tuple[str, str]] = []
  for line in lines:
    left, separator, right = line.partition(" - ")
    left_fields = left.split()
    right_fields = right.split()
    if not separator or len(left_fields) < 6 or len(right_fields) < 2:
      raise StorageError("kernel mount table contains a malformed entry")
    if _decode_mountinfo_field(left_fields[4]) == str(mountpoint):
      entries.append((right_fields[0], _decode_mountinfo_field(right_fields[1])))
  return tuple(entries)


class StoppedStorageCleanup:
  """Clean stale FUSE and snapshot state after systemd killed the cgroup."""

  def __init__(
    self,
    *,
    source: str | os.PathLike[str],
    snapshot: str | os.PathLike[str],
    mount: str | os.PathLike[str],
    unmount_timeout: float = 5.0,
    command_runner: Callable[..., Any] = subprocess.run,
    mount_inspector: Callable[[Path], tuple[tuple[str, str], ...]] = _mountinfo_entries,
  ):
    self.snapshot_builder = SnapshotBuilder(source, snapshot)
    requested_mount = Path(mount)
    if not requested_mount.is_absolute():
      raise StorageError("managed FUSE path must be absolute")
    if requested_mount.name != MANAGED_MOUNT_NAME or requested_mount.parent.name != MANAGED_MOUNT_DIRECTORY:
      raise StorageError(f"refusing unmanaged FUSE path (expected .../{MANAGED_MOUNT_DIRECTORY}/{MANAGED_MOUNT_NAME})")
    if ".." in requested_mount.parts:
      raise StorageError("managed FUSE path must not contain parent traversal")
    if unmount_timeout <= 0:
      raise StorageError("unmount timeout must be positive")

    self.requested_mount_parent = requested_mount.parent
    self.mount_parent = self.requested_mount_parent
    self.mount = requested_mount
    self.pidfile = self.requested_mount_parent.with_suffix(".pid")
    self.unmount_timeout = unmount_timeout
    self.command_runner = command_runner
    self.mount_inspector = mount_inspector

  def _resolved_managed_paths(self) -> tuple[Path, Path, Path]:
    parent_metadata = self.requested_mount_parent.lstat()
    if not stat.S_ISDIR(parent_metadata.st_mode) or stat.S_ISLNK(parent_metadata.st_mode):
      raise StorageError("managed FUSE parent must be a real directory")
    resolved_mount_parent = self.requested_mount_parent.resolve(strict=True)
    if resolved_mount_parent == Path("/"):
      raise StorageError("managed FUSE path must not be the filesystem root")
    resolved_mount = resolved_mount_parent / self.mount.name
    resolved_pidfile = resolved_mount_parent.with_suffix(".pid")

    snapshot = self.snapshot_builder.snapshot
    source = self.snapshot_builder.source
    if (
      resolved_mount_parent == snapshot
      or resolved_mount_parent.is_relative_to(snapshot)
      or snapshot.is_relative_to(resolved_mount_parent)
      or resolved_mount_parent == source
      or resolved_mount_parent.is_relative_to(source)
      or source.is_relative_to(resolved_mount_parent)
    ):
      raise StorageError("managed FUSE, snapshot, and source paths must not contain each other")
    return resolved_mount_parent, resolved_mount, resolved_pidfile

  @staticmethod
  def _validate_optional_regular_file(path: Path, description: str) -> None:
    try:
      metadata = path.lstat()
    except FileNotFoundError:
      return
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
      raise StorageError(f"{description} is unsafe")

  def _mounted_filesystems(self) -> tuple[tuple[str, str], ...]:
    try:
      return self.mount_inspector(self.requested_mount_parent)
    except OSError as exc:
      raise StorageError(f"cannot inspect stale nbdfuse mount state: {exc}") from exc

  def _validate_managed_mount(self, entries: tuple[tuple[str, str], ...]) -> None:
    if len(entries) != 1:
      raise StorageError("refusing stacked filesystems at managed nbdfuse mountpoint")
    filesystem_type, source = entries[0]
    if filesystem_type != "fuse.nbdfuse" or source != "nbdfuse":
      raise StorageError(f"refusing to detach foreign filesystem {filesystem_type}:{source}")

  def _detach_stale_fuse(self) -> None:
    entries = self._mounted_filesystems()
    if not entries:
      return
    self._validate_managed_mount(entries)
    try:
      result = self.command_runner(
        ["/usr/bin/fusermount3", "-uz", str(self.requested_mount_parent)],
        check=False,
        timeout=self.unmount_timeout,
      )
    except subprocess.TimeoutExpired as exc:
      raise StorageError("timed out detaching stale nbdfuse mount") from exc
    if getattr(result, "returncode", 0) != 0:
      raise StorageError(f"stale nbdfuse detach failed with status {result.returncode}")
    if self._mounted_filesystems():
      raise StorageError("stale nbdfuse mount remains attached")

  def cleanup(self) -> None:
    # Snapshot validation runs before any removal. In particular, a foreign
    # mount or symlink beneath the managed snapshot makes the whole operation
    # fail closed without unlinking a single snapshot entry.
    self.snapshot_builder.validate_cleanup_target()
    self._validate_optional_regular_file(self.pidfile, "nbdfuse pidfile")
    # Read /proc/self/mountinfo before touching the mountpoint itself. A dead
    # FUSE mount can make lstat()/resolve() fail with ENOTCONN, but its exact
    # target and filesystem identity remain available in the kernel table.
    self._detach_stale_fuse()
    # A FUSE mount hides its underlying output artifact. Validate it only
    # after detaching, then remove exactly that file and the adjacent pidfile.
    _mount_parent, resolved_mount, resolved_pidfile = self._resolved_managed_paths()
    self._validate_optional_regular_file(resolved_mount, "nbdfuse output path")
    self._validate_optional_regular_file(resolved_pidfile, "nbdfuse pidfile")
    for artifact in (resolved_mount, resolved_pidfile):
      try:
        artifact.unlink()
      except FileNotFoundError:
        pass
    self.snapshot_builder.cleanup()


def _build_parser() -> argparse.ArgumentParser:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--source", default="/data/media/0/realdata")
  parser.add_argument("--snapshot", default="/data/tmp/usb-storage-snapshot")
  parser.add_argument("--mount", default="/run/usb-storage/footage.img")
  parser.add_argument("--unmount-timeout", type=float, default=5.0)
  return parser


def main(argv: Sequence[str] | None = None) -> int:
  arguments = _build_parser().parse_args(argv)
  try:
    StoppedStorageCleanup(
      source=arguments.source,
      snapshot=arguments.snapshot,
      mount=arguments.mount,
      unmount_timeout=arguments.unmount_timeout,
    ).cleanup()
  except (OSError, StorageError) as exc:
    print(f"USB storage post-stop cleanup failed safely: {exc}", file=sys.stderr)
    return 1
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
