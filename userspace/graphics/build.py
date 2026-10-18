#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import subprocess
import sys


def run(*args):
  return subprocess.check_output(args, text=True)


def symbols(path):
  result = {}
  for line in run("readelf", "--dyn-syms", "--wide", str(path)).splitlines():
    fields = line.split()
    if len(fields) >= 8 and fields[0].removesuffix(":").isdigit():
      result[fields[7]] = fields[6]
  return result


def main():
  gbm, egl, output = map(Path, sys.argv[1:])
  output.mkdir(parents=True, exist_ok=True)
  stub = output / "libagnos-wayland-stubs.so"
  for library, source in [(stub, "stubs.c"), (output / "libCB.so", "opencl_stubs.c")]:
    subprocess.check_call([
      os.environ.get("CC", "gcc"), "-shared", "-fPIC", "-Os", "-s", "-Wall", "-Wextra", "-Werror",
      "-Wl,-z,defs", "-Wl,-z,relro,-z,now", f"-Wl,-soname,{library.name}",
      "-o", str(library), str(Path(__file__).with_name(source)),
    ])
  exports = {name for name, section in symbols(stub).items() if section != "UND"}
  dependencies = ["libwayland-client.so.0", "libwayland-server.so.0", "libwayland-egl.so.1", "libffi.so.6"]

  for source, name in [(gbm, "libgbm.so"), (egl, "libeglSubDriverWayland.so")]:
    # e_machine must match: cross builds must compile the stub for the drivers' architecture.
    if source.read_bytes()[18:20] != stub.read_bytes()[18:20]:
      raise RuntimeError("Stub and Qualcomm library architectures differ")
    imports = {name for name, section in symbols(source).items()
               if section == "UND" and name.startswith(("wl_", "WlEgl"))}
    if not imports or any("agnos_" + name not in exports for name in imports):
      raise RuntimeError(f"Uncovered Wayland imports in {source}: {sorted(imports)}")
    mapping = output / "symbols.map"
    mapping.write_text("".join(f"{name} agnos_{name}\n" for name in sorted(imports)))
    destination = output / name
    shutil.copyfile(source, destination)
    subprocess.check_call([
      "patchelf", "--rename-dynamic-symbols", str(mapping),
      *[arg for dependency in dependencies for arg in ("--remove-needed", dependency)],
      "--add-needed", stub.name, str(destination),
    ])
    patched = symbols(destination)
    if any(name.startswith(("wl_", "WlEgl")) for name in patched):
      raise RuntimeError(f"Wayland symbols remain in {destination}")
    if set(run("patchelf", "--print-needed", str(destination)).splitlines()) & set(dependencies):
      raise RuntimeError(f"Wayland dependencies remain in {destination}")
  mapping.unlink()


if __name__ == "__main__":
  main()
