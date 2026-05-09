/*
 * power_burn_max - short CPU/LED-only power blip for boot.
 *
 *   power_burn_max [seconds] [n_cores]
 *
 * seconds may be fractional. n_cores defaults to all 8 SDM845 cores; use 4 to
 * burn only the big cluster.
 */

#define _GNU_SOURCE
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;
static volatile sig_atomic_t exit_signum = 0;
static void stop_sig(int s) { exit_signum = s; running = 0; }

/* End-of-ramoops DDR page. Survives warm reset if DDR stays in self-refresh
 * across a PSU dropout, so ABL reads this cookie on boot to detect a mid-burn
 * power cut. */
#define POWER_TEST_ADDR  0xB03FFFFCull
#define POWER_TEST_MAGIC 0x57505354u   /* "WPST" */

static void write_magic(uint32_t val) {
  int fd = open("/dev/mem", O_RDWR | O_SYNC);
  if (fd < 0) return;
  const uintptr_t page = POWER_TEST_ADDR & ~0xFFFull;
  const uintptr_t off = POWER_TEST_ADDR & 0xFFFull;
  void *p = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)page);
  if (p == MAP_FAILED) { close(fd); return; }
  *(volatile uint32_t *)((char *)p + off) = val;
  msync(p, 0x1000, MS_SYNC);
  munmap(p, 0x1000);
  close(fd);
}

#define MAX_SAVED 128
static struct { char path[192]; char val[64]; } saved[MAX_SAVED];
static int nsaved;

static int sysfs_read(const char *p, char *b, int sz) {
  FILE *f = fopen(p, "r");
  if (!f) return -1;
  if (!fgets(b, sz, f)) { fclose(f); return -1; }
  fclose(f);
  b[strcspn(b, "\n")] = 0;
  return 0;
}

static void sysfs_write(const char *p, const char *v) {
  FILE *f = fopen(p, "w");
  if (!f) return;
  fputs(v, f);
  fclose(f);
}

static void save_and_write(const char *p, const char *v) {
  if (nsaved < MAX_SAVED && sysfs_read(p, saved[nsaved].val, sizeof(saved[0].val)) == 0) {
    strncpy(saved[nsaved].path, p, sizeof(saved[0].path) - 1);
    saved[nsaved].path[sizeof(saved[0].path) - 1] = 0;
    nsaved++;
  }
  sysfs_write(p, v);
}

static void restore_all(void) {
  for (int i = nsaved - 1; i >= 0; i--) sysfs_write(saved[i].path, saved[i].val);
}

static void fatal_sig(int s) {
  write_magic(0);
  restore_all();
  _exit(128 + s);
}

static void leds_on(void) {
  save_and_write("/sys/class/leds/led:torch_0/brightness",  "500");
  save_and_write("/sys/class/leds/led:torch_1/brightness",  "500");
  save_and_write("/sys/class/leds/led:torch_2/brightness",  "300");
  save_and_write("/sys/class/leds/led:switch_0/brightness", "255");
  save_and_write("/sys/class/leds/led:switch_1/brightness", "255");
  save_and_write("/sys/class/leds/led:switch_2/brightness", "255");
}

static void cpu_bus_freq_max(void) {
  save_and_write("/sys/class/devfreq/soc:qcom,cpubw/governor",   "performance");
  save_and_write("/sys/class/devfreq/soc:qcom,llccbw/governor",  "performance");
  save_and_write("/sys/class/devfreq/soc:qcom,l3-cpu0/governor", "performance");
  save_and_write("/sys/class/devfreq/soc:qcom,l3-cpu4/governor", "performance");
}

static void pin_core(int cpu) {
  char path[160];
  char max_freq[32];

  snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", cpu);
  if (sysfs_read(path, max_freq, sizeof(max_freq)) != 0)
    max_freq[0] = 0;

  snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/online", cpu);
  save_and_write(path, "1");

  if (max_freq[0]) {
    snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_max_freq", cpu);
    save_and_write(path, max_freq);
    snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_min_freq", cpu);
    save_and_write(path, max_freq);
  }

  snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_governor", cpu);
  save_and_write(path, "performance");
}

static void *cpu_burn(void *arg) {
  int core = (int)(intptr_t)arg;
  cpu_set_t set; CPU_ZERO(&set); CPU_SET(core, &set);
  pthread_setaffinity_np(pthread_self(), sizeof(set), &set);

  void *mem = NULL;
  if (posix_memalign(&mem, 64, 4096) != 0)
    return NULL;
  memset(mem, core, 4096);

  const uint32_t a = 0x3f000000u + (uint32_t)core;
  const uint32_t b = 0x3e800000u + (uint32_t)core;
  const uint32_t c = 0x3f4ccccdu + (uint32_t)core;

  while (running) {
    asm volatile(
      "dup v0.4s, %w[a]\n"
      "dup v1.4s, %w[b]\n"
      "dup v2.4s, %w[c]\n"
      "dup v3.4s, %w[a]\n"
      "dup v4.4s, %w[b]\n"
      "dup v5.4s, %w[c]\n"
      "dup v6.4s, %w[a]\n"
      "dup v7.4s, %w[b]\n"
      "dup v16.4s, %w[c]\n"
      "dup v17.4s, %w[a]\n"
      "dup v18.4s, %w[b]\n"
      "dup v19.4s, %w[c]\n"
      "mov x9, #10000\n"
      "1:\n"
      "ldp q20, q21, [%[p], #0]\n"
      "fmla v0.4s, v16.4s, v17.4s\n"
      "fmla v1.4s, v17.4s, v18.4s\n"
      "fmla v2.4s, v18.4s, v19.4s\n"
      "fmla v3.4s, v19.4s, v16.4s\n"
      "ldp q22, q23, [%[p], #32]\n"
      "fmla v4.4s, v16.4s, v18.4s\n"
      "fmla v5.4s, v17.4s, v19.4s\n"
      "fmla v6.4s, v18.4s, v16.4s\n"
      "fmla v7.4s, v19.4s, v17.4s\n"
      "eor v20.16b, v20.16b, v22.16b\n"
      "fmla v8.4s, v0.4s, v17.4s\n"
      "fmla v9.4s, v1.4s, v18.4s\n"
      "fmla v10.4s, v2.4s, v19.4s\n"
      "fmla v11.4s, v3.4s, v16.4s\n"
      "eor v21.16b, v21.16b, v23.16b\n"
      "fmla v12.4s, v4.4s, v18.4s\n"
      "fmla v13.4s, v5.4s, v19.4s\n"
      "fmla v14.4s, v6.4s, v16.4s\n"
      "fmla v15.4s, v7.4s, v17.4s\n"
      "stp q20, q21, [%[p], #0]\n"
      "stp q22, q23, [%[p], #32]\n"
      "subs x9, x9, #1\n"
      "b.ne 1b\n"
      :
      : [p] "r" (mem), [a] "r" (a), [b] "r" (b), [c] "r" (c)
      : "x9", "cc", "memory",
        "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7",
        "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15",
        "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23");
  }

  free(mem);
  return NULL;
}

static uint64_t mono_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

int main(int argc, char **argv) {
  double duration_s = argc > 1 ? strtod(argv[1], NULL) : 1.0;
  int n_cores = argc > 2 ? atoi(argv[2]) : 8;
  if (n_cores < 0) n_cores = 0;
  if (n_cores > 8) n_cores = 8;
  int first_cpu = n_cores > 4 ? 0 : 4;

  signal(SIGTERM, stop_sig);
  signal(SIGINT, stop_sig);
  signal(SIGABRT, fatal_sig);
  signal(SIGSEGV, fatal_sig);
  signal(SIGBUS, fatal_sig);

  cpu_bus_freq_max();
  for (int i = 0; i < n_cores; i++) pin_core(first_cpu + i);
  write_magic(POWER_TEST_MAGIC);
  leds_on();

  pthread_t th[8];
  for (int i = 0; i < n_cores; i++)
    pthread_create(&th[i], NULL, cpu_burn, (void *)(intptr_t)(first_cpu + i));

  uint64_t end_ns = duration_s > 0.0 ? mono_ns() + (uint64_t)(duration_s * 1000000000.0) : 0;
  while (running) {
    if (end_ns && mono_ns() >= end_ns) break;
    usleep(1000);
  }
  running = 0;

  for (int i = 0; i < n_cores; i++) pthread_join(th[i], NULL);
  restore_all();
  write_magic(0);
  if (exit_signum) fprintf(stderr, "[power_burn_max] interrupted by signal %d\n", (int)exit_signum);
  return 0;
}
