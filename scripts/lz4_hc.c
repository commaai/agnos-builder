#define LZ4_HC_STATIC_LINKING_ONLY
#include <lz4hc.h>

void *agnos_lz4_create(void) {
  return LZ4_createStreamHC();
}

void agnos_lz4_destroy(void *context) {
  LZ4_freeStreamHC(context);
}

int agnos_lz4_compress(void *context, const char *source, char *target, int size, int capacity) {
  if (!context || size <= 0 || size > 1048576) return 0;
  // Every transport frame is independent. Favor longer matches to reduce
  // decoding work on the device while retaining HC's smaller wire payload.
  LZ4_resetStreamHC_fast(context, 12);
  LZ4_favorDecompressionSpeed(context, 1);
  return LZ4_compress_HC_continue(context, source, target, size, capacity);
}
