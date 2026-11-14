/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright (c) 2017-2019, The Linux Foundation. All rights reserved.
 *
 * cam_compat_qcom.h - stubs for the downstream-only Qualcomm platform APIs
 * that the Spectra camera driver uses and mainline doesn't have:
 *
 *   - linux/clk/qcom.h : the per-consumer clk branch memory/periphery retention
 *     flags (CLKFLAG_*) plus clk_set_flags(). The common clock framework has
 *     no per-clk flag setter; these flags are a power optimisation (RAM
 *     retention on idle clk branches), so a no-op is functionally safe.
 *
 *   - soc/qcom/socinfo.h : socinfo_get_id(). Mainline does not export it; it
 *     only selects SoC-revision quirks, and 0 selects none.
 */

#ifndef _CAM_COMPAT_QCOM_H_
#define _CAM_COMPAT_QCOM_H_

#include <linux/clk.h>
#include <linux/types.h>

/* Downstream clk branch memory/periphery retention flags (linux/clk/qcom.h). */
enum branch_mem_flags {
	CLKFLAG_RETAIN_PERIPH,
	CLKFLAG_NORETAIN_PERIPH,
	CLKFLAG_RETAIN_MEM,
	CLKFLAG_NORETAIN_MEM,
	CLKFLAG_PERIPH_OFF_SET,
	CLKFLAG_PERIPH_OFF_CLEAR,
};

/*
 * Downstream clk_set_flags() has no mainline equivalent. The flags only control
 * idle-time RAM retention on the clk branch (a power optimisation); no-op is
 * functionally safe.
 */
static inline int clk_set_flags(struct clk *clk, unsigned long flags)
{
	return 0;
}

/*
 * Downstream socinfo helper. 0 disables the revision-specific quirks.
 */
static inline uint32_t socinfo_get_id(void)
{
	return 0;
}

#endif /* _CAM_COMPAT_QCOM_H_ */
