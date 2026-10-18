#include <stdio.h>
#include <stdlib.h>

// Qualcomm's EGL subdriver also implements the GBM backend used by raylib.
// Only its unused Wayland paths should reach these entry points. The imports
// are renamed to avoid interposing on real Wayland clients elsewhere.
#define STUB(name) \
  __attribute__((noreturn)) void agnos_##name(void) { \
    fputs("Unexpected Qualcomm Wayland call: " #name "\n", stderr); \
    abort(); \
  }

STUB(wl_client_post_no_memory)
STUB(wl_display_connect)
STUB(wl_display_create_queue)
STUB(wl_display_dispatch_queue)
STUB(wl_display_flush)
STUB(wl_event_queue_destroy)
STUB(wl_global_create)
STUB(wl_global_destroy)
STUB(wl_proxy_add_listener)
STUB(wl_proxy_destroy)
STUB(wl_proxy_marshal)
STUB(wl_proxy_marshal_constructor)
STUB(wl_proxy_set_queue)
STUB(wl_resource_create)
STUB(wl_resource_destroy)
STUB(wl_resource_get_user_data)
STUB(wl_resource_instance_of)
STUB(wl_resource_post_error)
STUB(wl_resource_post_event)
STUB(wl_resource_set_implementation)
STUB(wl_resource_set_user_data)
STUB(WlEglWindowDecRef)
STUB(WlEglWindowIncRef)
STUB(WlEglWindowValidate)

// Layout of wl_interface from wayland-util.h. These descriptors are referenced
// by the unused Wayland protocol code, including static relocation tables.
struct wl_message;
struct wl_interface {
  const char *name;
  int version;
  int method_count;
  const struct wl_message *methods;
  int event_count;
  const struct wl_message *events;
};

const struct wl_interface agnos_wl_buffer_interface = {"wl_buffer", 0, 0, NULL, 0, NULL};
const struct wl_interface agnos_wl_callback_interface = {"wl_callback", 0, 0, NULL, 0, NULL};
const struct wl_interface agnos_wl_registry_interface = {"wl_registry", 0, 0, NULL, 0, NULL};
