#ifndef _COLOR_CORRECTION_H_
#define _COLOR_CORRECTION_H_

#include <stdio.h>
#include <stdint.h>


// These are actually float16s, so need to be converted before use
struct __attribute__((__packed__)) color_correction_values {
  uint16_t gamma;
  uint16_t ccm[9];
  uint16_t rgb_color_gains[3];
};

static const char color_correction_fragment_shader_template[] =
	"  	gl_FragColor.rgb = pow(gl_FragColor.rgb, vec3(2.2, 2.2, 2.2));\n"
	"   gl_FragColor.r *= %ff;\n"
	"   gl_FragColor.g *= %ff;\n"
	"   gl_FragColor.b *= %ff;\n"
	"		vec3 rgb_cc = vec3(0.0f, 0.0f, 0.0f);\n"
	"  	rgb_cc += gl_FragColor.r * vec3(%ff, %ff, %ff);\n"
  "  	rgb_cc += gl_FragColor.g * vec3(%ff, %ff, %ff);\n"
  "  	rgb_cc += gl_FragColor.b * vec3(%ff, %ff, %ff);\n"
	"  	gl_FragColor.rgb = rgb_cc;\n"
  "  	gl_FragColor.rgb = pow(gl_FragColor.rgb, vec3(%ff/2.2, %ff/2.2, %ff/2.2));\n"
	;
static const char null_shader[] = "";

const char * color_correction_get_shader(void);

#endif