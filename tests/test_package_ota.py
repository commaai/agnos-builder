import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("package_ota", Path(__file__).resolve().parents[1] / "scripts/package_ota.py")
package_ota = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package_ota)


class TestPackaging(unittest.TestCase):
  def setUp(self):
    directory = tempfile.TemporaryDirectory()
    self.addCleanup(directory.cleanup)
    self.root = Path(directory.name)
    self.output = self.root / "ota"
    self.boot = package_ota.Partition("boot", self.root / "boot.img", True, True, True, False)
    self.system = package_ota.Partition("system", self.root / "system.img", True, True, False, False)
    self.userdata = package_ota.Partition("userdata_90", self.root / "userdata.img", False, False, True, False)
    self.gpt = package_ota.GPT(0, "gpt_main_0", self.root / "gpt.img", 0, 6, False, False, True, False)
    for entry in (self.boot, self.system):
      entry.path.write_bytes(b"AGNOS fixture image")
    for name, value in {"OTA_OUTPUT_DIR": self.output, "GPTS": [self.gpt],
                        "PARTITIONS": [self.boot, self.system, self.userdata]}.items():
      mocked = patch.object(package_ota, name, value)
      mocked.start()
      self.addCleanup(mocked.stop)

  def run_packager(self, *args):
    with patch("sys.argv", ["package_ota.py", *args]):
      package_ota.main()

  def read_manifest(self, name):
    return json.loads((self.output / name).read_text())

  def test_ota_only_does_not_require_factory_images(self):
    self.run_packager("--ota-only")
    for name in ("ota.json", "ota-staging.json"):
      manifest = self.read_manifest(name)
      self.assertEqual([item["name"] for item in manifest], ["boot", "system"])
      for item in manifest:
        self.assertTrue((self.output / item["url"].rsplit("/", 1)[-1]).is_file())
    self.assertFalse((self.output / "all-partitions.json").exists())
    self.assertTrue(list(self.output.glob("system-*.img")))

  def test_full_release_keeps_factory_images(self):
    for entry in (self.gpt, self.userdata):
      entry.path.write_bytes(b"factory fixture image")
    self.run_packager()
    self.assertEqual([item["name"] for item in self.read_manifest("ota.json")], ["boot", "system"])
    for name in ("all-partitions.json", "all-partitions-staging.json"):
      manifest = self.read_manifest(name)
      self.assertEqual([item["name"] for item in manifest], ["gpt_main_0", "boot", "system", "userdata_90"])
      self.assertEqual(manifest[0]["gpt"], {"lun": 0, "start_sector": 0, "num_sectors": 6})


if __name__ == "__main__":
  unittest.main()
