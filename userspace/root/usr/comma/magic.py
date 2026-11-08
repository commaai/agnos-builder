#!/usr/bin/env python3
import os, socket, struct, threading, time
from array import array

import pyray as rl

SOCK_PATH = "/tmp/drmfd.sock"
DRM_DEVICE = "/dev/dri/card0"
BACKGROUND = "/usr/comma/bg.png"
GAMMA_CURVES_FILE = "/persist/comma/dwo_gamma_curves"
COMMAND_FD = 3 if os.getenv("LISTEN_FDS") == "1" and os.getenv("LISTEN_FDNAMES") == "mipi_command" else None

GAMMA_ADDR = [
  [(0x00, 0x01), (0x02, 0x03), (0x04, 0x05), (0x06, 0x07), (0x08, 0x09), (0x0A, 0x0B), (0x0C, 0x0D), (0x0E, 0x0F), (0x10, 0x11), (0x12, 0x13), (0x14, 0x15), (0x16, 0x17), (0x18, 0x19), (0x1A, 0x1B), (0x1C, 0x1D), (0x1E, 0x1F), (0x20, 0x21), (0x22, 0x23), (0x24, 0x25), (0x26, 0x27), (0x28, 0x29), (0x2A, 0x2B), (0x2D, 0x2F), (0x30, 0x31), (0x32, 0x33)],
  [(0x34, 0x35), (0x36, 0x37), (0x38, 0x39), (0x3A, 0x3B), (0x3D, 0x3F), (0x40, 0x41), (0x42, 0x43), (0x44, 0x45), (0x46, 0x47), (0x48, 0x49), (0x4A, 0x4B), (0x4C, 0x4D), (0x4E, 0x4F), (0x50, 0x51), (0x52, 0x53), (0x54, 0x55), (0x56, 0x58), (0x59, 0x5A), (0x5B, 0x5C), (0x5D, 0x5E), (0x5F, 0x60), (0x61, 0x62), (0x63, 0x64), (0x65, 0x66), (0x67, 0x68)],
  [(0x69, 0x6A), (0x6B, 0x6C), (0x6D, 0x6E), (0x6F, 0x70), (0x71, 0x72), (0x73, 0x74), (0x75, 0x76), (0x77, 0x78), (0x79, 0x7A), (0x7B, 0x7C), (0x7D, 0x7E), (0x7F, 0x80), (0x81, 0x82), (0x83, 0x84), (0x85, 0x86), (0x87, 0x88), (0x89, 0x8A), (0x8B, 0x8C), (0x8D, 0x8E), (0x8F, 0x90), (0x91, 0x92), (0x93, 0x94), (0x95, 0x96), (0x97, 0x98), (0x99, 0x9A)],
]

def power_screen():
  try:
    with open("/sys/class/backlight/panel0-backlight/bl_power", "w") as f:
      f.write("0")
    with open("/sys/class/backlight/panel0-backlight/max_brightness") as f:
      max_brightness = int((int(f.read().strip()) / 100) * 65)
    with open("/sys/class/backlight/panel0-backlight/brightness", "w") as f:
      f.write(str(max_brightness))
  except Exception:
    pass

def show_background(tex, pos):
  rl.begin_drawing()
  rl.draw_texture(tex, int(pos.x), int(pos.y), rl.WHITE)
  rl.end_drawing()
  power_screen()

def handle_client(client, drm_master):
  try:
    drm_master_dup = os.dup(drm_master)
    client.sendmsg([b"x"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array("i", [drm_master_dup]).tobytes())])
    client.recv(1)
  except Exception:
    pass
  finally:
    try:
      os.close(drm_master_dup)
      client.close()
    except Exception:
      pass

def command_mode(mode):
  return f"39 01 00 00 0A 00 02 FE {((0b1010 << 4) | mode):02X}"

def pack_command(command_str):
  command_buf = bytes(map(lambda x: int(x, base=16), command_str.strip().split()))
  return struct.pack(f"i{len(command_buf)}s", len(command_buf), command_buf)

def set_gamma(gamma):
  cmds = [command_mode(2)]
  for color_idx in range(3):
    for i, val in reversed(list(enumerate(gamma[color_idx]))):
      msb, lsb = GAMMA_ADDR[color_idx][i]
      cmds.append(f"39 0F 00 00 0A 00 02 {msb:02X} {(val >> 8) & 0xFF:02X}")
      cmds.append(f"39 {'01' if i % 10 == 0 else '0F'} 00 00 0A 00 02 {lsb:02X} {val & 0xFF:02X}")
  cmds.append(command_mode(0))

  data = b"".join(pack_command(c) for c in cmds)
  with open(COMMAND_FD, "wb") as f:
    f.write(data)

def set_screen_calibration():
  if COMMAND_FD is None:
    print("No screen calibration device supplied")
    return

  if not os.path.exists(GAMMA_CURVES_FILE):
    print("No gamma curves found")
    return

  with open(GAMMA_CURVES_FILE, "r") as f:
    gamma = [[int(x, 16) for x in l.strip().split()] for l in f]

  set_gamma(gamma)
  print("Successfully setup screen calibration")

def main():
  # listen first so comma.sh can start setup while magic loads. clients wait for accept()
  # below, which comes after the background is drawn
  try:
    os.unlink(SOCK_PATH)
  except FileNotFoundError:
    pass

  server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
  server.bind(SOCK_PATH)
  server.settimeout(0.1)
  server.listen(1)

  while True:
    try:
      drm_master = os.open(DRM_DEVICE, os.O_RDWR | os.O_CLOEXEC)
      break
    except Exception as e:
      print(e)
      time.sleep(0.1)

  os.environ['DRM_FD'] = str(drm_master)
  rl.init_window(0, 0, "not weston")
  img = rl.load_image(BACKGROUND)
  rl.image_resize(img, rl.get_screen_width(), rl.get_screen_width()//2)
  tex = rl.load_texture_from_image(img)
  rl.set_texture_filter(tex, rl.TextureFilter.TEXTURE_FILTER_BILINEAR)
  pos = rl.Vector2((rl.get_screen_width() - tex.width)/2.0, (rl.get_screen_height() - tex.height)/2.0)
  rl.unload_image(img)
  show_background(tex, pos)

  # the panel only takes this once it's on, and loses it when magic restarts
  threading.Thread(target=set_screen_calibration, daemon=True).start()

  clients = set()
  need_background = False

  while True:
    dead = [t for t in list(clients) if not t.is_alive()]
    for t in dead:
      t.join()
      clients.discard(t)
    if not clients and need_background:
      need_background = False
      show_background(tex, pos)

    try:
      client, _ = server.accept()
    except Exception:
      continue

    need_background = True
    t = threading.Thread(target=handle_client, args=(client, drm_master), daemon=True)
    t.start()
    clients.add(t)

if __name__ == "__main__":
  main()
