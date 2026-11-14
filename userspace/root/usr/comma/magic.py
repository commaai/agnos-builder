#!/usr/bin/env python3
import glob, os, socket, struct, threading, time
from array import array

import pyray as rl

SOCK_PATH = "/tmp/drmfd.sock"
DRM_DEVICE = "/dev/dri/card0"
BACKGROUND = "/usr/comma/bg.png"
GAMMA_CURVES_FILE = "/persist/comma/dwo_gamma_curves"
# the panel driver loads this as /lib/firmware/comma/dwo-do0200fat07-gamma.bin the first time it powers on
GAMMA_FIRMWARE = "/run/panel-firmware/dwo-do0200fat07-gamma.bin"

def power_screen():
  try:
    backlight = glob.glob("/sys/class/backlight/*")[0]
    with open(f"{backlight}/bl_power", "w") as f:
      f.write("0")
    with open(f"{backlight}/max_brightness") as f:
      max_brightness = int((int(f.read().strip()) / 100) * 65)
    with open(f"{backlight}/brightness", "w") as f:
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

def set_screen_calibration():
  if not os.path.exists(GAMMA_CURVES_FILE):
    print("No gamma curves found")
    return

  with open(GAMMA_CURVES_FILE, "r") as f:
    gamma = [[int(x, 16) for x in l.strip().split()] for l in f]

  # 3 channels of 25 big-endian points. packed first, so bad curves leave no file
  data = struct.pack(">75H", *sum(gamma, []))
  with open(GAMMA_FIRMWARE, "wb") as f:
    f.write(data)
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

  # before the first frame, which powers the panel on
  try:
    set_screen_calibration()
  except Exception as e:
    print(f"Failed to set screen calibration: {e}")

  os.environ['DRM_FD'] = str(drm_master)
  rl.init_window(0, 0, "not weston")
  img = rl.load_image(BACKGROUND)
  rl.image_resize(img, rl.get_screen_width(), rl.get_screen_width()//2)
  tex = rl.load_texture_from_image(img)
  rl.set_texture_filter(tex, rl.TextureFilter.TEXTURE_FILTER_BILINEAR)
  pos = rl.Vector2((rl.get_screen_width() - tex.width)/2.0, (rl.get_screen_height() - tex.height)/2.0)
  rl.unload_image(img)
  show_background(tex, pos)

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
