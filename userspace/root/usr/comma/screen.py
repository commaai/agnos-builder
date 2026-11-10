#!/usr/local/venv/bin/python
"""Look at and touch the screen without a person.

usage: /usr/comma/screen.py COMMAND [COMMAND ...]

  screenshot [PATH]          PNG of the screen, upright. waits up to 3s for it to stop changing.
                             PATH defaults to stdout when that isn't a terminal, else /tmp/screen.png
  tap X Y                    tap at screenshot pixel X, Y, origin top left
  swipe X0 Y0 X1 Y1 [MS]     drag from X0, Y0 to X1, Y1 over MS milliseconds (default 300).
                             scrollers fling on fast swipes; use ~1000 to stop where the finger does
  sleep SECONDS

Commands run in order, so one call can act and then look:

  ssh DEVICE /usr/comma/screen.py tap 315 120 screenshot > after.png

Screenshots are small enough that viewers show them at full size, and taps use
the same pixels. stdout only carries the PNG. stderr reports each screenshot's
size, and says when the screen was still changing after the wait.

Run it as is, not with python3 or sudo. Screenshots read the buffer being
scanned out. Touches are written to the touchscreen's own event node, so every
reader gets them like real ones.
"""
import ctypes
import fcntl
import mmap
import os
import struct
import sys
import time
import zlib

# before the slow imports
if __name__ == "__main__" and os.geteuid() != 0 and len(sys.argv) > 1:
  os.execvp("sudo", ["sudo", sys.executable, os.path.abspath(__file__), *sys.argv[1:]])

import evdev
import numpy as np
from evdev import ecodes as e

# screenshots are downscaled by a whole number to fit in this, so viewers don't rescale them
MAX_SIZE = 1280

# the UI draws rotated in the panel's portrait framebuffer. np.rot90 turns to make it upright
ROTATION = {"comma mici": -1, "comma tizi": 1}


def _scale(width, height):
  return -(-max(width, height) // MAX_SIZE)


def _rotation():
  with open("/sys/firmware/devicetree/base/model") as f:
    return ROTATION.get(f.read().strip("\x00 \n"), 0)


def _iowr(nr, size):
  return (3 << 30) | (size << 16) | (ord("d") << 8) | nr


class _PlaneRes(ctypes.Structure):
  _fields_ = [("plane_id_ptr", ctypes.c_uint64), ("count_planes", ctypes.c_uint32)]

class _Plane(ctypes.Structure):
  _fields_ = [("plane_id", ctypes.c_uint32), ("crtc_id", ctypes.c_uint32), ("fb_id", ctypes.c_uint32),
              ("possible_crtcs", ctypes.c_uint32), ("gamma_size", ctypes.c_uint32),
              ("count_format_types", ctypes.c_uint32), ("format_type_ptr", ctypes.c_uint64)]

class _FB(ctypes.Structure):
  _fields_ = [("fb_id", ctypes.c_uint32), ("width", ctypes.c_uint32), ("height", ctypes.c_uint32),
              ("pitch", ctypes.c_uint32), ("bpp", ctypes.c_uint32), ("depth", ctypes.c_uint32),
              ("handle", ctypes.c_uint32)]

class _FB2(ctypes.Structure):
  _fields_ = [("fb_id", ctypes.c_uint32), ("width", ctypes.c_uint32), ("height", ctypes.c_uint32),
              ("pixel_format", ctypes.c_uint32), ("flags", ctypes.c_uint32), ("handles", ctypes.c_uint32 * 4),
              ("pitches", ctypes.c_uint32 * 4), ("offsets", ctypes.c_uint32 * 4), ("modifier", ctypes.c_uint64 * 4)]

class _Prime(ctypes.Structure):
  _fields_ = [("handle", ctypes.c_uint32), ("flags", ctypes.c_uint32), ("fd", ctypes.c_int32)]

class _Cap(ctypes.Structure):
  _fields_ = [("cap", ctypes.c_uint64), ("value", ctypes.c_uint64)]

_SET_CLIENT_CAP = (1 << 30) | (ctypes.sizeof(_Cap) << 16) | (ord("d") << 8) | 0x0D
_GEM_CLOSE = (1 << 30) | (8 << 16) | (ord("d") << 8) | 0x09
_GETFB = _iowr(0xAD, ctypes.sizeof(_FB))
_GETFB2 = _iowr(0xCE, ctypes.sizeof(_FB2))
_GETPLANERESOURCES = _iowr(0xB5, ctypes.sizeof(_PlaneRes))
_GETPLANE = _iowr(0xB6, ctypes.sizeof(_Plane))
_PRIME_HANDLE_TO_FD = _iowr(0x2D, ctypes.sizeof(_Prime))
_UNIVERSAL_PLANES = 2

# byte offsets of R, G, B in each little-endian 32-bit pixel
_FORMATS = {b"AB24": (0, 1, 2), b"XB24": (0, 1, 2), b"AR24": (2, 1, 0), b"XR24": (2, 1, 0)}


def _scanout_planes(fd):
  res = _PlaneRes()
  fcntl.ioctl(fd, _GETPLANERESOURCES, res)
  ids = (ctypes.c_uint32 * res.count_planes)()
  res.plane_id_ptr = ctypes.addressof(ids)
  fcntl.ioctl(fd, _GETPLANERESOURCES, res)
  planes = []
  for plane_id in ids:
    p = _Plane(plane_id=plane_id)
    fcntl.ioctl(fd, _GETPLANE, p)
    if p.fb_id:
      planes.append(p)
  return planes


def _read_fb(fd, fb_id):
  fb = _FB(fb_id=fb_id)
  fcntl.ioctl(fd, _GETFB, fb)
  if not fb.handle:
    raise PermissionError("reading the framebuffer needs root")
  try:
    fourcc = b"AB24"  # what the UI allocates. kernels with GETFB2 report it
    fb2 = _FB2(fb_id=fb_id)
    try:
      fcntl.ioctl(fd, _GETFB2, fb2)
      fourcc = struct.pack("<I", fb2.pixel_format)
      for h in set(fb2.handles) - {0, fb.handle}:
        fcntl.ioctl(fd, _GEM_CLOSE, struct.pack("II", h, 0))
    except OSError:
      pass
    if fourcc not in _FORMATS:
      raise NotImplementedError(f"pixel format {fourcc.decode()}")

    prime = _Prime(handle=fb.handle, flags=os.O_CLOEXEC)
    fcntl.ioctl(fd, _PRIME_HANDLE_TO_FD, prime)
    try:
      with mmap.mmap(prime.fd, fb.pitch * fb.height, mmap.MAP_SHARED, mmap.PROT_READ) as m:
        px = np.frombuffer(m, np.uint8).reshape(fb.height, fb.pitch)[:, :fb.width * 4].reshape(fb.height, fb.width, 4)
        img = px[:, :, list(_FORMATS[fourcc])]
        del px  # the mmap can't close while a view of it exists
      return img
    finally:
      os.close(prime.fd)
  finally:
    fcntl.ioctl(fd, _GEM_CLOSE, struct.pack("II", fb.handle, 0))


def _grab(fd):
  for _ in range(5):
    planes = _scanout_planes(fd)
    if len(planes) != 1:
      raise RuntimeError(f"expected one plane scanning out, found {len(planes)}")
    img = _read_fb(fd, planes[0].fb_id)
    # a page flip during the copy can hand the buffer back to the renderer
    if [p.fb_id for p in _scanout_planes(fd)] == [planes[0].fb_id]:
      return img
  raise RuntimeError("the screen kept flipping during the copy")


def screenshot(settle=3.0):
  """Upright RGB array (height, width, 3) of what the panel is scanning out,
  and whether it stopped changing.

  Waits up to `settle` seconds for the screen to stop changing, ignoring
  changes as small as a blinking cursor.
  """
  fd = os.open("/dev/dri/card0", os.O_RDWR | os.O_CLOEXEC)
  try:
    fcntl.ioctl(fd, _SET_CLIENT_CAP, _Cap(_UNIVERSAL_PLANES, 1))
    deadline = time.monotonic() + settle
    img, settled = _grab(fd), False
    while not settled and time.monotonic() < deadline:
      time.sleep(0.15)
      prev, img = img, _grab(fd)
      settled = np.count_nonzero((prev != img).any(axis=2)) < img.shape[0] * img.shape[1] // 1000
    h, w, _ = img.shape
    n = _scale(w, h)
    img = img[:h - h % n, :w - w % n].reshape(h // n, n, w // n, n, 3).mean(axis=(1, 3)).astype(np.uint8)
    return np.rot90(img, _rotation()), settled
  finally:
    os.close(fd)


def write_png(img, f):
  h, w, _ = img.shape
  raw = np.zeros((h, w * 3 + 1), np.uint8)
  raw[:, 1:] = img.reshape(h, w * 3)

  def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
  f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
          chunk(b"IDAT", zlib.compress(raw.tobytes(), 1)) + chunk(b"IEND", b""))


class Touchscreen:
  def __init__(self):
    for path in evdev.list_devices():
      dev = evdev.InputDevice(path)
      absinfo = dict(dev.capabilities(absinfo=True).get(e.EV_ABS, []))
      dev.close()
      if e.ABS_MT_POSITION_X in absinfo:
        self.width, self.height = absinfo[e.ABS_MT_POSITION_X].max, absinfo[e.ABS_MT_POSITION_Y].max
        self.fd = os.open(path, os.O_WRONLY | os.O_CLOEXEC)
        break
    else:
      raise RuntimeError("no touchscreen found")
    self.k = _rotation() % 4
    self.n = _scale(self.width, self.height)
    w, h = self.width // self.n, self.height // self.n
    self.size = (h, w) if self.k % 2 else (w, h)

  def close(self):
    os.close(self.fd)

  def __enter__(self):
    return self

  def __exit__(self, *_):
    self.close()

  def _native(self, x, y):
    if not (0 <= x < self.size[0] and 0 <= y < self.size[1]):
      raise ValueError(f"{x}, {y} is off the {self.size[0]}x{self.size[1]} screen")
    x, y = x * self.n + self.n // 2, y * self.n + self.n // 2
    # inverse of screenshot()'s np.rot90
    if self.k == 1:
      return self.width - 1 - y, x
    if self.k == 2:
      return self.width - 1 - x, self.height - 1 - y
    if self.k == 3:
      return y, self.height - 1 - x
    return x, y

  def _write(self, *events):
    os.write(self.fd, b"".join(struct.pack("llHHi", 0, 0, t, c, v) for t, c, v in events) +
             struct.pack("llHHi", 0, 0, e.EV_SYN, e.SYN_REPORT, 0))

  def _move(self, x, y):
    nx, ny = self._native(x, y)
    self._write((e.EV_ABS, e.ABS_MT_POSITION_X, nx), (e.EV_ABS, e.ABS_MT_POSITION_Y, ny))

  def down(self, x, y):
    nx, ny = self._native(x, y)
    self._write((e.EV_ABS, e.ABS_MT_SLOT, 0), (e.EV_ABS, e.ABS_MT_TRACKING_ID, 0xC0A),
                (e.EV_ABS, e.ABS_MT_POSITION_X, nx), (e.EV_ABS, e.ABS_MT_POSITION_Y, ny),
                (e.EV_ABS, e.ABS_MT_PRESSURE, 50), (e.EV_ABS, e.ABS_MT_TOUCH_MAJOR, 10),
                (e.EV_KEY, e.BTN_TOUCH, 1))

  def up(self):
    self._write((e.EV_ABS, e.ABS_MT_SLOT, 0), (e.EV_ABS, e.ABS_MT_TRACKING_ID, -1), (e.EV_KEY, e.BTN_TOUCH, 0))

  def tap(self, x, y, hold=0.1):
    self.down(x, y)
    time.sleep(hold)
    self.up()
    time.sleep(0.05)  # so back-to-back taps land in separate frames

  def swipe(self, x0, y0, x1, y1, duration=0.3):
    self.down(x0, y0)
    steps = max(1, int(duration * 60))
    for i in range(1, steps + 1):
      time.sleep(duration / steps)
      self._move(x0 + (x1 - x0) * i // steps, y0 + (y1 - y0) * i // steps)
    self.up()
    time.sleep(0.05)


ARITY = {"screenshot": (0, 1), "tap": (2, 2), "swipe": (4, 5), "sleep": (1, 1)}


def parse(argv):
  cmds = []
  for arg in argv:
    if arg in ARITY:
      cmds.append([arg])
    elif cmds and len(cmds[-1]) - 1 < ARITY[cmds[-1][0]][1]:
      cmds[-1].append(arg)
    else:
      raise ValueError(f"unexpected {arg!r}")
  for cmd, *args in cmds:
    if len(args) < ARITY[cmd][0]:
      raise ValueError(f"{cmd} needs {ARITY[cmd][0]} arguments")
    if cmd in ("tap", "swipe", "sleep"):
      for a in args:
        float(a)
  return cmds


def main(argv):
  try:
    cmds = parse(argv)
  except ValueError as err:
    sys.exit(f"screen.py: {err}\n\n{__doc__}")
  if not cmds:
    print(__doc__)
    return

  touch = None
  try:
    for cmd, *args in cmds:
      if cmd == "screenshot":
        img, settled = screenshot()
        path = args[0] if args else ("/tmp/screen.png" if sys.stdout.isatty() else "-")
        if path == "-":
          write_png(img, sys.stdout.buffer)
          sys.stdout.buffer.flush()
        else:
          with open(path, "wb") as f:
            write_png(img, f)
        print(f"screenshot {img.shape[1]}x{img.shape[0]}" + ("" if path == "-" else f" saved to {path}") +
              ("" if settled else ", still changing after 3s"), file=sys.stderr)
      elif cmd == "sleep":
        time.sleep(float(args[0]))
      else:
        touch = touch or Touchscreen()
        if cmd == "tap":
          touch.tap(*map(int, args))
        else:
          touch.swipe(*map(int, args[:4]), *([int(args[4]) / 1000] if len(args) == 5 else []))
  except ValueError as err:
    sys.exit(f"screen.py: {err}")
  finally:
    if touch:
      touch.close()


if __name__ == "__main__":
  main(sys.argv[1:])
