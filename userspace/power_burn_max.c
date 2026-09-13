/*
 * power_burn_max - CPU/GPU/LED power burn for tici.
 *
 *   power_burn_max [seconds] [n_perf_cores]
 */

#define _GNU_SOURCE
#include <CL/cl.h>
#include <arm_neon.h>
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
    if (fd < 0) { perror("open /dev/mem"); return; }
    const uintptr_t page = POWER_TEST_ADDR & ~0xFFFull;
    const uintptr_t off  = POWER_TEST_ADDR & 0xFFFull;
    void *p = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)page);
    if (p == MAP_FAILED) { perror("mmap /dev/mem"); close(fd); return; }
    *(volatile uint32_t *)((char *)p + off) = val;
    msync(p, 0x1000, MS_SYNC);
    munmap(p, 0x1000);
    close(fd);
}

#define MAX_SAVED 96
static struct { char path[192]; char val[48]; } saved[MAX_SAVED];
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
        nsaved++;
    }
    sysfs_write(p, v);
}
static void restore_all(void) {
    for (int i = nsaved - 1; i >= 0; i--) sysfs_write(saved[i].path, saved[i].val);
}
static void fatal_sig(int s) {
    const char *m = "[power_burn_max] fault: signal\n";
    switch (s) {
        case SIGABRT: m = "[power_burn_max] fault: SIGABRT\n"; break;
        case SIGSEGV: m = "[power_burn_max] fault: SIGSEGV\n"; break;
        case SIGBUS:  m = "[power_burn_max] fault: SIGBUS\n";  break;
    }
    (void)!write(2, m, strlen(m));
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
static void freq_max(void) {
    /* max_pwrlevel=0 unlocks the 710MHz step that Adreno gates off by default
     * even under governor=performance. */
    save_and_write("/sys/class/kgsl/kgsl-3d0/devfreq/governor", "performance");
    save_and_write("/sys/class/kgsl/kgsl-3d0/max_pwrlevel",     "0");
    save_and_write("/sys/class/kgsl/kgsl-3d0/force_bus_on",     "1");
    save_and_write("/sys/class/kgsl/kgsl-3d0/force_clk_on",     "1");
    save_and_write("/sys/class/kgsl/kgsl-3d0/force_rail_on",    "1");
    save_and_write("/sys/class/kgsl/kgsl-3d0/force_no_nap",     "1");
    save_and_write("/sys/class/devfreq/soc:qcom,gpubw/governor",  "performance");
    save_and_write("/sys/class/devfreq/soc:qcom,cpubw/governor",  "performance");
    save_and_write("/sys/class/devfreq/soc:qcom,llccbw/governor", "performance");
    save_and_write("/sys/class/devfreq/soc:qcom,l3-cpu0/governor","performance");
    save_and_write("/sys/class/devfreq/soc:qcom,l3-cpu4/governor","performance");
    save_and_write("/sys/class/devfreq/soc:qcom,l3-cdsp/governor","performance");
}
static void pin_perf_core(int cpu) {
    char path[128];
    snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/online", cpu);
    save_and_write(path, "1");
    snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_governor", cpu);
    save_and_write(path, "performance");
}

static void *cpu_burn(void *arg) {
    int core = (int)(intptr_t)arg;
    cpu_set_t set; CPU_ZERO(&set); CPU_SET(core, &set);
    pthread_setaffinity_np(pthread_self(), sizeof(set), &set);

    /* Contraction map x := 0.5*x + 0.25 — fixed point at 0.5, keeps values
     * bounded away from subnormal/NaN paths that short-circuit the FPU. */
    float32x4_t v0 = vdupq_n_f32(0.50f + core * 0.01f);
    float32x4_t v1 = vdupq_n_f32(0.25f);
    float32x4_t v2 = vdupq_n_f32(0.75f);
    float32x4_t v3 = vdupq_n_f32(0.125f);
    float32x4_t v4 = vdupq_n_f32(0.875f);
    float32x4_t v5 = vdupq_n_f32(0.625f);
    float32x4_t v6 = vdupq_n_f32(0.375f);
    float32x4_t v7 = vdupq_n_f32(0.1875f);
    const float32x4_t half = vdupq_n_f32(0.5f);
    const float32x4_t quarter = vdupq_n_f32(0.25f);

    while (running) {
        for (int i = 0; i < 10000; i++) {
            v0 = vfmaq_f32(quarter, v0, half);
            v1 = vfmaq_f32(quarter, v1, half);
            v2 = vfmaq_f32(quarter, v2, half);
            v3 = vfmaq_f32(quarter, v3, half);
            v4 = vfmaq_f32(quarter, v4, half);
            v5 = vfmaq_f32(quarter, v5, half);
            v6 = vfmaq_f32(quarter, v6, half);
            v7 = vfmaq_f32(quarter, v7, half);
        }
    }
    volatile float sink = vgetq_lane_f32(v0,0) + vgetq_lane_f32(v1,0) + vgetq_lane_f32(v2,0) +
                           vgetq_lane_f32(v3,0) + vgetq_lane_f32(v4,0) + vgetq_lane_f32(v5,0) +
                           vgetq_lane_f32(v6,0) + vgetq_lane_f32(v7,0);
    (void)sink;
    return NULL;
}

static const char *GPU_KSRC =
    "__kernel void burn(__global float *buf, int n) {"
    "  int id = get_global_id(0);"
    "  float4 a = (float4)(0.6f,0.7f,0.8f,0.9f) + (float)(id&15)*0.001f;"
    "  float4 b=a*0.5f, c=a*0.75f, d=a*0.8f, e=a*0.9f, f=a*0.55f, g=a*0.65f, h=a*0.85f;"
    "  for (int i = 0; i < n; i++) {"
    "    a = mad(a,(float4)(0.5f),(float4)(0.25f));"
    "    b = mad(b,(float4)(0.5f),(float4)(0.25f));"
    "    c = mad(c,(float4)(0.5f),(float4)(0.25f));"
    "    d = mad(d,(float4)(0.5f),(float4)(0.25f));"
    "    e = mad(e,(float4)(0.5f),(float4)(0.25f));"
    "    f = mad(f,(float4)(0.5f),(float4)(0.25f));"
    "    g = mad(g,(float4)(0.5f),(float4)(0.25f));"
    "    h = mad(h,(float4)(0.5f),(float4)(0.25f));"
    "  }"
    "  if ((id&1023)==0) buf[id/1024] = a.x+b.x+c.x+d.x+e.x+f.x+g.x+h.x;"
    "}";

int main(int argc, char **argv) {
    int duration = 1, n_perf = 4;
    if (argc > 1) duration = atoi(argv[1]);
    if (argc > 2) n_perf   = atoi(argv[2]);
    if (n_perf < 0) n_perf = 0;  if (n_perf > 4) n_perf = 4;

    signal(SIGTERM, stop_sig);
    signal(SIGINT,  stop_sig);
    signal(SIGABRT, fatal_sig);
    signal(SIGSEGV, fatal_sig);
    signal(SIGBUS,  fatal_sig);

    freq_max();
    for (int i = 0; i < n_perf; i++) pin_perf_core(4 + i);

    cl_platform_id plat; cl_device_id dev; cl_int err;
    clGetPlatformIDs(1, &plat, NULL);
    clGetDeviceIDs(plat, CL_DEVICE_TYPE_GPU, 1, &dev, NULL);
    cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err);
    cl_command_queue q = clCreateCommandQueue(ctx, dev, 0, &err);
    cl_program prog = clCreateProgramWithSource(ctx, 1, &GPU_KSRC, NULL, &err);
    clBuildProgram(prog, 1, &dev, "-cl-fast-relaxed-math -cl-mad-enable", NULL, NULL);
    cl_kernel kern = clCreateKernel(prog, "burn", &err);
    cl_mem buf = clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, 4096 * sizeof(float), NULL, &err);
    int n_inner = 200;
    clSetKernelArg(kern, 0, sizeof(cl_mem), &buf);
    clSetKernelArg(kern, 1, sizeof(int),    &n_inner);
    const size_t gs = 65536;

    write_magic(POWER_TEST_MAGIC);

    pthread_t cpu_th[4];
    for (int i = 0; i < n_perf; i++)
        pthread_create(&cpu_th[i], NULL, cpu_burn, (void *)(intptr_t)(4 + i));

    leds_on();

    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    uint64_t t_end_ns = (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec + (uint64_t)duration * 1000000000ull;
    while (running) {
        clEnqueueNDRangeKernel(q, kern, 1, NULL, &gs, NULL, 0, NULL, NULL);
        clFinish(q);
        if (duration > 0) {
            clock_gettime(CLOCK_MONOTONIC, &ts);
            if ((uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec >= t_end_ns) break;
        }
    }
    running = 0;

    for (int i = 0; i < n_perf; i++) pthread_join(cpu_th[i], NULL);

    clReleaseMemObject(buf);
    clReleaseKernel(kern);
    clReleaseProgram(prog);
    clReleaseCommandQueue(q);
    clReleaseContext(ctx);
    restore_all();
    write_magic(0);
    if (exit_signum) fprintf(stderr, "[power_burn_max] interrupted by signal %d\n", (int)exit_signum);
    return 0;
}
