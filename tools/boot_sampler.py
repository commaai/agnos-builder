#!/usr/bin/env python3
"""Reboot DUTs in a loop as fast as possible and keep each boot's logs.

Runs against UP stations (adb to the DUT over the station, so no DUT network is needed) or `local` when run on one.

  boot_sampler.py -o runs/x --method sysrq UP12=user@station UP13=user@station   # until ctrl-c, rerun to continue
  boot_sampler.py -o runs/x --method power --count 100 --targets-file targets    # NAME=TARGET per line, cold boots
  boot_sampler.py -o runs/x --capture foo='cat /proc/foo' --ready 'test -e /tmp/x' --settle 5 ...
  boot_sampler.py -o runs/x --summary

Methods:
  sysrq   fastest, skips shutdown. Unclean like a power cut, after a sync. The CPU stays powered: a warm boot
  reboot  clean `systemctl reboot`, ~10 s slower since it waits on shutdown. A warm boot
  power   cuts the DUT's power from the station. A cold boot, use this for anything that may depend on it

Output: <out>/manifest.jsonl (append only, one line per sample or event), <out>/<device>/<sample>/<capture>.gz.
A sample's directory is complete if it exists, and is renamed into place before its manifest line is written.

Reboots mark the current boot successful first, since a reboot before openpilot gets to it counts against the A/B retry
limit, and falling back to another slot can brick a rack DUT. So this can't be used to test slot fallback.
"""
import argparse
import datetime
import gzip
import json
import os
import re
import shlex
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

CAPTURES = {
  "dmesg": "dmesg",
  "journal": "journalctl -b --no-pager -o short-monotonic",
  "analyze": "systemd-analyze; systemd-analyze blame --no-pager",
}
BOOT_ID = "cat /proc/sys/kernel/random/boot_id"
SYSTEM_READY = "systemctl is-system-running | grep -qE '^(running|degraded)$'"
TRIGGERS = {
  "sysrq": "sync; echo b > /proc/sysrq-trigger",
  "reboot": "systemctl reboot",
}
POWER_CYCLE = """PYTHONPATH=/data/rack-up python3 -c '
import ultimate_provisioning.dut as D
D.POWER_OFF = {off_time}
d = D.DUT(); d.power_cycle(); d.up.set_aux_host()'"""

stop = threading.Event()
write_lock = threading.Lock()


class Interrupted(Exception):
  pass


class Device:
  def __init__(self, name: str, target: str, args: argparse.Namespace, control_dir: str):
    self.name, self.target, self.args = name, target, args
    self.ssh = ["ssh", "-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ServerAliveInterval=5", "-o", "ControlMaster=auto", "-o", "ControlPersist=60",
                "-o", f"ControlPath={control_dir}/%C", *args.ssh_opt, target]
    self.slot = None

  def redact(self, s: str) -> str:
    return re.sub(r"\S+@\S+", "<host>", s.replace(self.target, self.name))[-300:]

  def station(self, cmd: str, timeout: float) -> subprocess.CompletedProcess:
    argv = ["bash", "-c", cmd] if self.target == "local" else [*self.ssh, cmd]
    try:
      # its own session, so ctrl-c lets a transfer finish instead of killing ssh under it
      return subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout, start_new_session=True)
    except subprocess.TimeoutExpired:
      return subprocess.CompletedProcess(argv, 124, b"", b"timeout")

  def dut(self, cmd: str, timeout: float = 5) -> tuple[bool, bytes]:
    # adb doesn't pass on the exit code
    r = self.station(f"adb exec-out {shlex.quote(f'({cmd}); echo __rc=$?')}", timeout)
    head, _, rc = r.stdout.rstrip().rpartition(b"__rc=")
    return r.returncode == 0 and rc == b"0", head

  def poll(self, until: float, check) -> bool:
    while time.monotonic() < until:
      if stop.is_set():
        raise Interrupted
      if check():
        return True
      time.sleep(0.05)
    return False

  def boot_id(self) -> str:
    ok, out = self.dut(BOOT_ID, timeout=3)
    return out.decode(errors="replace").strip() if ok else ""

  def trigger(self) -> str:
    """Start the reboot. Returns an error, if there is one worth recording."""
    mark_success = "abctl --set_success >/dev/null 2>&1"
    if self.args.method == "power":
      self.dut(mark_success)
      r = self.station(POWER_CYCLE.format(off_time=self.args.off_time), 30)
      return self.redact(r.stderr.decode(errors="replace")) if r.returncode else ""
    self.dut(f"{mark_success}; {TRIGGERS[self.args.method]}")  # the connection dies with the DUT, so its result means nothing
    return ""

  def wait_for_boot_id(self, old: str, timeout: float) -> tuple[bool, str]:
    """Wait until the DUT answers with a boot_id other than old."""
    new = [""]
    def check():
      new[0] = self.boot_id()
      return new[0] and new[0] != old
    return self.poll(time.monotonic() + timeout, check), new[0]

  def sample(self, out: Path, n: int) -> dict:
    a = self.args
    start = now()
    # after a crash or ctrl-c the DUT may still be booting
    _, old = self.wait_for_boot_id("", a.boot_timeout)
    rec = {"device": self.name, "sample": n, "method": a.method, "start": start, "prev_boot_id": old}
    t0 = time.monotonic()
    if not old:
      return {**rec, "status": "unreachable", "duration": a.boot_timeout}

    error = self.trigger()
    t_trigger = time.monotonic()
    rebooted, new = self.wait_for_boot_id(old, a.boot_timeout)
    t_boot = time.monotonic()
    rec.update(boot_id=new, trigger=round(t_trigger - t0, 2), boot=round(t_boot - t_trigger, 2))
    if error:
      rec["error"] = error
    if not rebooted:
      # same boot_id is a reboot that didn't happen, and none is a DUT that didn't come back
      return {**rec, "status": "no_reboot" if new == old else "boot_timeout", "duration": round(t_boot - t0, 2)}

    ready = self.poll(time.monotonic() + a.ready_timeout, lambda: self.dut(a.ready or SYSTEM_READY, timeout=10)[0])
    t_ready = time.monotonic()
    if a.settle:
      self.poll(t_ready + a.settle, lambda: False)
    t_cap = time.monotonic()
    rec["ready"] = round(t_ready - t_boot, 2)

    _, info = self.dut("cat /proc/uptime /VERSION; abctl --boot_slot", timeout=10)
    info = info.decode(errors="replace").split()
    if len(info) >= 4:
      rec.update(uptime=float(info[0]), version=info[2], slot=info[3])
    status = "ok" if ready else "ready_timeout"

    # sample numbers only count up, so a directory can't be overwritten even if a manifest line was lost
    tmp, final = out / self.name / f"{n:06d}.tmp", out / self.name / f"{n:06d}"
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    captures = {**CAPTURES, **dict(a.capture)}
    with ThreadPoolExecutor(len(captures)) as pool:
      results = pool.map(lambda cmd: self.dut(cmd, timeout=a.capture_timeout), captures.values())
      for name, (ok, data) in zip(captures, results):
        if not ok and name in CAPTURES and status == "ok":
          status = "capture_failed"
        (tmp / f"{name}.gz").write_bytes(gzip.compress(data, 1))
    tmp.rename(final)
    rec["capture"] = round(time.monotonic() - t_cap, 2)

    if self.slot and rec.get("slot") and rec["slot"] != self.slot:
      status = "slot_changed"
    self.slot = self.slot or rec.get("slot")
    return {**rec, "status": status, "duration": round(time.monotonic() - t0, 2)}

  def recover(self) -> bool:
    if not self.station("true", 15).returncode == 0:
      return False  # the station's gone, so nothing can be done about the DUT from here
    self.station(POWER_CYCLE.format(off_time=3.0), 30)
    return self.poll(time.monotonic() + self.args.boot_timeout, lambda: bool(self.boot_id()))

  def run(self, out: Path) -> None:
    n = next_sample(out, self.name)
    fails = 0
    while not stop.is_set():
      if self.args.count and count_ok(out, self.name) >= self.args.count:
        log(self.name, f"reached {self.args.count} ok samples")
        return
      try:
        rec = self.sample(out, n)
      except Interrupted:
        return
      with write_lock:
        append(out, rec)
      log(self.name, f"#{n} {rec['status']} {rec['duration']}s (boot {rec.get('boot', '-')}, uptime {rec.get('uptime', '-')})")
      n += 1
      fails = 0 if rec["status"] == "ok" else fails + 1

      reason = None
      if rec["status"] == "slot_changed":
        reason = f"slot changed to {rec.get('slot')}, the DUT may need reflashing"
      elif rec["status"] in ("boot_timeout", "unreachable"):
        try:
          recovered = self.recover()
        except Interrupted:
          return
        with write_lock:
          append(out, {"device": self.name, "event": "recovery", "ok": recovered, "start": now()})
        if not recovered:
          reason = "didn't come back after a power cycle"
      if reason is None and fails >= self.args.max_failures:
        reason = f"{fails} failures in a row"
      if reason:
        with write_lock:
          append(out, {"device": self.name, "event": "device_stopped", "reason": reason, "start": now()})
        log(self.name, f"stopping: {reason}")
        return


def now() -> str:
  return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def log(name: str, msg: str) -> None:
  print(f"{datetime.datetime.now():%H:%M:%S} {name} {msg}", flush=True)


def read_manifest(out: Path) -> list[dict]:
  path = out / "manifest.jsonl"
  if not path.exists():
    return []
  rows = []
  for line in path.read_text().splitlines():
    try:
      rows.append(json.loads(line))
    except json.JSONDecodeError:
      pass  # only a line cut off by a crash can be broken
  return rows


def append(out: Path, rec: dict) -> None:
  path = out / "manifest.jsonl"
  # a crash can leave a partial last line, don't glue this one to it
  torn = path.exists() and path.stat().st_size and path.read_bytes()[-1:] != b"\n"
  fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
  try:
    os.write(fd, (("\n" if torn else "") + json.dumps(rec) + "\n").encode())
    os.fsync(fd)
  finally:
    os.close(fd)


def count_ok(out: Path, name: str) -> int:
  return sum(r.get("device") == name and r.get("status") == "ok" for r in read_manifest(out))


def next_sample(out: Path, name: str) -> int:
  d = out / name
  on_disk = [int(p.name[:6]) for p in d.iterdir() if p.name[:6].isdigit()] if d.exists() else []
  in_manifest = [r["sample"] for r in read_manifest(out) if r.get("device") == name and "sample" in r]
  for p in d.glob("*.tmp") if d.exists() else []:
    shutil.rmtree(p, ignore_errors=True)
  return max(on_disk + in_manifest, default=0) + 1


def summary(out: Path) -> None:
  rows = read_manifest(out)
  samples = [r for r in rows if "sample" in r]
  names = sorted({r["device"] for r in rows})
  groups = sorted({(r["device"], r["method"]) for r in samples})
  print(f"{'device':8} {'method':7} {'ok':>5} {'fail':>5} {'/hour':>6} {'boot med':>9} {'uptime med':>11} {'cycle med':>10}")
  for name, method in groups:
    g = [r for r in samples if (r["device"], r["method"]) == (name, method)]
    ok = [r for r in g if r["status"] == "ok"]
    active = sum(r["duration"] for r in g)
    med = lambda k, rs=ok: statistics.median(v) if (v := [r[k] for r in rs if k in r]) else float("nan")
    print(f"{name:8} {method:7} {len(ok):5} {len(g) - len(ok):5} {len(ok) * 3600 / active if active else 0:6.0f} "
          f"{med('boot'):9.2f} {med('uptime'):11.2f} {med('duration'):10.2f}")
  for r in samples:
    if r["status"] != "ok":
      print(f"  {r['device']} #{r['sample']} {r['status']} {r.get('error', '')}")
  for name in names:
    state = next((r for r in reversed(rows) if r["device"] == name and "event" in r), {})
    stopped = state.get("event") == "device_stopped"
    want = {f"{r['sample']:06d}" for r in samples if r["device"] == name and r["status"] == "ok"}
    have = {p.name for p in (out / name).iterdir()} if (out / name).exists() else set()
    recorded = {f"{r['sample']:06d}" for r in samples if r["device"] == name}
    missing, extra = want - have, have - recorded
    print(f"{name}: {'STOPPED: ' + state['reason'] if stopped else 'running or idle'}; "
          f"{len(missing)} ok samples missing logs, {len(extra)} dirs not in manifest")


def parse_pair(s: str) -> tuple[str, str]:
  name, sep, value = s.partition("=")
  if not sep or not name or not value:
    raise argparse.ArgumentTypeError(f"expected NAME=VALUE, got {name}=...")
  return name, value


def main() -> int:
  p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
  p.add_argument("targets", nargs="*", type=parse_pair, metavar="NAME=SSH_TARGET", help="UP station to ssh to, or NAME=local")
  p.add_argument("-o", "--out", type=Path, required=True)
  p.add_argument("--summary", action="store_true")
  p.add_argument("--targets-file", type=Path, help="NAME=SSH_TARGET per line, to keep them off the command line")
  p.add_argument("--method", choices=["sysrq", "reboot", "power"], default="sysrq")
  p.add_argument("--count", type=int, default=0, help="stop once each device has this many ok samples in --out")
  p.add_argument("--ready", help="command on the DUT that succeeds once it's ready to capture. default: systemd finished")
  p.add_argument("--settle", type=float, default=0, help="seconds to wait after ready")
  p.add_argument("--capture", action="append", default=[], type=parse_pair, metavar="NAME=CMD", help="also store CMD's output")
  p.add_argument("--boot-timeout", type=float, default=120)
  p.add_argument("--ready-timeout", type=float, default=60)
  p.add_argument("--capture-timeout", type=float, default=60)
  p.add_argument("--max-failures", type=int, default=3, help="stop a device after this many failed samples in a row")
  p.add_argument("--off-time", type=float, default=1.0, help="seconds off for --method power, after the DUT's gone from USB")
  p.add_argument("--ssh-opt", action="append", default=[], help="extra ssh argument, e.g. -oUserKnownHostsFile=x")
  args = p.parse_args()

  if args.summary:
    summary(args.out)
    return 0

  targets = list(args.targets)
  if args.targets_file:
    targets += [parse_pair(l.strip()) for l in args.targets_file.read_text().splitlines() if l.strip()]
  if not targets:
    p.error("no targets")
  args.out.mkdir(parents=True, exist_ok=True)

  # the ssh control sockets' path has to be short, so not TMPDIR
  control_dir = tempfile.mkdtemp(prefix="bs", dir="/tmp")
  devices = [Device(name, target, args, control_dir) for name, target in targets]
  threads = [threading.Thread(target=d.run, args=(args.out,), daemon=True) for d in devices]

  def on_sigint(*_):
    if stop.is_set():
      os._exit(130)
    stop.set()
    print("stopping, in-flight samples are dropped. ctrl-c again to quit now", flush=True)
  signal.signal(signal.SIGINT, on_sigint)
  signal.signal(signal.SIGTERM, on_sigint)

  try:
    for t in threads:
      t.start()
    while any(t.is_alive() for t in threads):
      time.sleep(0.2)
  finally:
    for d in devices:
      if d.target != "local":
        subprocess.run([*d.ssh[:-1], "-O", "exit", d.target], capture_output=True, stdin=subprocess.DEVNULL)
    shutil.rmtree(control_dir, ignore_errors=True)
  summary(args.out)
  return 0


if __name__ == "__main__":
  sys.exit(main())
