#include <stdio.h>
#include <stdlib.h>

// GLES only loads libCB for EGL/OpenCL event interop, which is unused.
__attribute__((noreturn)) void cb_get_sync_obj_from_cl_event_qcom(void) {
  fputs("Unexpected Qualcomm OpenCL event interop call\n", stderr);
  abort();
}
