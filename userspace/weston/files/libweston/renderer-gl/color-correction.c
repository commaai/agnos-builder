#include <stdlib.h>

#include "color-correction.h"

float decode_float16(uint16_t value){
  uint32_t sign = value >> 15;
  uint32_t exponent = (value >> 10) & 0x1F;
  uint32_t fraction = (value & 0x3FF);
  uint32_t output;
  if (exponent == 0){
    if (fraction == 0){
      // Zero
      output = (sign << 31);
    } else {
      exponent = 127 - 14;
      while ((fraction & (1 << 10)) == 0) {
        exponent--;
        fraction <<= 1;
      }
      fraction &= 0x3FF;
      output = (sign << 31) | (exponent << 23) | (fraction << 13);
    }
  } else if (exponent == 0x1F) {
    // Inf or NaN
    output = (sign << 31) | (0xFF << 23) | (fraction << 13);
  } else {
    // Regular
    output = (sign << 31) | ((exponent + (127-15)) << 23) | (fraction << 13);
  }

  return *((float*)&output);
}

struct color_correction_values * read_correction_values(void) {
  int ret;
  FILE *f = NULL;
  struct color_correction_values *ccv = NULL;

  weston_log("Setting up color correction\n");

  if (getenv("DISABLE_COLOR_CORRECTION")) {
    weston_log("Color correction disabled by flag\n");
    goto err;
  }

  ccv = malloc(sizeof(struct color_correction_values));
  if (ccv == NULL) {
    weston_log("CCV allocation failed...\n");
    goto err;
  }

  const char *cal_paths[] = {
    getenv("COLOR_CORRECTION_PATH"),
    "/data/misc/display/color_cal/color_cal",
    "/sys/devices/platform/soc/894000.i2c/i2c-2/2-0017/color_cal",
    "/persist/comma/color_cal",
  };
  for (int i = 0; i < sizeof(cal_paths) / sizeof(const char *); i++) {
    const char *cal_fn = cal_paths[i];
    if (cal_fn == NULL) {
      continue;
    }

    weston_log("Color calibration trying %s\n", cal_fn);
    f = fopen(cal_fn, "r");
    if (f == NULL) {
      weston_log("- unable to open %s\n", cal_fn);
      continue;
    }

    ret = fread(ccv, sizeof(struct color_correction_values), 1, f);
    fclose(f);
    if (ret == 1) {
      return ccv;
    } else {
      weston_log("- file too short!\n");
    }
  }

  weston_log("No color calibraion files found!\n");

err:
  if (f != NULL) fclose(f);
  if (ccv != NULL) free(ccv);
  return NULL;
}

const char * color_correction_get_shader(void){
  int ret;
  const char *shader = NULL;
  struct color_correction_values *ccv = NULL;

  shader = malloc(1024);
  if(shader == NULL){
    weston_log("Malloc failed\n");
    goto err;
  }

  ccv = read_correction_values();
  if(ccv == NULL){
    weston_log("No color correction values found\n");
    goto err;
  }

  ret = sprintf(shader,
    color_correction_fragment_shader_template,
    (1.0/decode_float16(ccv->rgb_color_gains[0])),
    (1.0/decode_float16(ccv->rgb_color_gains[1])),
    (1.0/decode_float16(ccv->rgb_color_gains[2])),
    decode_float16(ccv->ccm[0]),
    decode_float16(ccv->ccm[1]),
    decode_float16(ccv->ccm[2]),
    decode_float16(ccv->ccm[3]),
    decode_float16(ccv->ccm[4]),
    decode_float16(ccv->ccm[5]),
    decode_float16(ccv->ccm[6]),
    decode_float16(ccv->ccm[7]),
    decode_float16(ccv->ccm[8]),
    (1.0/decode_float16(ccv->gamma)),
    (1.0/decode_float16(ccv->gamma)),
    (1.0/decode_float16(ccv->gamma))
  );

  if(ret < 0){
    weston_log("Color correction sprintf failed\n");
    goto err;
  }

  weston_log("Successfully setup color correction\n");
  free(ccv);
  return shader;

err:
  weston_log("Failed to setup color correction\n");
  if (ccv != NULL) free(ccv);
  if (shader != NULL) free(shader);
  return null_shader;
}