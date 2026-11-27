/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef SPECTRA_MODULE_H
#define SPECTRA_MODULE_H

int cam_req_mgr_init(void);
void cam_req_mgr_exit(void);
int cam_req_mgr_late_init(void);
int cam_sync_init(void);
void cam_sync_exit(void);
int cam_smmu_init_module(void);
void cam_smmu_exit_module(void);
int cam_cpas_dev_init_module(void);
void cam_cpas_dev_exit_module(void);
int cam_cdm_intf_init_module(void);
void cam_cdm_intf_exit_module(void);
int cam_hw_cdm_init_module(void);
void cam_hw_cdm_exit_module(void);
int cam_ife_csid170_init_module(void);
void cam_ife_csid170_exit_module(void);
int cam_ife_csid_lite170_init_module(void);
void cam_ife_csid_lite170_exit_module(void);
int cam_vfe170_init_module(void);
void cam_vfe170_exit_module(void);
int cam_vfe_lite170_init_module(void);
void cam_vfe_lite170_exit_module(void);
int cam_isp_dev_init_module(void);
void cam_isp_dev_exit_module(void);
int cam_res_mgr_init(void);
void cam_res_mgr_exit(void);
int cam_cci_init_module(void);
void cam_cci_exit_module(void);
int cam_cci_late_init(void);
int cam_csiphy_init_module(void);
void cam_csiphy_exit_module(void);
int cam_sensor_driver_init(void);
void cam_sensor_driver_exit(void);
int cam_a5_init_module(void);
void cam_a5_exit_module(void);
int cam_ipe_init_module(void);
void cam_ipe_exit_module(void);
int cam_bps_init_module(void);
void cam_bps_exit_module(void);
int cam_icp_init_module(void);
void cam_icp_exit_module(void);

#endif
