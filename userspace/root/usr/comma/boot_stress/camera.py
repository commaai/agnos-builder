"""Use the installed openpilot camera and hardware encoder consumers, without manager."""
import gc
import hashlib
import os
from pathlib import Path
import resource
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

CAMERAS = ("narrowRoadCameraState", "wideRoadCameraState", "cabinCameraState")
ENCODERS = ("narrowRoadEncodeData", "wideRoadEncodeData", "cabinEncodeData")
# Native encoderd also creates this publisher and waits for its subscriber.
AUX_ENCODERS = ("qNarrowRoadEncodeData",)


def validate_frames(streams, minimum=3, camera_states=True):
  """Validate every received frame, including startup; never trim a warmup window."""
  errors = []
  for name, frames in streams.items():
    if len(frames) < minimum:
      errors.append(f"{name}: only {len(frames)} frames, need {minimum}")
    if camera_states and frames and frames[0]["frameId"] != 0:
      errors.append(f"{name}: first frame was {frames[0]['frameId']}, not zero")
    for frame in frames:
      duration = frame["timestampEof"] - frame["timestampSof"]
      if not 0 < duration < 50_000_000:
        errors.append(f"{name}: invalid readout duration {duration} ns at frame {frame['frameId']}")
    for previous, frame in zip(frames, frames[1:]):
      if frame["frameId"] != previous["frameId"] + 1:
        errors.append(f"{name}: frame IDs skipped {previous['frameId']} -> {frame['frameId']}")
      delta = frame["timestampSof"] - previous["timestampSof"]
      if abs(delta - 50_000_000) >= 5_000_000:
        errors.append(f"{name}: SOF interval {delta / 1e6:.6f} ms at frame {frame['frameId']}")
  names = list(streams)
  if len(names) == 3:
    timestamps = [{frame["frameId"]: frame["timestampSof"] for frame in streams[name]} for name in names]
    common = set(timestamps[0]).intersection(timestamps[1], timestamps[2])
    if minimum and not common:
      errors.append("cameras have no common frame IDs")
    for frame_id in sorted(common):
      road_delta = abs(timestamps[0][frame_id] - timestamps[1][frame_id])
      if road_delta >= 2_000_000:
        errors.append(f"road cameras: SOF offset {road_delta / 1e6:.6f} ms at frame {frame_id}")
      cabin_delta = abs(timestamps[2][frame_id] - timestamps[0][frame_id])
      if not 20_000_000 < cabin_delta < 30_000_000:
        errors.append(f"cabin camera: stagger {cabin_delta / 1e6:.6f} ms at frame {frame_id}")
    if not camera_states and all(streams[name] for name in names):
      first = {streams[name][0]["frameId"] for name in names}
      if len(first) != 1:
        errors.append(f"encoders started on different frame IDs: {sorted(first)}")
  return errors


def _stop(processes):
  """Children inherit the probe's process group, so its supervisor can kill all of them."""
  pending = []
  for process in processes:
    if process.poll() is None:
      process.send_signal(signal.SIGTERM)
      pending.append(process)
  incomplete = []
  for process in pending:
    try:
      process.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
      process.kill()
      try:
        process.wait(timeout=0.2)
      except subprocess.TimeoutExpired:
        incomplete.append(process.pid)
  return incomplete


def _video_fds(pid):
  paths = []
  try:
    for fd in Path(f"/proc/{pid}/fd").iterdir():
      try:
        target = os.readlink(fd)
        if target.startswith("/dev/video"):
          paths.append(target)
      except OSError:
        pass
  except OSError:
    pass
  return sorted(set(paths))


def run(options):
  start = time.monotonic()
  op = Path(options.get("openpilot") or "").resolve()
  if not options.get("openpilot"):
    raise ValueError("camera probe requires --openpilot pointing to a built checkout")
  commands = {name: op / "openpilot/system" / folder / name for name, folder in (("camerad", "camerad"), ("encoderd", "loggerd"))}
  for name, path in commands.items():
    if not path.is_file() or not os.access(path, os.X_OK):
      raise ValueError(f"{name} is not built: {path}")
  rtprio = resource.getrlimit(resource.RLIMIT_RTPRIO)[0]
  if rtprio != resource.RLIM_INFINITY and rtprio < 52:
    raise ValueError("encoderd needs LimitRTPRIO=100 (its real-time priority is 52)")
  frames_needed = int(options.get("frames", 10))
  if not 3 <= frames_needed <= 100:
    raise ValueError("camera frames must be between 3 and 100")
  prefix = "bootcamera_" + uuid.uuid4().hex[:12]
  # A unique prefix keeps Params and IPC separate even if another test has left stale objects.
  # The caller must still stop openpilot: physical camera devices are exclusive.
  paths = [str(op), str(op / "msgq_repo"), str(op / "opendbc_repo")]
  old_path = sys.path[:]
  old_env = {key: os.environ.get(key) for key in ("OPENPILOT_PREFIX", "PARAMS_ROOT", "LOG_ROOT", "PYTHONPATH")}
  streams = {name: [] for name in CAMERAS}
  encoded = {name: [] for name in ENCODERS}
  aux_encoded = {name: [] for name in AUX_ENCODERS}
  processes = []
  logs = {}
  log_paths = {}
  sockets = {}
  errors = []
  result = {"probe": "camera", "prefix": prefix, "frames_requested": frames_needed,
            "coverage": "first camera frames and hardware HEVC packets; no image quality or decode check"}
  shm = Path("/dev/shm") / ("msgq_" + prefix)
  with tempfile.TemporaryDirectory(prefix="boot-camera-") as directory:
    directory = Path(directory)
    artifacts = Path(options.get("artifact_dir") or directory)
    try:
      artifacts.mkdir(parents=True, exist_ok=True)
      os.environ.update(OPENPILOT_PREFIX=prefix, PARAMS_ROOT=str(directory / "params"),
                        LOG_ROOT=str(directory / "logs"), PYTHONPATH=os.pathsep.join(paths))
      sys.path[:0] = paths
      shm.mkdir(mode=0o775)
      from openpilot.common.params import Params
      from openpilot.cereal import messaging

      params = Params()
      params.put_bool("RecordFront", True, block=True)
      params.put_bool("RecordAudio", False, block=True)
      params.put_bool("IsOffroad", True, block=True)
      # Subscribe before either producer exists; conflate=False preserves startup frames.
      sockets = {name: messaging.sub_sock(name, conflate=False, timeout=0) for name in CAMERAS + ENCODERS + AUX_ENCODERS}
      result["consumer_start_monotonic"] = time.monotonic()
      result["native_consumer_pids"] = {}
      for name in ("encoderd", "camerad"):
        log_paths[name] = artifacts / ("camera-" + name + ".log")
        log = log_paths[name].open("wb")
        logs[name] = log
        processes.append(subprocess.Popen([str(commands[name])], cwd=commands[name].parent,
                                          stdout=log, stderr=subprocess.STDOUT))
        result["native_consumer_pids"][name] = processes[-1].pid
      deadline = time.monotonic() + float(options.get("camera_timeout", 6.0))
      while time.monotonic() < deadline:
        for name, sock in sockets.items():
          for message in messaging.drain_sock(sock):
            if not message.valid:
              errors.append(f"{name}: invalid message")
            body = getattr(message, name)
            index = body if name in CAMERAS else body.idx
            sample = {field: int(getattr(index, field)) for field in ("frameId", "timestampSof", "timestampEof")}
            if name in CAMERAS:
              if not streams[name]:
                result.setdefault("first_message_monotonic", {})[name] = time.monotonic()
              streams[name].append(sample)
            else:
              size = len(body.data)
              sample.update(bytes=size, declared_bytes=int(index.len), width=int(body.width), height=int(body.height),
                            codec=str(index.type), sha256=hashlib.sha256(bytes(body.data)).hexdigest())
              if size <= 0 or size != index.len or body.width <= 0 or body.height <= 0:
                errors.append(f"{name}: invalid encoded packet: {sample}")
              expected_codec = "fullHEVC" if name in ENCODERS else "qcameraH264"
              if str(index.type) != expected_codec:
                errors.append(f"{name}: expected {expected_codec}, got {index.type}")
              (encoded if name in ENCODERS else aux_encoded)[name].append(sample)
        errors += validate_frames(streams, minimum=0)
        errors += validate_frames(encoded, minimum=0, camera_states=False)
        dead = [process for process in processes if process.poll() is not None]
        if dead:
          errors.extend(f"native consumer pid {process.pid} exited {process.returncode}" for process in dead)
        if errors:
          break
        if all(len(frames) >= frames_needed for frames in list(streams.values()) + list(encoded.values()) + list(aux_encoded.values())):
          break
        time.sleep(0.005)
      errors += validate_frames(streams, minimum=frames_needed)
      errors += validate_frames(encoded, minimum=frames_needed, camera_states=False)
      errors += validate_frames(aux_encoded, minimum=frames_needed, camera_states=False)
      result["encoder_video_fds"] = _video_fds(processes[0].pid)
      if not result["encoder_video_fds"]:
        errors.append("encoderd held no V4L2 device descriptor")
      # Check that encoded metadata still identifies the same physical frames.
      for camera, encoder in zip(CAMERAS, ENCODERS):
        state = {frame["frameId"]: frame for frame in streams[camera]}
        for frame in encoded[encoder]:
          match = state.get(frame["frameId"])
          if match is None or any(match[field] != frame[field] for field in ("timestampSof", "timestampEof")):
            errors.append(f"{encoder}: encoded frame {frame['frameId']} does not match camera metadata")
    except Exception as error:
      errors.append(f"{type(error).__name__}: {error}")
    finally:
      incomplete = _stop(processes)
      result["incomplete_native_pids"] = incomplete
      if incomplete:
        errors.append(f"native consumers did not exit after SIGKILL: {incomplete}")
      for name, log in logs.items():
        log.close()
        data = log_paths[name].read_bytes()
        if options.get("artifact_dir"):
          result[name + "_log_path"] = str(log_paths[name])
        result[name + "_log"] = (data[:8192] + (b"\n...\n" if len(data) > 16384 else b"") + data[-8192:] if len(data) > 16384 else data).decode(errors="replace")
      sockets.clear()
      gc.collect()
      shutil.rmtree(shm, ignore_errors=True)
      for path in Path("/tmp").glob(prefix + "_visionipc_*"):
        try:
          path.unlink()
        except OSError:
          pass
      sys.path[:] = old_path
      for key, value in old_env.items():
        if value is None:
          os.environ.pop(key, None)
        else:
          os.environ[key] = value
  result.update(ok=not errors, errors=list(dict.fromkeys(errors)), camera_frames=streams, encoded_frames=encoded, auxiliary_encoded_frames=aux_encoded,
                elapsed=time.monotonic() - start)
  return result
