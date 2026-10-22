#!/usr/bin/env python3
# Split the packages `uv sync` would install into wheel URLs for:
#   musl.txt  - musllinux aarch64 or pure-Python wheels (or sdists, built here)
#   glibc.txt - packages with only manylinux aarch64 wheels. SPIKE: installed
#               anyway as a size stand-in; they need musl builds to actually run.
# usage: pick_wheels.py uv.lock export.txt outdir
import re
import sys
import tomllib

lock, export, outdir = sys.argv[1:]
wanted = {}
for line in open(export):
  m = re.match(r"^([A-Za-z0-9_.-]+)==([^ ;\\]+)", line.strip())
  if m:
    wanted[m[1].lower().replace("_", "-")] = m[2]

def tag_score(url, kind):
  name = url.rsplit("/", 1)[-1]
  if kind == "musl":
    m = re.search(r"musllinux_(\d+)_(\d+)_aarch64", name)
  else:
    m = re.search(r"manylinux_?(\d+)_(\d+)_aarch64|manylinux2014_aarch64", name)
  if not m:
    return None
  ver = (2, 17) if "manylinux2014" in name else (int(m[1]), int(m[2]))
  cp = 2 if "-cp312-" in name else (1 if "abi3" in name else 0)
  return (cp, ver)

musl, glibc, sdist = [], [], []
for p in tomllib.load(open(lock, "rb"))["package"]:
  name = p["name"].lower().replace("_", "-")
  if name not in wanted or "registry" not in p.get("source", {}):
    continue
  wheels = [w["url"] for w in p.get("wheels", [])]
  py312 = [u for u in wheels if re.search(r"-(cp312|abi3|py3|py2\.py3)-", u.rsplit("/", 1)[-1]) or "-cp3" in u and "abi3" in u]
  best = None
  for kind, bucket in (("musl", musl), ("glibc", glibc)):
    cands = [(tag_score(u, kind), u) for u in py312]
    cands = [c for c in cands if c[0]]
    if kind == "glibc":
      pure = [u for u in wheels if u.endswith("-none-any.whl")]
      if pure:
        best = (musl, pure[0])
        break
    if cands:
      best = (bucket, max(cands)[1])
      break
  if best is None and p.get("sdist"):
    best = (sdist, f"{p['name']}=={p['version']}")
  if best is None:
    sys.exit(f"no installable artifact for {name}")
  best[0].append(best[1] if best[0] is sdist else f"{p['name']} @ {best[1]}")

for fn, rows in (("musl.txt", musl), ("glibc.txt", glibc), ("sdist.txt", sdist)):
  open(f"{outdir}/{fn}", "w").write("\n".join(rows) + "\n")
print(f"musl/pure wheels: {len(musl)}, sdists: {len(sdist)}, glibc-only stand-ins: {len(glibc)}")
print("glibc-only:", " ".join(sorted(r.split(" @ ")[0] for r in glibc)))
