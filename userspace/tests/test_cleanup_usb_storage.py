#!/usr/bin/env python3

from __future__ import annotations

import errno
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest  # noqa: TID251 - these tests intentionally use only the standard library
from unittest import mock  # noqa: TID251 - these tests intentionally use only the standard library


USERSPACE = Path(__file__).parents[1]
COMMA_DIR = USERSPACE / "root" / "usr" / "comma"
POST_STOP = COMMA_DIR / "cleanup_usb_storage.sh"
STORAGE_SERVICE = USERSPACE / "root" / "usr" / "lib" / "systemd" / "system" / "usb-storage.service"
sys.path.insert(0, str(COMMA_DIR))

import cleanup_usb_storage  # noqa: E402, RUF100
import usb_storage  # noqa: E402, RUF100


class StoppedStorageCleanupTest(unittest.TestCase):
  def setUp(self) -> None:
    self.temporary_directory = tempfile.TemporaryDirectory()
    self.root = Path(self.temporary_directory.name)
    self.source = self.root / "realdata"
    self.source.mkdir()
    self.snapshot = self.root / usb_storage.MANAGED_SNAPSHOT_NAME
    self.mount_parent = self.root / usb_storage.MANAGED_MOUNT_DIRECTORY
    self.mount_parent.mkdir()
    self.mount = self.mount_parent / usb_storage.MANAGED_MOUNT_NAME
    self.pidfile = self.mount_parent.with_suffix(".pid")

  def tearDown(self) -> None:
    if self.snapshot.exists() and not self.snapshot.is_symlink():
      usb_storage.SnapshotBuilder(self.source, self.snapshot).cleanup()
    self.temporary_directory.cleanup()

  def cleaner(self, **kwargs: object) -> cleanup_usb_storage.StoppedStorageCleanup:
    return cleanup_usb_storage.StoppedStorageCleanup(
      source=self.source,
      snapshot=self.snapshot,
      mount=self.mount,
      **kwargs,
    )

  def test_clean_stop_is_an_idempotent_noop(self) -> None:
    def unexpected_runner(*_args: object, **_kwargs: object) -> None:
      self.fail("fusermount3 must not run for a clean stop")

    self.cleaner(command_runner=unexpected_runner, mount_inspector=lambda _path: ()).cleanup()

    self.assertFalse(self.snapshot.exists())
    self.assertFalse(self.mount.exists())
    self.assertFalse(self.pidfile.exists())

  def test_forced_stop_detaches_then_removes_only_managed_artifacts(self) -> None:
    source_file = self.source / "route.log"
    source_file.write_bytes(b"pinned footage")
    self.snapshot.mkdir()
    snapshot_file = self.snapshot / "route.log"
    os.link(source_file, snapshot_file)
    self.mount.write_bytes(b"stale virtual file")
    self.pidfile.write_text("123\n")
    active = True
    commands: list[list[str]] = []

    def mount_inspector(_path: Path) -> tuple[tuple[str, str], ...]:
      return (("fuse.nbdfuse", "nbdfuse"),) if active else ()

    def runner(command: list[str], **_kwargs: object) -> types.SimpleNamespace:
      nonlocal active
      commands.append(command)
      active = False
      return types.SimpleNamespace(returncode=0)

    cleaner = self.cleaner(command_runner=runner, mount_inspector=mount_inspector)
    cleaner.cleanup()

    self.assertEqual(commands, [["/usr/bin/fusermount3", "-uz", str(cleaner.mount_parent)]])
    self.assertFalse(self.snapshot.exists())
    self.assertFalse(self.mount.exists())
    self.assertFalse(self.pidfile.exists())
    self.assertEqual(source_file.read_bytes(), b"pinned footage")

  def test_unsafe_snapshot_is_preserved_before_any_detach_or_unlink(self) -> None:
    foreign = self.root / "foreign"
    foreign.mkdir()
    foreign_file = foreign / "private"
    foreign_file.write_text("preserve")
    self.snapshot.symlink_to(foreign, target_is_directory=True)
    self.mount.write_bytes(b"preserve")
    self.pidfile.write_text("123\n")

    with self.assertRaises(usb_storage.StorageError):
      self.cleaner(mount_inspector=lambda _path: ()).cleanup()

    self.assertTrue(self.snapshot.is_symlink())
    self.assertTrue(self.mount.exists())
    self.assertTrue(self.pidfile.exists())
    self.assertEqual(foreign_file.read_text(), "preserve")

  def test_failed_stale_unmount_preserves_backing_state(self) -> None:
    self.snapshot.mkdir()
    (self.snapshot / "route.log").write_bytes(b"pinned")
    self.mount.write_bytes(b"stale virtual file")
    self.pidfile.write_text("123\n")

    with self.assertRaisesRegex(usb_storage.StorageError, "status 7"):
      self.cleaner(
        command_runner=lambda *_args, **_kwargs: types.SimpleNamespace(returncode=7),
        mount_inspector=lambda _path: (("fuse.nbdfuse", "nbdfuse"),),
      ).cleanup()

    self.assertTrue(self.snapshot.exists())
    self.assertTrue(self.mount.exists())
    self.assertTrue(self.pidfile.exists())

  def test_dead_fuse_is_detached_before_mountpoint_path_inspection(self) -> None:
    self.snapshot.mkdir()
    (self.snapshot / "route.log").write_bytes(b"pinned")
    self.mount.write_bytes(b"stale virtual file")
    self.pidfile.write_text("123\n")
    active = True

    def mount_inspector(_path: Path) -> tuple[tuple[str, str], ...]:
      return (("fuse.nbdfuse", "nbdfuse"),) if active else ()

    def runner(*_args: object, **_kwargs: object) -> types.SimpleNamespace:
      nonlocal active
      active = False
      return types.SimpleNamespace(returncode=0)

    cleaner = self.cleaner(command_runner=runner, mount_inspector=mount_inspector)
    real_resolve = Path.resolve
    real_lstat = Path.lstat

    def guarded_resolve(path: Path, strict: bool = False) -> Path:
      if path == self.mount_parent and active:
        raise OSError(errno.ENOTCONN, "dead FUSE")
      return real_resolve(path, strict=strict)

    def guarded_lstat(path: Path) -> os.stat_result:
      if path == self.mount_parent and active:
        raise OSError(errno.ENOTCONN, "dead FUSE")
      return real_lstat(path)

    with mock.patch.object(Path, "resolve", guarded_resolve), mock.patch.object(Path, "lstat", guarded_lstat):
      cleaner.cleanup()

    self.assertFalse(self.snapshot.exists())
    self.assertFalse(self.mount.exists())
    self.assertFalse(self.pidfile.exists())

  def test_foreign_mount_is_never_detached_or_cleaned(self) -> None:
    self.snapshot.mkdir()
    (self.snapshot / "route.log").write_bytes(b"pinned")
    self.pidfile.write_text("123\n")

    def unexpected_runner(*_args: object, **_kwargs: object) -> None:
      self.fail("foreign mount must not be detached")

    with self.assertRaisesRegex(usb_storage.StorageError, "foreign filesystem"):
      self.cleaner(
        command_runner=unexpected_runner,
        mount_inspector=lambda _path: (("ext4", "/dev/private"),),
      ).cleanup()

    self.assertTrue(self.snapshot.exists())
    self.assertTrue(self.pidfile.exists())

  def test_foreign_fuse_cannot_spoof_nbdfuse_with_its_source_basename(self) -> None:
    self.snapshot.mkdir()
    (self.snapshot / "route.log").write_bytes(b"pinned")

    def unexpected_runner(*_args: object, **_kwargs: object) -> None:
      self.fail("spoofed foreign FUSE mount must not be detached")

    with self.assertRaisesRegex(usb_storage.StorageError, "foreign filesystem"):
      self.cleaner(
        command_runner=unexpected_runner,
        mount_inspector=lambda _path: (("fuse.sshfs", "/foreign/nbdfuse"),),
      ).cleanup()

    self.assertTrue(self.snapshot.exists())

  def test_mount_inspection_error_is_not_treated_as_no_mount(self) -> None:
    self.snapshot.mkdir()
    (self.snapshot / "route.log").write_bytes(b"pinned")

    def unavailable(_path: Path) -> tuple[tuple[str, str], ...]:
      raise OSError(errno.EIO, "mount table unavailable")

    with self.assertRaisesRegex(usb_storage.StorageError, "cannot inspect"):
      self.cleaner(mount_inspector=unavailable).cleanup()

    self.assertTrue(self.snapshot.exists())

  def test_mountinfo_parser_matches_only_the_exact_managed_target(self) -> None:
    mountinfo = self.root / "mountinfo"
    mountinfo.write_text(
      "".join((
        "35 24 0:31 / /run rw - tmpfs tmpfs rw\n",
        "36 35 0:32 / /run/usb-storage rw - fuse.nbdfuse nbdfuse rw\n",
        "37 35 0:33 / /run/usb-storage-extra rw - ext4 /dev/private rw\n",
      )),
    )

    entries = cleanup_usb_storage._mountinfo_entries(Path("/run/usb-storage"), mountinfo=mountinfo)

    self.assertEqual(entries, (("fuse.nbdfuse", "nbdfuse"),))


class PostStopWrapperTest(unittest.TestCase):
  def setUp(self) -> None:
    self.temporary_directory = tempfile.TemporaryDirectory()
    self.root = Path(self.temporary_directory.name)
    self.log = self.root / "order.log"
    self.helper = self.root / "helper"
    self.helper.write_text(
      "".join((
        "#!/bin/sh\n",
        "printf 'helper:%s\\n' \"$1\" >> \"$POST_STOP_LOG\"\n",
      )),
    )
    self.helper.chmod(0o755)
    self.cleanup = self.root / "cleanup"
    self.cleanup.write_text(
      "".join((
        "#!/bin/sh\n",
        "printf 'cleanup\\n' >> \"$POST_STOP_LOG\"\n",
      )),
    )
    self.cleanup.chmod(0o755)
    self.environment = os.environ.copy()
    self.environment.update({
      "POST_STOP_LOG": str(self.log),
      "USB_GADGET_HELPER": str(self.helper),
      "USB_STORAGE_CLEANUP_BIN": str(self.cleanup),
    })

  def tearDown(self) -> None:
    self.temporary_directory.cleanup()

  def test_cleanup_finishes_before_safe_personality_reconstruction(self) -> None:
    subprocess.run([str(POST_STOP)], env=self.environment, check=True, capture_output=True, text=True)

    self.assertEqual(self.log.read_text().splitlines(), [
      "helper:prepare-storage-post-stop",
      "cleanup",
      "helper:ensure-requested-personality",
    ])

  def test_cleanup_failure_forces_unbind_and_never_reconstructs(self) -> None:
    self.cleanup.write_text("#!/bin/sh\nexit 9\n")

    result = subprocess.run([str(POST_STOP)], env=self.environment, check=False, capture_output=True, text=True)

    self.assertNotEqual(result.returncode, 0)
    self.assertEqual(self.log.read_text().splitlines(), [
      "helper:prepare-storage-post-stop",
      "helper:unbind",
    ])

  def test_reconstruction_failure_happens_only_after_cleanup_and_stays_unbound(self) -> None:
    self.helper.write_text(
      "".join((
        "#!/bin/sh\n",
        "printf 'helper:%s\\n' \"$1\" >> \"$POST_STOP_LOG\"\n",
        "[ \"$1\" != ensure-requested-personality ]\n",
      )),
    )

    result = subprocess.run([str(POST_STOP)], env=self.environment, check=False, capture_output=True, text=True)

    self.assertNotEqual(result.returncode, 0)
    self.assertEqual(self.log.read_text().splitlines(), [
      "helper:prepare-storage-post-stop",
      "cleanup",
      "helper:ensure-requested-personality",
      "helper:unbind",
    ])

  def test_service_runs_post_stop_cleanup_after_control_group_shutdown(self) -> None:
    unit = STORAGE_SERVICE.read_text()

    self.assertIn("ExecStopPost=/usr/comma/cleanup_usb_storage.sh\n", unit)
    self.assertIn("KillMode=control-group\n", unit)


if __name__ == "__main__":
  unittest.main()
