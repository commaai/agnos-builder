#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/fsuid.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <drm/drm.h>
#include <drm/drm_mode.h>
#include <linux/input.h>

static const char *USAGE =
  "Look at and touch the screen virtually.\n"
  "\n"
  "usage: %1$s COMMAND [COMMAND ...]\n"
  "\n"
  "  screenshot [--now] [PATH]  PNG of the screen, upright, once it's (mostly) stopped changing, up to\n"
  "                             3s. --now takes it right away, mid-animation if one is running.\n"
  "                             PATH is on the device, - is stdout. without one it goes to stdout when\n"
  "                             that isn't a terminal, so over SSH `screenshot > local.png` saves it on\n"
  "                             your side, and to /tmp/screen.png when it is\n"
  "  tap X Y                    tap at screenshot pixel X, Y, origin top left\n"
  "  swipe X0 Y0 X1 Y1 [MS]     drag from X0, Y0 to X1, Y1 over MS milliseconds (default 300, up to 10000).\n"
  "                             scrollers fling on fast swipes; use ~1000 to stop where the finger does\n"
  "  record SECONDS DIR         save each frame shown over SECONDS (up to 10) as DIR/MS.png, MS after\n"
  "                             the start, skipping frames that repeat the one before. DIR is on the\n"
  "                             device and must be new or empty. frames are held in memory until the\n"
  "                             end, up to 200MB: about 540 frames on a comma four, 110 on a comma 3x.\n"
  "                             stderr reports the frame rate it caught, which on a comma 3x is below\n"
  "                             the display's, and the longest gap between frames\n"
  "  sleep SECONDS              up to 3600\n"
  "\n"
  "Commands run in order, so one call can act and then look. Taps and swipes are\n"
  "spaced so each one registers, so typing on the keyboard is just a run of taps:\n"
  "\n"
  "  ssh DEVICE %1$s tap 315 120 screenshot > after.png\n"
  "  ssh DEVICE %1$s screenshot /tmp/before.png tap 315 120 screenshot > after.png\n"
  "  ssh DEVICE %1$s tap 315 120 record 1 /tmp/anim\n"
  "\n"
  "Only one screenshot can go to stdout; give the others a PATH on the device.\n"
  "\n"
  "Screenshots are small enough that viewers show them at full size, and taps use\n"
  "the same pixels. stdout only carries the PNG. stderr reports each screenshot's\n"
  "size, says if a small part keeps animating (the rest is still, the frame is fine\n"
  "to use) or it was still changing after 3s, and says if a tap or swipe left every\n"
  "pixel as it was. It exits non-zero only on errors, and checks every command\n"
  "before running any: arguments, that taps and swipes are on the screen, and that\n"
  "PATHs and DIRs can be written.\n"
  "\n"
  "Screenshots read the buffer being scanned out. Touches are written to the\n"
  "touchscreen's own event node, so every reader gets them like real ones.\n";

#define MAX_SIZE 1280  // screenshots are downscaled by a whole number to fit, so viewers don't rescale them

__attribute__((noreturn)) static void die(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fputs("screen: ", stderr);
  vfprintf(stderr, fmt, ap);
  fputc('\n', stderr);
  va_end(ap);
  exit(1);
}

static void *xmalloc(size_t n) {
  void *p = malloc(n);
  if (!p) die("out of memory");
  return p;
}

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void nap(double s) {
  struct timespec ts = {(time_t)s, (long)((s - (time_t)s) * 1e9)};
  while (nanosleep(&ts, &ts) && errno == EINTR) {}
}

// quarter turns counterclockwise that make the UI upright. it draws rotated in the panel's portrait framebuffer
static int rotation(void) {
  char model[64] = {0};
  FILE *f = fopen("/sys/firmware/devicetree/base/model", "r");
  if (f) {
    if (!fread(model, 1, sizeof(model) - 1, f)) model[0] = 0;
    fclose(f);
  }
  if (!strcmp(model, "comma mici")) return 3;
  if (!strcmp(model, "comma tizi")) return 1;
  return 0;
}

static int scale_for(int w, int h) {
  int m = w > h ? w : h;
  return (m + MAX_SIZE - 1) / MAX_SIZE;
}

// *** display ***

// a framebuffer, or a sparse sample of it: every sx-th pixel of every sy-th row. pixels are R, G, B, X
// bytes, the format the UI allocates (the 4.9 kernel has no GETFB2 to ask)
typedef struct {
  int w, h, sx, sy;  // native framebuffer size, sample spacing
  uint32_t *px;      // (h / sy) rows of (w / sx) pixels
} Frame;

static int drm_fd = -1;
static uint32_t lit_crtc;

// the fb on the one lit CRTC's primary plane, which is where the UI draws
static uint32_t scanout_fb(void) {
  if (lit_crtc) {  // cheap enough to poll for page flips while recording
    struct drm_mode_crtc c = {.crtc_id = lit_crtc};
    if (!ioctl(drm_fd, DRM_IOCTL_MODE_GETCRTC, &c) && c.fb_id) return c.fb_id;
  }
  struct drm_mode_card_res res = {0};
  uint32_t ids[16];
  if (ioctl(drm_fd, DRM_IOCTL_MODE_GETRESOURCES, &res)) die("GETRESOURCES: %s", strerror(errno));
  if (res.count_crtcs > 16) die("too many CRTCs");
  res = (struct drm_mode_card_res){.crtc_id_ptr = (uintptr_t)ids, .count_crtcs = res.count_crtcs};
  if (ioctl(drm_fd, DRM_IOCTL_MODE_GETRESOURCES, &res)) die("GETRESOURCES: %s", strerror(errno));
  uint32_t fb = 0;
  int lit = 0;
  for (uint32_t i = 0; i < res.count_crtcs; i++) {
    struct drm_mode_crtc c = {.crtc_id = ids[i]};
    if (ioctl(drm_fd, DRM_IOCTL_MODE_GETCRTC, &c)) die("GETCRTC: %s", strerror(errno));
    if (c.fb_id) {
      fb = c.fb_id;
      lit_crtc = c.crtc_id;
      lit++;
    }
  }
  if (lit != 1) die("expected one display showing something, found %d", lit);
  return fb;
}

static void gem_close(uint32_t handle) {
  struct drm_gem_close c = {.handle = handle};
  ioctl(drm_fd, DRM_IOCTL_GEM_CLOSE, &c);
}

static size_t cache_line(void) {
#ifdef __aarch64__
  uint64_t ctr;
  __asm__ volatile("mrs %0, ctr_el0" : "=r"(ctr));
  return 4 << (ctr >> 16 & 0xF);
#else
  return 64;
#endif
}

// drops cached copies of [p, p + n), so reads see what the GPU wrote rather than what an earlier read
// cached. the dma-buf sync ioctl succeeds without doing this on these kernels, so it isn't used. the
// lines are never dirty (the mapping is read-only), so this writes nothing back
static void invalidate(const uint8_t *p, size_t n) {
#ifdef __aarch64__
  size_t line = cache_line();
  for (uintptr_t a = (uintptr_t)p & ~(line - 1); a < (uintptr_t)p + n; a += line) __asm__ volatile("dc civac, %0" ::"r"(a) : "memory");
  __asm__ volatile("dsb sy" ::: "memory");
#else
  (void)p, (void)n;
#endif
}

// returns how long the copy took, or -1 if the framebuffer went away, as it does when the UI restarts
static double read_fb(uint32_t fb_id, Frame *f, int full) {
  struct drm_mode_fb_cmd fb = {.fb_id = fb_id};
  if (ioctl(drm_fd, DRM_IOCTL_MODE_GETFB, &fb)) {
    if (errno == ENOENT) return -1;
    die("GETFB: %s", strerror(errno));
  }
  if (!fb.handle) die("reading the framebuffer needs root");
  if (fb.bpp != 32 || fb.pitch < fb.width * 4) die("unexpected framebuffer: %u bpp, pitch %u for width %u", fb.bpp, fb.pitch, fb.width);

  struct drm_prime_handle prime = {.handle = fb.handle, .flags = DRM_CLOEXEC};
  if (ioctl(drm_fd, DRM_IOCTL_PRIME_HANDLE_TO_FD, &prime)) die("PRIME_HANDLE_TO_FD: %s", strerror(errno));
  size_t len = (size_t)fb.pitch * fb.height;
  const uint8_t *map = mmap(NULL, len, PROT_READ, MAP_SHARED, prime.fd, 0);
  if (map == MAP_FAILED) die("mmap: %s", strerror(errno));

  // a full copy for the screenshot, or one pixel per cache line from every 8th row to watch for changes
  int sx = full ? 1 : cache_line() / 4, sy = full ? 1 : 8;
  if (!f->px || f->w != (int)fb.width || f->h != (int)fb.height || f->sx != sx) {
    free(f->px);
    *f = (Frame){.w = fb.width, .h = fb.height, .sx = sx, .sy = sy};
    f->px = xmalloc((size_t)(f->w / sx) * (f->h / sy) * 4);
  }
  uint32_t *o = f->px;
  double start = now();
  for (int y = 0; y < f->h / sy * sy; y += sy) {
    const uint8_t *row = map + (size_t)y * fb.pitch;
    invalidate(row, (size_t)f->w * 4);
    if (full) {
      memcpy(o, row, (size_t)f->w * 4);
      o += f->w;
    } else {
      for (int x = 0; x < f->w / sx * sx; x += sx) memcpy(o++, row + x * 4, 4);
    }
  }

  double took = now() - start;
  munmap((void *)map, len);
  close(prime.fd);
  gem_close(fb.handle);
  return took;
}

// copies the frame being shown and returns its fb. a frame is never torn: the UI draws into a back
// buffer and the display flips to it once it's finished, so the shown buffer only changes if a flip
// hands it back to the UI during the copy. the check after it catches one flip. a copy slow enough
// for two (away and back) is retried, which makes a torn frame unlikely rather than impossible
static uint32_t grab(Frame *f, int full) {
  if (drm_fd < 0) {
    drm_fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (drm_fd < 0) die("/dev/dri/card0: %s", strerror(errno));
    // opening the card when nothing holds DRM master makes us master, which would keep the UI from getting
    // it. give it straight back (when we aren't master, this fails and does nothing). the control node
    // can't do this without master, but it can't export a cached mapping and the uncached one is too
    // slow to copy between page flips
    ioctl(drm_fd, DRM_IOCTL_DROP_MASTER, 0);
  }
  for (int i = 0; i < 10; i++) {
    uint32_t fb = scanout_fb();
    double took = read_fb(fb, f, full);
    if (took < 0 || scanout_fb() != fb) continue;
    if (took < 0.008 || i >= 5) return fb;  // a slow copy on a busy device still beats failing
  }
  die("couldn't copy a frame without the screen flipping during it");
}

// fraction of pixels (or sampled pixels) that differ
static double changed(const Frame *a, const Frame *b) {
  if (a->w != b->w || a->h != b->h || a->sx != b->sx) return 1;
  size_t n = 0, total = (size_t)(a->w / a->sx) * (a->h / a->sy);
  for (size_t i = 0; i < total; i++) n += a->px[i] != b->px[i];
  return (double)n / total;
}

enum { SETTLED, ANIMATING, CHANGING };

// waits for the screen to be still for 0.4s, or for only small parts of it (a shimmer, a cursor) to keep
// changing for 1s, up to 3s, then copies the frame into `f`. stillness is judged on a sparse sample
static int settle(Frame *f) {
  enum { N = 64 };
  double t[N], c[N];
  int n = 0, state = CHANGING;
  Frame prev = {0}, sample = {0}, *s = &sample;
  double start = now();
  grab(s, 0);
  while (now() - start < 3.0) {
    nap(0.05);
    Frame tmp = prev;
    prev = *s;
    *s = tmp;
    grab(s, 0);
    t[n % N] = now();
    c[n % N] = changed(&prev, s);
    n++;
    double tn = t[(n - 1) % N];
    int still = tn - start >= 0.4, small = tn - start >= 1.0;
    for (int i = n - 1; i >= 0 && i >= n - N; i--) {
      if (t[i % N] > tn - 0.4 && c[i % N] >= 0.01) still = 0;
      if (t[i % N] > tn - 1.0 && c[i % N] >= 0.1) small = 0;
    }
    if (still || small) {
      state = still ? SETTLED : ANIMATING;
      break;
    }
  }
  free(prev.px);
  free(sample.px);
  grab(f, 1);
  return state;
}

// *** PNG, uncompressed ***

static uint32_t crc_table[256];

static uint32_t crc(uint32_t c, const uint8_t *p, size_t n) {
  if (!crc_table[1])
    for (uint32_t i = 0; i < 256; i++) {
      uint32_t v = i;
      for (int k = 0; k < 8; k++) v = v & 1 ? 0xEDB88320 ^ (v >> 1) : v >> 1;
      crc_table[i] = v;
    }
  c = ~c;
  while (n--) c = crc_table[(c ^ *p++) & 0xFF] ^ (c >> 8);
  return ~c;
}

static void be32(uint8_t *p, uint32_t v) {
  p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}

static void chunk(FILE *out, const char *type, const uint8_t *data, size_t n) {
  uint8_t hdr[8];
  be32(hdr, n);
  memcpy(hdr + 4, type, 4);
  uint8_t tail[4];
  be32(tail, crc(crc(0, hdr + 4, 4), data, n));
  fwrite(hdr, 1, 8, out);
  fwrite(data, 1, n, out);
  fwrite(tail, 1, 4, out);
}

// rgb is h rows of w * 3 bytes
static void write_png(FILE *out, const uint8_t *rgb, int w, int h) {
  size_t row = (size_t)w * 3 + 1, raw_len = row * h;
  uint8_t *raw = xmalloc(raw_len);
  for (int y = 0; y < h; y++) {
    raw[y * row] = 0;  // no filter
    memcpy(raw + y * row + 1, rgb + (size_t)y * w * 3, row - 1);
  }
  // a zlib stream of stored deflate blocks
  size_t blocks = (raw_len + 65534) / 65535;
  size_t z_len = 2 + raw_len + blocks * 5 + 4;
  uint8_t *z = xmalloc(z_len), *p = z;
  *p++ = 0x78;
  *p++ = 0x01;
  uint32_t a = 1, b = 0;
  for (size_t off = 0; off < raw_len; off += 65535) {
    size_t n = raw_len - off < 65535 ? raw_len - off : 65535;
    *p++ = off + n == raw_len;
    *p++ = n; *p++ = n >> 8; *p++ = ~n; *p++ = ~n >> 8;
    memcpy(p, raw + off, n);
    p += n;
    for (size_t i = 0; i < n; i++) {
      a = (a + raw[off + i]) % 65521;
      b = (b + a) % 65521;
    }
  }
  be32(p, b << 16 | a);

  uint8_t ihdr[13];
  be32(ihdr, w);
  be32(ihdr + 4, h);
  memcpy(ihdr + 8, "\x08\x02\x00\x00\x00", 5);  // 8-bit RGB
  fwrite("\x89PNG\r\n\x1a\n", 1, 8, out);
  chunk(out, "IHDR", ihdr, 13);
  chunk(out, "IDAT", z, z_len);
  chunk(out, "IEND", NULL, 0);
  free(raw);
  free(z);
}

// writes a PNG to path, or stdout for "-"
static void save(const char *path, const uint8_t *rgb, int w, int h) {
  int out_stdout = !strcmp(path, "-");
  FILE *out = out_stdout ? stdout : fopen(path, "wb");
  if (!out) die("can't write %s on the device (%s). to save it locally, leave out PATH and redirect stdout", path, strerror(errno));
  write_png(out, rgb, w, h);
  if (ferror(out) | (out_stdout ? fflush(out) : fclose(out))) die("writing %s failed (%s)", out_stdout ? "stdout" : path, strerror(errno));
}

// box-downscale by `n` and turn upright
static uint8_t *upright(const Frame *f, int n, int k, int *ow, int *oh) {
  int w = f->w / n, h = f->h / n;
  *ow = k % 2 ? h : w;
  *oh = k % 2 ? w : h;
  uint8_t *rgb = xmalloc((size_t)w * h * 3);
  for (int uy = 0; uy < *oh; uy++)
    for (int ux = 0; ux < *ow; ux++) {
      int x, y;  // in the downscaled native image
      switch (k) {
        case 1: x = w - 1 - uy; y = ux; break;
        case 2: x = w - 1 - ux; y = h - 1 - uy; break;
        case 3: x = uy; y = h - 1 - ux; break;
        default: x = ux; y = uy;
      }
      unsigned sum[3] = {0};
      for (int dy = 0; dy < n; dy++)
        for (int dx = 0; dx < n; dx++) {
          const uint8_t *px = (const uint8_t *)&f->px[(size_t)(y * n + dy) * f->w + x * n + dx];
          sum[0] += px[0];
          sum[1] += px[1];
          sum[2] += px[2];
        }
      uint8_t *o = rgb + ((size_t)uy * *ow + ux) * 3;
      for (int i = 0; i < 3; i++) o[i] = sum[i] / (n * n);
    }
  return rgb;
}

// *** touch ***

static int touch_fd = -1, touch_w, touch_h, touch_n, touch_k, touch_uw, touch_uh;

static void touch_open(void) {
  if (touch_fd >= 0) return;
  DIR *d = opendir("/dev/input");
  if (!d) die("/dev/input: %s", strerror(errno));
  struct dirent *e;
  while ((e = readdir(d)) && touch_fd < 0) {
    if (strncmp(e->d_name, "event", 5)) continue;
    char path[300];
    snprintf(path, sizeof(path), "/dev/input/%s", e->d_name);
    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) continue;
    uint8_t bits[ABS_MAX / 8 + 1] = {0};
    struct input_absinfo ax, ay;
    if (ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(bits)), bits) >= 0 && bits[ABS_MT_POSITION_X / 8] & (1 << ABS_MT_POSITION_X % 8) &&
        !ioctl(fd, EVIOCGABS(ABS_MT_POSITION_X), &ax) && !ioctl(fd, EVIOCGABS(ABS_MT_POSITION_Y), &ay)) {
      touch_fd = fd;
      // both panels report 0 to the framebuffer's width and height, so touch units are its pixels
      touch_w = ax.maximum;
      touch_h = ay.maximum;
    } else {
      close(fd);
    }
  }
  closedir(d);
  if (touch_fd < 0) die("no touchscreen found");
  touch_k = rotation();
  touch_n = scale_for(touch_w, touch_h);
  touch_uw = (touch_k % 2 ? touch_h : touch_w) / touch_n;
  touch_uh = (touch_k % 2 ? touch_w : touch_h) / touch_n;
}

static void on_screen(long x, long y) {
  if (x < 0 || y < 0 || x >= touch_uw || y >= touch_uh) die("%ld, %ld is off the %dx%d screen", x, y, touch_uw, touch_uh);
}

static void native(int x, int y, int *nx, int *ny) {
  x = x * touch_n + touch_n / 2;
  y = y * touch_n + touch_n / 2;
  // inverse of upright()
  switch (touch_k) {
    case 1: *nx = touch_w - 1 - y; *ny = x; break;
    case 2: *nx = touch_w - 1 - x; *ny = touch_h - 1 - y; break;
    case 3: *nx = y; *ny = touch_h - 1 - x; break;
    default: *nx = x; *ny = y;
  }
}

static const struct input_event LIFT[] = {
  {.type = EV_ABS, .code = ABS_MT_SLOT, .value = 0}, {.type = EV_ABS, .code = ABS_MT_TRACKING_ID, .value = -1},
  {.type = EV_KEY, .code = BTN_TOUCH, .value = 0}, {.type = EV_SYN, .code = SYN_REPORT},
};
static volatile sig_atomic_t finger_down;

// so being killed mid-gesture (^C, a dropped SSH connection, a test timeout) doesn't leave a finger on the
// screen, which the UI would take as a long press
static void lift_and_exit(int sig) {
  if (finger_down && write(touch_fd, LIFT, sizeof(LIFT)) < 0) {}
  _exit(128 + sig);
}

static void emit(int n, const int (*ev)[3]) {
  struct input_event buf[16] = {0};
  for (int i = 0; i < n; i++) {
    buf[i].type = ev[i][0];
    buf[i].code = ev[i][1];
    buf[i].value = ev[i][2];
  }
  buf[n].type = EV_SYN;
  buf[n].code = SYN_REPORT;
  if (write(touch_fd, buf, sizeof(buf[0]) * (n + 1)) < 0) die("touch: %s", strerror(errno));
}

static void down(int x, int y) {
  int nx, ny;
  native(x, y, &nx, &ny);
  // the kernel drops values that repeat the last one, so a reader that started since (like a restarted UI)
  // would never get this position. a nudge first makes it a change
  const int ev[][3] = {
    {EV_ABS, ABS_MT_SLOT, 0}, {EV_ABS, ABS_MT_TRACKING_ID, 0xC0A},
    {EV_ABS, ABS_MT_POSITION_X, nx ^ 1}, {EV_ABS, ABS_MT_POSITION_Y, ny ^ 1},
    {EV_ABS, ABS_MT_POSITION_X, nx}, {EV_ABS, ABS_MT_POSITION_Y, ny},
    {EV_ABS, ABS_MT_PRESSURE, 50}, {EV_ABS, ABS_MT_TOUCH_MAJOR, 10}, {EV_KEY, BTN_TOUCH, 1},
  };
  finger_down = 1;
  emit(9, ev);
}

static void move(int x, int y) {
  int nx, ny;
  native(x, y, &nx, &ny);
  const int ev[][3] = {{EV_ABS, ABS_MT_POSITION_X, nx}, {EV_ABS, ABS_MT_POSITION_Y, ny}};
  emit(2, ev);
}

static void up(void) {
  if (write(touch_fd, LIFT, sizeof(LIFT)) < 0) die("touch: %s", strerror(errno));
  finger_down = 0;
  nap(0.05);  // so back-to-back gestures land in separate frames
}

// *** recording ***

// polls for page flips and copies each new frame, then writes the ones that differ from the frame
// before once it's done, so encoding doesn't hold up the copying
static void record(double seconds, const char *dir) {
  enum { MAX = 600, MAX_BYTES = 200 << 20 };
  struct { double t; uint8_t *rgb; } shots[MAX];
  int nshots = 0, flips = 0, k = rotation(), w = 0, h = 0;
  double gap = 0, last = 0, start = now();
  Frame f = {0};
  uint32_t shown = 0;
  while (now() - start < seconds && nshots < MAX && (size_t)nshots * w * h * 3 < MAX_BYTES) {
    if (shown && scanout_fb() == shown) {
      nap(0.001);
      continue;
    }
    double t = now() - start;
    shown = grab(&f, 1);
    if (flips++) gap = t - last > gap ? t - last : gap;
    last = t;
    uint8_t *rgb = upright(&f, scale_for(f.w, f.h), k, &w, &h);
    if (nshots && !memcmp(rgb, shots[nshots - 1].rgb, (size_t)w * h * 3)) {
      free(rgb);
      continue;
    }
    shots[nshots].t = t;
    shots[nshots++].rgb = rgb;
  }
  double took = now() - start;
  free(f.px);
  for (int i = 0; i < nshots; i++) {
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/%04d.png", dir, (int)(shots[i].t * 1000));
    save(path, shots[i].rgb, w, h);
    free(shots[i].rgb);
  }
  fprintf(stderr, "recorded %.1fs", took);
  if (took < seconds) fprintf(stderr, " (stopped early, at the memory limit)");
  fprintf(stderr, ": caught %d frames (%.0f fps, longest gap %.0fms), %d different saved to %s\n", flips,
          flips / took, gap * 1000, nshots, dir);
}

// makes dir if needed and checks it's empty, before anything runs
static void check_record_dir(const char *dir) {
  if (mkdir(dir, 0755) && errno != EEXIST) die("can't make %s on the device (%s)", dir, strerror(errno));
  DIR *d = opendir(dir);
  if (!d) die("can't open %s on the device (%s)", dir, strerror(errno));
  for (struct dirent *e; (e = readdir(d));)
    if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) die("%s isn't empty, so its frames would mix with these", dir);
  closedir(d);
  if (access(dir, W_OK)) die("can't write to %s on the device (%s)", dir, strerror(errno));
}

// checks a screenshot PATH can be written, before anything runs
static void check_path(const char *path) {
  struct stat st;
  if (!stat(path, &st) && S_ISDIR(st.st_mode)) die("%s is a directory on the device; give a file name", path);
  if (!access(path, F_OK)) {
    if (access(path, W_OK)) die("can't write %s on the device (%s). to save it locally, leave out PATH and redirect stdout", path, strerror(errno));
    return;
  }
  char dir[PATH_MAX];
  snprintf(dir, sizeof(dir), "%s", path);
  char *slash = strrchr(dir, '/');
  if (slash == dir) dir[1] = 0;
  else if (slash) *slash = 0;
  else strcpy(dir, ".");
  if (access(dir, W_OK | X_OK)) die("can't write %s on the device (%s). to save it locally, leave out PATH and redirect stdout", path, strerror(errno));
}

// *** commands ***

static const struct { const char *name; int min, max; } CMDS[] = {
  {"screenshot", 0, 2}, {"tap", 2, 2}, {"swipe", 4, 5}, {"sleep", 1, 1}, {"record", 2, 2},
};
enum { SCREENSHOT, TAP, SWIPE, SLEEP, RECORD, NCMDS };

static int command(const char *s) {
  for (int i = 0; i < NCMDS; i++)
    if (!strcmp(s, CMDS[i].name)) return i;
  return -1;
}

static int integer(const char *s, long *v) {
  char *end;
  errno = 0;
  *v = strtol(s, &end, 10);
  return *s && !*end && !errno;
}

static int seconds(const char *s, double *v) {
  char *end;
  *v = strtod(s, &end);
  return *s && !*end && isfinite(*v) && *v >= 0;
}

// one command and its arguments: tap/swipe numbers in n[], seconds in secs, a PATH or DIR in path
typedef struct {
  int cmd, nargs, now;
  long n[5];
  double secs;
  const char *path;
} Cmd;

// parses the command at argv[*i] and moves *i past it, dying on anything wrong with it
static Cmd parse(int argc, char **argv, int *i) {
  Cmd c = {.cmd = command(argv[*i])};
  if (c.cmd < 0) die("unexpected '%s'. run it with no arguments for usage", argv[*i]);
  char **a = argv + *i + 1;
  while (*i + 1 + c.nargs < argc && c.nargs < CMDS[c.cmd].max && command(a[c.nargs]) < 0) c.nargs++;
  if (c.nargs < CMDS[c.cmd].min) die("%s needs %d arguments", CMDS[c.cmd].name, CMDS[c.cmd].min);
  *i += 1 + c.nargs;
  switch (c.cmd) {
    case SCREENSHOT:
      c.now = c.nargs && !strcmp(a[0], "--now");
      if (c.nargs == 2 && !c.now) die("screenshot takes one PATH");
      c.path = c.nargs > c.now ? a[c.now] : NULL;
      if (c.path && c.path[0] == '-' && c.path[1]) die("screenshot: unknown option '%s'", c.path);
      break;
    case TAP:
    case SWIPE:
      for (int j = 0; j < c.nargs; j++)
        if (!integer(a[j], &c.n[j])) die("%s: '%s' isn't a whole number", CMDS[c.cmd].name, a[j]);
      if (c.cmd == SWIPE && c.nargs < 5) c.n[4] = 300;
      if (c.cmd == SWIPE && (c.n[4] < 1 || c.n[4] > 10000)) die("swipe: MS is 1 to 10000");
      break;
    case SLEEP:
      if (!seconds(a[0], &c.secs) || c.secs > 3600) die("sleep: '%s' isn't a number of seconds, up to 3600", a[0]);
      break;
    case RECORD:
      if (!seconds(a[0], &c.secs) || c.secs <= 0 || c.secs > 10) die("record: SECONDS is more than 0, up to 10");
      c.path = a[1];
      break;
  }
  return c;
}

int main(int argc, char **argv) {
  char self[PATH_MAX] = "screen";
  ssize_t len = readlink("/proc/self/exe", self, sizeof(self) - 1);
  if (len > 0) self[len] = 0;
  if (argc == 1) {
    printf(USAGE, self);
    return 0;
  }

  // check every command before running any
  Cmd *cmds = xmalloc(sizeof(Cmd) * argc);
  int ncmds = 0, stdout_shots = 0, gestures = 0;
  for (int i = 1; i < argc;) {
    Cmd c = cmds[ncmds++] = parse(argc, argv, &i);
    stdout_shots += c.cmd == SCREENSHOT && (!c.path || !strcmp(c.path, "-"));
    gestures += c.cmd == TAP || c.cmd == SWIPE;
  }
  if (stdout_shots > 1) die("only one screenshot can go to stdout, give the others a PATH");

  // it's setuid root, rather than going through sudo, which logs every call to the journal
  if (geteuid() != 0) die("%s needs to be setuid root (chown root %s && chmod u+s %s)", self, self, self);
  // files it saves are written, and device nodes opened, as whoever ran it. root is only for reading
  // the framebuffer
  setfsuid(getuid());
  setfsgid(getgid());
  if ((uid_t)setfsuid(-1) != getuid() || (gid_t)setfsgid(-1) != getgid()) die("couldn't drop to the caller's file permissions");

  for (int i = 0; i < ncmds; i++) {
    if (cmds[i].cmd == SCREENSHOT && cmds[i].path && strcmp(cmds[i].path, "-")) check_path(cmds[i].path);
    if (cmds[i].cmd != RECORD) continue;
    for (int j = 0; j < i; j++)
      if (cmds[j].cmd == RECORD && !strcmp(cmds[j].path, cmds[i].path)) die("two records into %s would mix their frames", cmds[i].path);
    check_record_dir(cmds[i].path);
  }
  if (gestures) {
    touch_open();
    for (int i = 0; i < ncmds; i++)
      for (int j = 0; j < (cmds[i].cmd == TAP ? 2 : cmds[i].cmd == SWIPE ? 4 : 0); j += 2) on_screen(cmds[i].n[j], cmds[i].n[j + 1]);
    struct sigaction sa = {.sa_handler = lift_and_exit};
    int sigs[] = {SIGINT, SIGTERM, SIGHUP, SIGPIPE};
    for (int i = 0; i < 4; i++) sigaction(sigs[i], &sa, NULL);
  }

  Frame before = {0};  // the screen just before the last gesture
  int gestured = -1;
  for (int i = 0; i < ncmds; i++) {
    Cmd c = cmds[i];
    long *n = c.n;
    if (c.cmd == SCREENSHOT) {
      Frame f = {0};
      int state = SETTLED;
      if (c.now) grab(&f, 1);
      else state = settle(&f);
      int w, h;
      uint8_t *rgb = upright(&f, scale_for(f.w, f.h), rotation(), &w, &h);
      const char *path = c.path ? c.path : isatty(1) ? "/tmp/screen.png" : "-";
      save(path, rgb, w, h);
      fprintf(stderr, "screenshot %dx%d", w, h);
      if (strcmp(path, "-")) fprintf(stderr, " saved to %s", path);
      if (state == ANIMATING) fprintf(stderr, ", a small part keeps animating, the rest is still");
      if (state == CHANGING) fprintf(stderr, ", still changing after 3s");
      if (gestured >= 0 && changed(&before, &f) == 0) fprintf(stderr, ", unchanged since before the last %s", CMDS[gestured].name);
      fputc('\n', stderr);
      free(rgb);
      free(f.px);
    } else if (c.cmd == SLEEP) {
      nap(c.secs);
    } else if (c.cmd == RECORD) {
      record(c.secs, c.path);
    } else {
      // only a screenshot before the next gesture compares against this frame, so skip copying it otherwise
      int looks_later = 0;
      for (int j = i + 1; j < ncmds && cmds[j].cmd != TAP && cmds[j].cmd != SWIPE; j++) looks_later |= cmds[j].cmd == SCREENSHOT;
      if (looks_later) grab(&before, 1);
      gestured = looks_later ? c.cmd : -1;
      if (c.cmd == TAP) {
        down(n[0], n[1]);
        nap(0.1);
        up();
      } else {
        int steps = n[4] * 60 / 1000;
        if (steps < 1) steps = 1;
        down(n[0], n[1]);
        for (int s = 1; s <= steps; s++) {
          nap(n[4] / 1000.0 / steps);
          move(n[0] + (n[2] - n[0]) * s / steps, n[1] + (n[3] - n[1]) * s / steps);
        }
        up();
      }
    }
  }
  return 0;
}
