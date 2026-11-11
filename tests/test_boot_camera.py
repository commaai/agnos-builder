import importlib.util
from pathlib import Path
import unittest

MODULE = Path(__file__).parents[1] / "userspace/root/usr/comma/boot_stress/camera.py"
spec = importlib.util.spec_from_file_location("boot_camera", MODULE)
camera = importlib.util.module_from_spec(spec)
spec.loader.exec_module(camera)


def samples(timestamps):
  return [{"frameId": i, "timestampSof": sof, "timestampEof": sof + 11_000_000} for i, sof in enumerate(timestamps)]


class TestCameraValidation(unittest.TestCase):
  def test_aligned_first_frames(self):
    streams = {name: samples([8_000_000_000 + offset + i * 50_000_000 for i in range(3)])
               for name, offset in zip(camera.CAMERAS, (0, 10_000, 25_000_000))}
    self.assertEqual(camera.validate_frames(streams), [])

  def test_real_up05_startup_frame_loss(self):
    # First three messages from UP05 boot cd0944e2, before any test-side trimming.
    # Counters stay consecutive while narrow loses a physical 50 ms period.
    streams = dict(zip(camera.CAMERAS, map(samples, (
      (8639646558, 8739648797, 8789642183),
      (8639640152, 8689624891, 8739640099),
      (8664620256, 8714639579, 8764678016),
    ))))
    errors = camera.validate_frames(streams)
    self.assertTrue(any("SOF interval 100.002239 ms" in error for error in errors), errors)
    self.assertTrue(any("road cameras: SOF offset" in error for error in errors), errors)

  def test_startup_frames_cannot_be_discarded(self):
    streams = {name: samples([8_000_000_000 + offset + i * 50_000_000 for i in range(3)])
               for name, offset in zip(camera.CAMERAS, (0, 10_000, 25_000_000))}
    for frames in streams.values():
      for frame in frames:
        frame["frameId"] += 1
    self.assertTrue(any("not zero" in error for error in camera.validate_frames(streams)))


if __name__ == "__main__":
  unittest.main()
