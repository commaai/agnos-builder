/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright (c) 2014-2019, The Linux Foundation. All rights reserved.
 *
 * cam_smmu_compat.h - stubs for the downstream-only Qualcomm secure-buffer /
 * ION interfaces that the cam_smmu public API (cam_smmu_api.h) and its
 * stage-2 (secure) code path still reference.
 *
 * cam_smmu uses the generic IOMMU API for the non-secure data path, which is
 * the only one the camera uses. The secure (stage-2) path still names ION
 * client/handle types and the Qualcomm secure-buffer SCM calls:
 * cam_smmu_map_stage2_iova() takes `struct ion_client *` and
 * `ion_phys_addr_t`, and the stage-2 helpers call ion_import_dma_buf_fd(),
 * ion_phys() and ion_free(). This header provides minimal types and stub
 * inlines for exactly those symbols, so the API is unchanged. The secure path
 * is never used; the stubs return -ENODEV/NULL. A real implementation would
 * use a secure dma-buf heap and qcom_scm_assign_mem().
 */

#ifndef _CAM_SMMU_COMPAT_H_
#define _CAM_SMMU_COMPAT_H_

#include <linux/types.h>
#include <linux/dma-buf.h>
#include <linux/err.h>

/*
 * Downstream msm_ion.h exported ion_phys_addr_t and the opaque ion_client /
 * ion_handle handle types. Mainline removed ION entirely (replaced by dma-buf
 * heaps). Provide the minimal type aliases so the cam_smmu public API and the
 * secure path keep their original signatures.
 */
#ifndef _CAM_SMMU_ION_COMPAT_TYPES
#define _CAM_SMMU_ION_COMPAT_TYPES
typedef phys_addr_t ion_phys_addr_t;
struct ion_client;
struct ion_handle;
#endif /* _CAM_SMMU_ION_COMPAT_TYPES */

/*
 * Secure-path ION helper stubs. The non-secure camera data path does not use
 * these; they exist only so the stage-2 (secure) code in cam_smmu_api.c
 * compiles.
 */
static inline struct ion_handle *ion_import_dma_buf_fd(
	struct ion_client *client, int fd)
{
	return ERR_PTR(-ENODEV);
}

static inline int ion_phys(struct ion_client *client, struct ion_handle *handle,
	ion_phys_addr_t *addr, size_t *len)
{
	return -ENODEV;
}

static inline void ion_free(struct ion_client *client,
	struct ion_handle *handle)
{
}

#endif /* _CAM_SMMU_COMPAT_H_ */
