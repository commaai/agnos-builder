// SPDX-License-Identifier: GPL-2.0-only
#include <linux/module.h>

#include "spectra_module.h"

static const struct {
	int (*init)(void);
	void (*exit)(void);
} components[] = {
	{ cam_req_mgr_init, cam_req_mgr_exit },
	{ cam_sync_init, cam_sync_exit },
	{ cam_smmu_init_module, cam_smmu_exit_module },
	{ cam_cpas_dev_init_module, cam_cpas_dev_exit_module },
	{ cam_cdm_intf_init_module, cam_cdm_intf_exit_module },
	{ cam_hw_cdm_init_module, cam_hw_cdm_exit_module },
	{ cam_ife_csid170_init_module, cam_ife_csid170_exit_module },
	{ cam_ife_csid_lite170_init_module, cam_ife_csid_lite170_exit_module },
	{ cam_vfe170_init_module, cam_vfe170_exit_module },
	{ cam_vfe_lite170_init_module, cam_vfe_lite170_exit_module },
	{ cam_isp_dev_init_module, cam_isp_dev_exit_module },
	{ cam_res_mgr_init, cam_res_mgr_exit },
	{ cam_cci_init_module, cam_cci_exit_module },
	{ cam_csiphy_init_module, cam_csiphy_exit_module },
	{ cam_sensor_driver_init, cam_sensor_driver_exit },
	{ cam_a5_init_module, cam_a5_exit_module },
	{ cam_ipe_init_module, cam_ipe_exit_module },
	{ cam_bps_init_module, cam_bps_exit_module },
	{ cam_icp_init_module, cam_icp_exit_module },
};

static unsigned int initialized;

static void spectra_cleanup(void)
{
	while (initialized)
		components[--initialized].exit();
}

static int __init spectra_init(void)
{
	int rc;

	while (initialized < ARRAY_SIZE(components)) {
		rc = components[initialized].init();
		if (rc) {
			pr_err("spectra_camera: %ps failed: %d\n",
			       components[initialized].init, rc);
			goto fail;
		}
		initialized++;
	}
	rc = cam_req_mgr_late_init();
	if (rc)
		goto fail;
	rc = cam_cci_late_init();
	if (rc)
		goto fail;
	return 0;
fail:
	spectra_cleanup();
	return rc;
}

static void __exit spectra_exit(void)
{
	spectra_cleanup();
}

module_init(spectra_init);
module_exit(spectra_exit);
MODULE_DESCRIPTION("SDM845 Spectra camera stack");
MODULE_LICENSE("GPL v2");
MODULE_IMPORT_NS("DMA_BUF");
