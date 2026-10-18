#define _GNU_SOURCE
#include <dlfcn.h>
#include <link.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

static int check_library(struct dl_phdr_info *info, size_t size, void *data) {
  (void)size;
  (void)data;
  if (strstr(info->dlpi_name, "libwayland-") || strstr(info->dlpi_name, "libffi.so.6") ||
      strstr(info->dlpi_name, "libOpenCL.so")) {
    fprintf(stderr, "Unexpected dependency: %s\n", info->dlpi_name);
    return 1;
  }
  return 0;
}

static int expect_abort(const char *library, const char *symbol) {
  void *stub = dlopen(library, RTLD_NOW);
  if (!stub) return 1;
  void (*disabled)(void) = (void (*)(void))dlsym(stub, symbol);
  if (!disabled) return 1;

  // Validate the failure path in a child so the image build can continue.
  pid_t child = fork();
  if (child < 0) return 1;
  if (child == 0) {
    struct rlimit limit = {0, 0};
    if (setrlimit(RLIMIT_CORE, &limit) != 0) _exit(1);
    disabled();
    _exit(1);
  }
  int status;
  if (waitpid(child, &status, 0) != child || !WIFSIGNALED(status) || WTERMSIG(status) != SIGABRT) return 1;
  return 0;
}

int main(void) {
  const char *libraries[] = {"libgbm.so", "libEGL_adreno.so", "libGLESv2_adreno.so", "libeglSubDriverWayland.so"};
  for (unsigned int i = 0; i < sizeof(libraries) / sizeof(libraries[0]); i++) {
    if (!dlopen(libraries[i], RTLD_NOW | RTLD_GLOBAL)) {
      fprintf(stderr, "%s: %s\n", libraries[i], dlerror());
      return 1;
    }
  }
  if (dl_iterate_phdr(check_library, NULL)) return 1;

  void *stub = dlopen("libagnos-wayland-stubs.so", RTLD_NOW);
  if (!stub || dlsym(stub, "wl_display_connect")) return 1;
  if (expect_abort("libagnos-wayland-stubs.so", "agnos_wl_display_connect") ||
      expect_abort("libCB.so", "cb_get_sync_obj_from_cl_event_qcom")) return 1;
  puts("Qualcomm drivers load without Wayland, libffi6 or OpenCL; disabled calls abort.");
  return 0;
}
