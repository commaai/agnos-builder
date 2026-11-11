"""First-use audio, including the two independent clients used by openpilot."""
import ctypes
import contextlib
import concurrent.futures
import glob
import json
import fcntl
import select
import subprocess
import os
from pathlib import Path
import stat
import sys
import tempfile
import time
import traceback


STREAMS = {
  "input": {"samplerate": 16000, "channels": 1, "blocksize": 800},
  "output": {"samplerate": 48000, "channels": 1, "blocksize": 4096},
}


def _write(path, data):
  path = Path(path)
  temporary = path.with_suffix(path.suffix + ".tmp")
  temporary.write_text(json.dumps(data, default=str))
  temporary.replace(path)


def _card_state():
  try:
    return Path("/proc/asound/card0/state").read_text().strip()
  except OSError as e:
    return str(e)


def _device_snapshot(sd):
  result = {}
  try:
    result["default"] = list(sd.default.device)
    result["devices"] = [dict(device) for device in sd.query_devices()]
  except Exception as e:
    result["enumeration_error"] = repr(e)
  try:
    info = sd._lib.Pa_GetLastHostErrorInfo()
    if info != sd._ffi.NULL:
      result["host_error"] = {
        "api": int(info.hostApiType), "code": int(info.errorCode),
        "text": sd._ffi.string(info.errorText).decode(errors="replace") if info.errorText != sd._ffi.NULL else "",
      }
  except Exception as e:
    result["host_error_query"] = repr(e)
  return result


def _raw_alsa(role):
  """Bypass PortAudio's cached device list; only called after both clients close."""
  lib = ctypes.CDLL("libasound.so.2")
  lib.snd_pcm_open.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
  lib.snd_pcm_open.restype = ctypes.c_int
  lib.snd_pcm_close.argtypes = [ctypes.c_void_p]
  lib.snd_pcm_format_value.argtypes = [ctypes.c_char_p]
  lib.snd_pcm_format_value.restype = ctypes.c_int
  lib.snd_pcm_set_params.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_uint,
                                   ctypes.c_uint, ctypes.c_int, ctypes.c_uint]
  lib.snd_pcm_set_params.restype = ctypes.c_int
  lib.snd_pcm_prepare.argtypes = [ctypes.c_void_p]
  lib.snd_pcm_prepare.restype = ctypes.c_int
  lib.snd_strerror.argtypes = [ctypes.c_int]
  lib.snd_strerror.restype = ctypes.c_char_p
  pcm = ctypes.c_void_p()
  # SND_PCM_STREAM_PLAYBACK=0, CAPTURE=1; SND_PCM_NONBLOCK=1.
  result = {"open": lib.snd_pcm_open(ctypes.byref(pcm), b"default", int(role == "input"), 1)}
  if result["open"] == 0:
    try:
      # FLOAT_LE, RW_INTERLEAVED: the default plug PCM performs any required conversion.
      result["configure"] = lib.snd_pcm_set_params(pcm, lib.snd_pcm_format_value(b"FLOAT_LE"), 3, 1,
                                                 STREAMS[role]["samplerate"], 1, 100000)
      if result["configure"] == 0:
        result["prepare"] = lib.snd_pcm_prepare(pcm)
    finally:
      lib.snd_pcm_close(pcm)
  result["errors"] = {key: lib.snd_strerror(value).decode(errors="replace") for key, value in result.items() if value < 0}
  return result


def _gate(fd, timeout):
  try:
    if not select.select([fd], [], [], timeout)[0]:
      raise TimeoutError("audio peer did not reach the startup barrier")
    os.read(fd, 1)  # Closing the parent's writer releases every reader at once.
  finally:
    os.close(fd)


def _client(role, gates, diagnostic_lock, output, duration):
  """Never imported in the parent: even sounddevice's import enumerates devices."""
  result = {"role": role, "pid": os.getpid(), "uid": os.geteuid(), "gid": os.getegid(), "groups": os.getgroups(), "started": time.monotonic(), "card_state": _card_state(), "ok": False}
  sd = None
  try:
    _write(output + ".ready", result)
    _gate(gates[0], float(os.environ.get('BOOT_AUDIO_TIMEOUT', '5')))
    result["import_started"] = time.monotonic()
    import sounddevice as sd
    result["imported"] = time.monotonic()
    result["enumeration_after_import"] = _device_snapshot(sd)
    import numpy as np

    # Match micd's compatibility patch for NumPy's removal of binary fromstring.
    sd._array = lambda buffer, channels, dtype: np.frombuffer(buffer, dtype=dtype).reshape(-1, channels)
    result["portaudio"] = sd.get_portaudio_version()
    _write(output + ".imported", {"pid": os.getpid(), "time": time.monotonic()})
    _gate(gates[1], float(os.environ.get('BOOT_AUDIO_TIMEOUT', '5')))
    result["initialize_started"] = time.monotonic()
    sd._terminate()
    sd._initialize()
    result["initialized"] = time.monotonic()
    _write(output + '.initialized', {'pid': os.getpid(), 'time': result['initialized']})
    result["enumeration"] = _device_snapshot(sd)
    callbacks = {"count": 0, "frames": 0, "finite": True, "statuses": []}

    def callback(data, frames, timing, status):
      if role == "output":
        data.fill(0)  # Exercise real playback without emitting a tone.
      else:
        callbacks["finite"] = callbacks["finite"] and bool(np.isfinite(data).all())
      callbacks["count"] += 1
      callbacks["frames"] += frames
      if status and str(status) not in callbacks["statuses"]:
        callbacks["statuses"].append(str(status))

    constructor = sd.InputStream if role == "input" else sd.OutputStream
    with constructor(callback=callback, **STREAMS[role]) as stream:
      result["opened"] = time.monotonic()
      _write(output + '.opened', {'pid': os.getpid(), 'time': result['opened']})
      result["stream"] = {"device": int(stream.device), "samplerate": stream.samplerate,
                          "channels": stream.channels, "blocksize": stream.blocksize}
      time.sleep(duration)
      result["active"] = bool(stream.active)
    result["callbacks"] = callbacks
    assert callbacks["count"] > 0, "stream opened but delivered no callbacks"
    assert callbacks["finite"], "capture delivered non-finite samples"
    assert result["active"], "stream stopped unexpectedly"
    result["ok"] = True
  except Exception:
    result["error"] = traceback.format_exc()
    if sd is not None:
      result["enumeration_at_failure"] = _device_snapshot(sd)
  finally:
    result["stream_closed"] = time.monotonic()
    _write(output + ".initial", result)

  # Both clients have closed their real streams before the parent releases this gate.
  # This diagnoses a FAILED first use; it can never turn the result into a pass.
  if not result["ok"] and sd is not None:
    try:
      _gate(gates[2], 1)
      with open(diagnostic_lock, "a") as lock:
        deadline = time.monotonic() + 0.5
        while True:
          try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
          except BlockingIOError:
            if time.monotonic() >= deadline:
              raise TimeoutError("peer ALSA diagnostic did not finish")
            time.sleep(0.005)
        diagnostic = {"started": time.monotonic(), "card_state": _card_state()}
        result["diagnostic"] = diagnostic
        _write(output + ".diagnostic", result)
        diagnostic["raw_alsa"] = _raw_alsa(role)
        diagnostic["cached_after_raw"] = _device_snapshot(sd)
        _write(output + ".diagnostic", result)
        sd._terminate()
        sd._initialize()
        diagnostic["after_reinitialize"] = _device_snapshot(sd)
    except Exception:
      result["diagnostic_error"] = traceback.format_exc()
  result["finished"] = time.monotonic()
  _write(output, result)


def _read(path):
  try:
    return json.loads(Path(path).read_text())
  except (OSError, ValueError):
    return None


def _pair(directory, duration, timeout):
  gates = [os.pipe() for _ in range(3)]
  paths = {role: str(directory / (role + ".json")) for role in STREAMS}
  processes = {}
  open_fds = {fd for pair in gates for fd in pair}

  def close_fd(fd):
    if fd in open_fds:
      os.close(fd)
      open_fds.remove(fd)

  started = time.monotonic()
  deadline = started + timeout
  try:
    for role, path in paths.items():
      args = [sys.executable, str(Path(__file__).resolve()), "_client", role, path, str(duration),
              *[str(reader) for reader, _ in gates], str(directory / "diagnostic.lock")]
      processes[role] = subprocess.Popen(args, stdin=subprocess.DEVNULL, pass_fds=tuple(reader for reader, _ in gates),
                                         env=os.environ | {'BOOT_AUDIO_TIMEOUT': str(timeout)})
    for reader, _ in gates:
      close_fd(reader)
    # Align both the first import and the explicit reinitialization used by micd/soundd.
    for (_, writer), suffix in zip(gates[:2], (".ready", ".imported")):
      while time.monotonic() < deadline:
        if all(Path(path + suffix).exists() or Path(path + ".initial").exists() or processes[role].poll() is not None
               for role, path in paths.items()):
          break
        time.sleep(0.005)
      close_fd(writer)
    while time.monotonic() < deadline:
      if all(Path(path + ".initial").exists() or processes[role].poll() is not None for role, path in paths.items()):
        break
      time.sleep(0.005)
    unfinished = [role for role, path in paths.items() if not Path(path + ".initial").exists()]
    for role in unfinished:
      snapshot = {'role': role, 'pid': processes[role].pid, 'ok': False,
                  'phases': {suffix: _read(paths[role] + suffix) for suffix in ['.ready', '.imported', '.initialized', '.opened']}}
      for field in ['stack', 'wchan', 'status']:
        try:
          snapshot[field] = Path(f'/proc/{processes[role].pid}/{field}').read_text()
        except OSError as e:
          snapshot[field] = str(e)
      _write(paths[role] + '.timeout', snapshot)
      if processes[role].poll() is None:
        processes[role].terminate()
    close_fd(gates[2][1])
    deadline = time.monotonic() + 0.8
    while time.monotonic() < deadline and any(process.poll() is None for process in processes.values()):
      time.sleep(0.005)

    results = []
    for role, process in processes.items():
      if process.poll() is None:
        process.kill()
      try:
        process.wait(timeout=0.05)
      except subprocess.TimeoutExpired:
        pass  # A kernel D-state task remains visible to the coordinator's stack collector.
      result = (_read(paths[role]) or _read(paths[role] + ".diagnostic") or
                _read(paths[role] + ".initial") or _read(paths[role] + '.timeout') or {"role": role, "pid": process.pid, "ok": False})
      if role in unfinished or process.poll() != 0:
        result.update(ok=False, child_exitcode=process.returncode, child_alive=process.poll() is None,
                      error=result.get("error", "audio client exceeded its deadline or exited before reporting"))
      results.append(result)
    return {"ok": all(result["ok"] for result in results), "seconds": time.monotonic() - started, "clients": results}
  finally:
    for process in processes.values():
      if process.poll() is None:
        process.kill()
        try:
          process.wait(timeout=0.05)
        except subprocess.TimeoutExpired:
          pass
    for fd in list(open_fds):
      close_fd(fd)


def run(options):
  if options.get('audio_mode', 'raw') == 'raw':
    # No PortAudio/NumPy import or device-list cache: exercise ALSA's actual
    # open/configure/prepare contract immediately, once per direction.
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
      results = dict(zip(STREAMS, pool.map(_raw_alsa, STREAMS)))
    return {'ok': all(all(info.get(key) == 0 for key in ['open', 'configure', 'prepare']) for info in results.values()),
            'card_state': _card_state(), 'alsa': results,
            'coverage': 'ALSA duplex open/configure/prepare; audio-clients profile checks streaming callbacks'}
  if "sounddevice" in sys.modules:
    return {"ok": False, "error": "audio probe must run in a fresh worker; parent has already initialized sounddevice"}
  iterations = int(options.get("iterations", 3))
  duration = float(options.get("duration", 0.15))
  timeout = float(options.get("audio_timeout", 5))
  if not 1 <= iterations <= 100 or not 0.1 <= duration <= 1 or not duration < timeout <= 10:
    raise ValueError("invalid audio iterations/duration/timeout")
  nodes = []
  for name in sorted(glob.glob("/dev/snd/*")):
    try:
      info = os.stat(name)
    except OSError as e:
      nodes.append({"path": name, "error": str(e)})
      continue
    if stat.S_ISCHR(info.st_mode):
      nodes.append({"path": name, "uid": info.st_uid, "gid": info.st_gid,
                    "mode": oct(stat.S_IMODE(info.st_mode)), "accessible": os.access(name, os.R_OK | os.W_OK)})
  result = {"ok": True, "card_state": _card_state(), "nodes": nodes,
            "iterations_requested": iterations, "pairs": []}
  # Regular files avoid a full result pipe blocking a failing child's exit.
  if options.get('artifact_dir'):
    directory = Path(options['artifact_dir']) / 'audio'
    directory.mkdir(parents=True, exist_ok=True)
    storage = contextlib.nullcontext(str(directory))
  else:
    storage = tempfile.TemporaryDirectory(prefix="boot-audio-")
  with storage as temporary:
    for index in range(iterations):
      directory = Path(temporary) / str(index)
      directory.mkdir()
      pair = _pair(directory, duration, timeout)
      result["pairs"].append(pair)
      if not pair["ok"]:
        result["ok"] = False
        break
  return result


if __name__ == "__main__":
  if len(sys.argv) != 9 or sys.argv[1] != "_client":
    raise SystemExit("internal audio client; use test_boot_resources.py")
  _client(sys.argv[2], [int(fd) for fd in sys.argv[5:8]], sys.argv[8], sys.argv[3], float(sys.argv[4]))
