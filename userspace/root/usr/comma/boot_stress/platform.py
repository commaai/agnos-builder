"""User-level boot probes. Importing this module does not open any device."""

import ctypes
import fcntl
import mmap
import os
import signal
import socket
import struct
import tempfile
import time


def _ioc(direction, kind, number, size):
  return direction << 30 | size << 16 | ord(kind) << 8 | number


def _ioctl(fd, request, value):
  # These UAPIs contain pointers, so keep the ctypes objects alive for the call.
  libc = ctypes.CDLL(None, use_errno=True)
  libc.ioctl.argtypes = (ctypes.c_int, ctypes.c_ulong, ctypes.c_void_p)
  libc.ioctl.restype = ctypes.c_int
  if libc.ioctl(fd, request, ctypes.byref(value)) < 0:
    error = ctypes.get_errno()
    raise OSError(error, f"ioctl 0x{request:x}: {os.strerror(error)}")


class _GpuProperty(ctypes.Structure):
  _fields_ = [("type", ctypes.c_uint), ("value", ctypes.c_void_p), ("size", ctypes.c_size_t)]


class _GpuVersion(ctypes.Structure):
  _fields_ = [(name, ctypes.c_uint) for name in ("driver_major", "driver_minor", "device_major", "device_minor")]


class _GpuContext(ctypes.Structure):
  _fields_ = [("flags", ctypes.c_uint), ("id", ctypes.c_uint)]


def gpu(options):
  # kgsl_open_device starts the GPU, including its zap firmware, before returning.
  # Do not move this open (or a GPU library import) ahead of the selected first-use delay.
  with open("/dev/kgsl-3d0", "r+b", buffering=0) as device:
    version = _GpuVersion()
    prop = _GpuProperty(0x8, ctypes.addressof(version), ctypes.sizeof(version))  # KGSL_PROP_VERSION
    _ioctl(device.fileno(), _ioc(3, "\x09", 0x02, ctypes.sizeof(prop)), prop)
    if not version.driver_major:
      raise RuntimeError("KGSL returned an empty driver version")

    # A6xx requires PREAMBLE and NO_GMEM_ALLOC, and accepts a CL context type.
    context = _GpuContext(0x10 | 0x2 | 0x40 | (2 << 20), 0)
    _ioctl(device.fileno(), _ioc(3, "\x09", 0x13, ctypes.sizeof(context)), context)
    try:
      if not context.id:
        raise RuntimeError("KGSL returned an invalid draw context")
      result = {"driver_version": [version.driver_major, version.driver_minor],
                "device_version": [version.device_major, version.device_minor],
                "context": context.id,
                "coverage": "GPU startup and draw-context creation; no command submission"}
    finally:
      destroy = ctypes.c_uint(context.id)
      _ioctl(device.fileno(), _ioc(1, "\x09", 0x14, ctypes.sizeof(destroy)), destroy)
  return result


class _DrmCap(ctypes.Structure):
  _fields_ = [("capability", ctypes.c_uint64), ("value", ctypes.c_uint64)]


class _DumbBuffer(ctypes.Structure):
  _fields_ = [(name, ctypes.c_uint32) for name in ("height", "width", "bpp", "flags", "handle", "pitch")] + [("size", ctypes.c_uint64)]


class _DumbMap(ctypes.Structure):
  _fields_ = [("handle", ctypes.c_uint32), ("pad", ctypes.c_uint32), ("offset", ctypes.c_uint64)]


def drm(options):
  # GET_CAP and dumb-buffer ioctls do not require DRM master. Magic keeps its display.
  with open("/dev/dri/card0", "r+b", buffering=0) as device:
    fd = device.fileno()
    cap = _DrmCap(1, 0)  # DRM_CAP_DUMB_BUFFER
    _ioctl(fd, _ioc(3, "d", 0x0c, ctypes.sizeof(cap)), cap)
    if cap.value != 1:
      raise RuntimeError("DRM has no dumb-buffer support")
    buffer = _DumbBuffer(height=64, width=64, bpp=32)
    _ioctl(fd, _ioc(3, "d", 0xb2, ctypes.sizeof(buffer)), buffer)
    try:
      if buffer.size < 64 * 64 * 4 or buffer.pitch < 64 * 4:
        raise RuntimeError("DRM returned an undersized buffer")
      mapping = _DumbMap(buffer.handle, 0, 0)
      _ioctl(fd, _ioc(3, "d", 0xb3, ctypes.sizeof(mapping)), mapping)
      with mmap.mmap(fd, buffer.size, offset=mapping.offset) as pixels:
        pattern = b"\x12\x34\x56\x78" * 64
        pixels[:len(pattern)] = pattern
        if pixels[:len(pattern)] != pattern:
          raise RuntimeError("DRM mapped-buffer write/read mismatch")
      return {"pitch": buffer.pitch, "size": buffer.size,
              "coverage": "dumb-buffer allocation, mapping and CPU access; no modeset or scanout"}
    finally:
      destroy = ctypes.c_uint32(buffer.handle)
      _ioctl(fd, _ioc(3, "d", 0xb4, ctypes.sizeof(destroy)), destroy)


def _fd_roundtrip():
  parent, child = socket.socketpair()
  parent.settimeout(1)
  child.settimeout(1)
  fd = os.memfd_create("boot-resource-test", os.MFD_CLOEXEC)
  pid = None
  try:
    os.ftruncate(fd, mmap.PAGESIZE)
    with mmap.mmap(fd, mmap.PAGESIZE) as memory:
      memory[:6] = b"parent"
      pid = os.fork()
      if pid == 0:
        parent.close()
        os.close(fd)
        try:
          _, received, _, _ = socket.recv_fds(child, 1, 1)
          if len(received) != 1:
            raise RuntimeError("expected one shared-memory FD")
          try:
            with mmap.mmap(received[0], mmap.PAGESIZE) as shared:
              if shared[:6] != b"parent":
                raise RuntimeError("child cannot read shared memory")
              shared[:5] = b"child"
            child.sendall(b"ok")
          finally:
            os.close(received[0])
        except BaseException:
          os._exit(1)
        os._exit(0)
      child.close()
      socket.send_fds(parent, [b"x"], [fd])
      if parent.recv(2) != b"ok" or memory[:5] != b"child":
        raise RuntimeError("cross-process FD/memory transfer failed")
      _, status = os.waitpid(pid, 0)
      pid = None
      if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
        raise RuntimeError(f"FD recipient failed: {status}")
  finally:
    parent.close()
    child.close()
    os.close(fd)
    if pid is not None:
      try:
        os.kill(pid, signal.SIGKILL)
      except ProcessLookupError:
        pass
      os.waitpid(pid, 0)


def filesystem(options):
  if not os.statvfs("/").f_flag & os.ST_RDONLY:
    raise RuntimeError("root filesystem is writable")
  checked = []
  pattern = b"boot-resource-test\0" * 200
  for directory in ("/data", "/data/tmp", "/cache", "/tmp", "/var/tmp", "/dev/shm", os.path.expanduser("~")):
    with tempfile.TemporaryDirectory(prefix="boot-resource-", dir=directory) as temporary:
      with open(os.path.join(temporary, "mapped"), "w+b") as f:
        f.truncate(mmap.PAGESIZE)
        with mmap.mmap(f.fileno(), mmap.PAGESIZE) as memory:
          memory[:len(pattern)] = pattern
          memory.flush()
          os.fsync(f.fileno())
          if memory[:len(pattern)] != pattern:
            raise RuntimeError(f"file mapping mismatch in {directory}")
      # This also exercises each directory's Unix-socket namespace and permissions.
      with socket.socket(socket.AF_UNIX) as listener, socket.socket(socket.AF_UNIX) as client:
        path = os.path.join(temporary, "socket")
        listener.settimeout(1)
        client.settimeout(1)
        listener.bind(path)
        listener.listen(1)
        client.connect(path)
        connection, _ = listener.accept()
        with connection:
          connection.settimeout(1)
          client.sendall(b"ready")
          if connection.recv(5) != b"ready":
            raise RuntimeError(f"Unix socket failed in {directory}")
    checked.append(directory)
  _fd_roundtrip()
  return {"directories": checked, "coverage": "create, mmap, write/read, flush, Unix sockets and cross-process shared-memory FD transfer"}


class _IonAllocation(ctypes.Structure):
  _fields_ = [("length", ctypes.c_size_t), ("alignment", ctypes.c_size_t),
              ("heap_mask", ctypes.c_uint), ("flags", ctypes.c_uint), ("handle", ctypes.c_int)]


class _IonFd(ctypes.Structure):
  _fields_ = [("handle", ctypes.c_int), ("fd", ctypes.c_int)]


def _ion_buffer():
  with open("/dev/ion", "r+b", buffering=0) as ion:
    allocation = _IonAllocation(mmap.PAGESIZE, mmap.PAGESIZE, 1 << 25, 0, 0)  # ION_SYSTEM_HEAP_ID
    _ioctl(ion.fileno(), _ioc(3, "I", 0, ctypes.sizeof(allocation)), allocation)
    try:
      share = _IonFd(allocation.handle, -1)
      _ioctl(ion.fileno(), _ioc(3, "I", 4, ctypes.sizeof(share)), share)
      try:
        with mmap.mmap(share.fd, mmap.PAGESIZE) as memory:
          memory[:4] = b"ion!"
          if memory[:4] != b"ion!":
            raise RuntimeError("ION mapping write/read mismatch")
      finally:
        os.close(share.fd)
    finally:
      handle = ctypes.c_int(allocation.handle)
      _ioctl(ion.fileno(), _ioc(3, "I", 1, ctypes.sizeof(handle)), handle)


def devices(options):
  checked = {}
  touch = "/dev/input/by-path/platform-894000.i2c-event"
  with open(touch, "rb", buffering=0) as device:
    version = bytearray(4)
    fcntl.ioctl(device.fileno(), _ioc(2, "E", 0x01, 4), version)  # EVIOCGVERSION
    checked[touch] = {"event_version": struct.unpack("I", version)[0]}
  # Camera request-manager/sync endpoints are exclusive. The camera probe owns
  # those; an extra open here would create contention that consumers do not have.
  for path in ("/dev/adsprpc-smd",):
    fd = os.open(path, os.O_RDWR | os.O_CLOEXEC)
    os.close(fd)
    checked[path] = "opened read/write"
  # Venus uses the standard V4L2 API; the camera request manager does not.
  with open("/dev/video33", "r+b", buffering=0) as device:
    capability = bytearray(104)
    fcntl.ioctl(device.fileno(), _ioc(2, "V", 0, 104), capability)  # VIDIOC_QUERYCAP
    checked["/dev/video33"] = {"driver": bytes(capability[:16]).split(b"\0")[0].decode(),
                              "capabilities": struct.unpack_from("I", capability, 84)[0]}
  _ion_buffer()
  return {"devices": checked, "ion": "allocated, mapped, written and freed one system-heap page",
          "coverage": "input/codec ioctls and ION allocation; FastRPC endpoint opened, no DSP execution"}


def run(options):
  probes = {"gpu": gpu, "drm": drm, "filesystem": filesystem, "devices": devices}
  started = time.monotonic()
  result = probes[options["probe"]](options)
  return {"ok": True, "duration": time.monotonic() - started, **result}
