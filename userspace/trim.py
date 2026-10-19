import shutil
import subprocess
import sysconfig
from pathlib import Path

site = Path(sysconfig.get_path("purelib"))

# GNU strip corrupts the layout of the patched tinymesa libraries.
for package in ("tinymesa", "capnp", "zstandard", "kiwisolver", "fontTools"):
  for library in (site / package).rglob("*.so"):
    if not library.is_symlink():
      subprocess.run(["llvm-strip", "--strip-debug", str(library)], check=True)

# Keep runtime helpers such as numpy.testing and sympy.testing.
for package in ("sympy", "numpy", "matplotlib", "mpmath", "setuptools"):
  for directory in sorted((site / package).rglob("*")):
    if directory.name in ("tests", "test") and directory.is_dir():
      shutil.rmtree(directory)

# These inspection/benchmark tools are not used by GCC or clang to compile.
for pattern in ("/usr/bin/*lto-dump*", "/usr/bin/llvm-exegesis*", "/usr/lib/llvm-*/bin/llvm-exegesis"):
  for path in Path("/").glob(pattern.lstrip("/")):
    path.unlink()

# AGNOS uses Adreno EGL/GLES/GBM. Keep LLVM20 for tinymesa's CPU compiler.
lib = Path("/usr/lib/aarch64-linux-gnu")
for pattern in ("libgallium-*.so", "libEGL_mesa.so*", "libGLX_mesa.so*", "libgbm.so.1.0.0"):
  for path in lib.glob(pattern):
    path.unlink()
shutil.rmtree(lib / "dri")
shutil.rmtree(lib / "gbm")
Path("/usr/share/glvnd/egl_vendor.d/50_mesa.json").unlink()
