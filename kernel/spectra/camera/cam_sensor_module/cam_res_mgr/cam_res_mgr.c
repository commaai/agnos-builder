/* Copyright (c) 2017-2018, The Linux Foundation. All rights reserved.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 and
 * only version 2 as published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */

#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/gpio.h>
/*
 * <linux/gpio.h> no longer transitively pulls in the pinctrl consumer
 * API. Include it explicitly for devm_pinctrl_get/pinctrl_lookup_state/etc.
 */
#include <linux/pinctrl/consumer.h>
#include "cam_debug_util.h"
#include "cam_res_mgr_api.h"
#include "cam_res_mgr_private.h"
#include "cam_soc_util.h"

static struct cam_res_mgr *cam_res;

static void cam_res_mgr_free_res(void)
{
	struct cam_dev_res *dev_res, *dev_temp;
	struct cam_gpio_res *gpio_res, *gpio_temp;

	if (!cam_res)
		return;

	mutex_lock(&cam_res->gpio_res_lock);
	list_for_each_entry_safe(gpio_res, gpio_temp,
		&cam_res->gpio_res_list, list) {
		list_for_each_entry_safe(dev_res, dev_temp,
			&gpio_res->dev_list, list) {
			list_del_init(&dev_res->list);
			kfree(dev_res);
		}
		list_del_init(&gpio_res->list);
		kfree(gpio_res);
	}
	mutex_unlock(&cam_res->gpio_res_lock);

	mutex_lock(&cam_res->clk_res_lock);
	cam_res->shared_clk_ref_count = 0;
	mutex_unlock(&cam_res->clk_res_lock);
}

int cam_res_mgr_shared_pinctrl_init(void)
{
	struct cam_soc_pinctrl_info *pinctrl_info;

	/*
	 * We allow the cam_res is NULL or shared_gpio_enabled
	 * is false, it means this driver no probed or doesn't
	 * have shared gpio in this device.
	 */
	if (!cam_res || !cam_res->shared_gpio_enabled) {
		CAM_DBG(CAM_RES, "Not support shared gpio.");
		return 0;
	}

	if (cam_res->pstatus != PINCTRL_STATUS_PUT) {
		CAM_DBG(CAM_RES, "The shared pinctrl already been got.");
		return 0;
	}

	pinctrl_info = &cam_res->dt.pinctrl_info;

	pinctrl_info->pinctrl =
		devm_pinctrl_get(cam_res->dev);
	if (IS_ERR_OR_NULL(pinctrl_info->pinctrl)) {
		CAM_ERR(CAM_RES, "Pinctrl not available");
		cam_res->shared_gpio_enabled = false;
		return -EINVAL;
	}

	pinctrl_info->gpio_state_active =
		pinctrl_lookup_state(pinctrl_info->pinctrl,
			CAM_RES_MGR_DEFAULT);
	if (IS_ERR_OR_NULL(pinctrl_info->gpio_state_active)) {
		CAM_ERR(CAM_RES,
			"Failed to get the active state pinctrl handle");
		cam_res->shared_gpio_enabled = false;
		return -EINVAL;
	}

	pinctrl_info->gpio_state_suspend =
		pinctrl_lookup_state(pinctrl_info->pinctrl,
			CAM_RES_MGR_SLEEP);
	if (IS_ERR_OR_NULL(pinctrl_info->gpio_state_suspend)) {
		CAM_ERR(CAM_RES,
			"Failed to get the active state pinctrl handle");
		cam_res->shared_gpio_enabled = false;
		return -EINVAL;
	}

	mutex_lock(&cam_res->gpio_res_lock);
	cam_res->pstatus = PINCTRL_STATUS_GOT;
	mutex_unlock(&cam_res->gpio_res_lock);

	return 0;
}
EXPORT_SYMBOL(cam_res_mgr_shared_pinctrl_init);

static bool cam_res_mgr_shared_pinctrl_check_hold(void)
{
	int index = 0;
	int dev_num = 0;
	bool hold = false;
	struct list_head *list;
	struct cam_gpio_res *gpio_res;
	struct cam_res_mgr_dt *dt = &cam_res->dt;

	for (; index < dt->num_shared_gpio; index++) {
		list_for_each_entry(gpio_res,
			&cam_res->gpio_res_list, list) {

			if (gpio_res->gpio ==
				dt->shared_gpio[index]) {
				list_for_each(list, &gpio_res->dev_list)
					dev_num++;

				if (dev_num >= 2) {
					hold = true;
					break;
				}
			}
		}
	}

	if (cam_res->shared_clk_ref_count > 1)
		hold = true;

	return hold;
}

void cam_res_mgr_shared_pinctrl_put(void)
{
	struct cam_soc_pinctrl_info *pinctrl_info;

	if (!cam_res || !cam_res->shared_gpio_enabled) {
		CAM_DBG(CAM_RES, "Not support shared gpio.");
		return;
	}

	mutex_lock(&cam_res->gpio_res_lock);
	if (cam_res->pstatus == PINCTRL_STATUS_PUT) {
		CAM_DBG(CAM_RES, "The shared pinctrl already been put");
		mutex_unlock(&cam_res->gpio_res_lock);
		return;
	}

	if (cam_res_mgr_shared_pinctrl_check_hold()) {
		CAM_INFO(CAM_RES, "Need hold put this pinctrl");
		mutex_unlock(&cam_res->gpio_res_lock);
		return;
	}

	pinctrl_info = &cam_res->dt.pinctrl_info;

	devm_pinctrl_put(pinctrl_info->pinctrl);

	cam_res->pstatus = PINCTRL_STATUS_PUT;
	mutex_unlock(&cam_res->gpio_res_lock);
}
EXPORT_SYMBOL(cam_res_mgr_shared_pinctrl_put);

int cam_res_mgr_shared_pinctrl_select_state(bool active)
{
	int rc = 0;
	struct cam_soc_pinctrl_info *pinctrl_info;

	if (!cam_res || !cam_res->shared_gpio_enabled) {
		CAM_DBG(CAM_RES, "Not support shared gpio.");
		return 0;
	}

	mutex_lock(&cam_res->gpio_res_lock);
	if (cam_res->pstatus == PINCTRL_STATUS_PUT) {
		CAM_DBG(CAM_RES, "The shared pinctrl alerady been put.!");
		mutex_unlock(&cam_res->gpio_res_lock);
		return 0;
	}

	pinctrl_info = &cam_res->dt.pinctrl_info;

	if (active && (cam_res->pstatus != PINCTRL_STATUS_ACTIVE)) {
		rc = pinctrl_select_state(pinctrl_info->pinctrl,
			pinctrl_info->gpio_state_active);
		cam_res->pstatus = PINCTRL_STATUS_ACTIVE;
	} else if (!active &&
		!cam_res_mgr_shared_pinctrl_check_hold()) {
		rc = pinctrl_select_state(pinctrl_info->pinctrl,
			pinctrl_info->gpio_state_suspend);
		cam_res->pstatus = PINCTRL_STATUS_SUSPEND;
	}
	mutex_unlock(&cam_res->gpio_res_lock);

	return rc;
}
EXPORT_SYMBOL(cam_res_mgr_shared_pinctrl_select_state);

int cam_res_mgr_shared_pinctrl_post_init(void)
{
	int ret = 0;
	struct cam_soc_pinctrl_info *pinctrl_info;

	if (!cam_res || !cam_res->shared_gpio_enabled) {
		CAM_DBG(CAM_RES, "Not support shared gpio.");
		return ret;
	}

	mutex_lock(&cam_res->gpio_res_lock);
	if (cam_res->pstatus == PINCTRL_STATUS_PUT) {
		CAM_DBG(CAM_RES, "The shared pinctrl alerady been put.!");
		mutex_unlock(&cam_res->gpio_res_lock);
		return ret;
	}

	pinctrl_info = &cam_res->dt.pinctrl_info;

	/*
	 * If no gpio resource in gpio_res_list, and
	 * no shared clk now, it means this device
	 * don't have shared gpio.
	 */
	if (list_empty(&cam_res->gpio_res_list) &&
		cam_res->shared_clk_ref_count < 1) {
		ret = pinctrl_select_state(pinctrl_info->pinctrl,
			pinctrl_info->gpio_state_suspend);
		devm_pinctrl_put(pinctrl_info->pinctrl);
		cam_res->pstatus = PINCTRL_STATUS_PUT;
	}
	mutex_unlock(&cam_res->gpio_res_lock);

	return ret;
}
EXPORT_SYMBOL(cam_res_mgr_shared_pinctrl_post_init);

static int cam_res_mgr_add_device(struct device *dev,
	struct cam_gpio_res *gpio_res)
{
	struct cam_dev_res *dev_res = NULL;

	dev_res = kzalloc(sizeof(struct cam_dev_res), GFP_KERNEL);
	if (!dev_res)
		return -ENOMEM;

	dev_res->dev = dev;
	INIT_LIST_HEAD(&dev_res->list);

	list_add_tail(&dev_res->list, &gpio_res->dev_list);

	return 0;
}

static bool cam_res_mgr_gpio_is_shared(uint gpio)
{
	int index = 0;
	bool found = false;
	struct cam_res_mgr_dt *dt = &cam_res->dt;

	for (; index < dt->num_shared_gpio; index++) {
		if (gpio == dt->shared_gpio[index]) {
			found = true;
			break;
		}
	}

	return found;
}

int cam_res_mgr_gpio_request(struct device *dev, uint gpio,
		unsigned long flags, const char *label)
{
	int rc = 0;
	bool found = false;
	struct cam_gpio_res *gpio_res = NULL;

	if (cam_res && cam_res->shared_gpio_enabled) {
		mutex_lock(&cam_res->gpio_res_lock);
		list_for_each_entry(gpio_res, &cam_res->gpio_res_list, list) {
			if (gpio == gpio_res->gpio) {
				found = true;
				break;
			}
		}
		mutex_unlock(&cam_res->gpio_res_lock);
	}

	/*
	 * found equal to false has two situation:
	 * 1. shared gpio not enabled
	 * 2. shared gpio enabled, but not find this gpio
	 *    from the gpio_res_list
	 * These two situation both need request gpio.
	 */
	if (!found) {
		rc = gpio_request_one(gpio, flags, label);
                if(rc==0 && gpio==69){
                 CAM_ERR(CAM_RES, "gpio %d:%s request successly",
                                gpio, label);
                }
		if (rc) {
			CAM_ERR(CAM_RES, "gpio %d:%s request fails",
				gpio, label);
			///ALTEK_TAG_HwMiniISP>>>
			/*Dual sensor use the same GPIO so that GPIO request fails, bypass this issue*/
			if((!strcmp(label, "CAM_CUSTOM0") || !strcmp(label, "CAM_CUSTOM2")) && rc == -16){
				CAM_INFO(CAM_RES, "Miniisp power gpio %d : %s",gpio, label);
				rc = 0;
			}
			else
				return rc;
			///ALTEK_TAG_HwMiniISP<<<
		}
                
	}

	/*
	 * If the gpio is in the shared list, and not find
	 * from gpio_res_list, then insert a cam_gpio_res
	 * to gpio_res_list.
	 */
	if (!found && cam_res
		&& cam_res->shared_gpio_enabled &&
		cam_res_mgr_gpio_is_shared(gpio)) {

		gpio_res = kzalloc(sizeof(struct cam_gpio_res), GFP_KERNEL);
		if (!gpio_res)
			return -ENOMEM;

		gpio_res->gpio = gpio;
		gpio_res->power_on_count = 0;
		INIT_LIST_HEAD(&gpio_res->list);
		INIT_LIST_HEAD(&gpio_res->dev_list);

		rc = cam_res_mgr_add_device(dev, gpio_res);
		if (rc) {
			kfree(gpio_res);
			return rc;
		}

		mutex_lock(&cam_res->gpio_res_lock);
		list_add_tail(&gpio_res->list, &cam_res->gpio_res_list);
		mutex_unlock(&cam_res->gpio_res_lock);
	}

	if (found && cam_res
		&& cam_res->shared_gpio_enabled) {
		struct cam_dev_res *dev_res = NULL;

		found = 0;
		mutex_lock(&cam_res->gpio_res_lock);
		list_for_each_entry(dev_res, &gpio_res->dev_list, list) {
			if (dev_res->dev == dev) {
				found = 1;
				break;
			}
		}

		if (!found)
			rc = cam_res_mgr_add_device(dev, gpio_res);

		mutex_unlock(&cam_res->gpio_res_lock);
	}

	return rc;
}
EXPORT_SYMBOL(cam_res_mgr_gpio_request);

static void cam_res_mgr_gpio_free(struct device *dev, uint gpio)
{
	bool found = false;
	bool need_free = true;
	int dev_num =  0;
	struct cam_gpio_res *gpio_res = NULL;

	if (cam_res && cam_res->shared_gpio_enabled) {
		mutex_lock(&cam_res->gpio_res_lock);
		list_for_each_entry(gpio_res, &cam_res->gpio_res_list, list) {
			if (gpio == gpio_res->gpio) {
				found = true;
				break;
			}
		}
		mutex_unlock(&cam_res->gpio_res_lock);
	}

	if (found && cam_res
		&& cam_res->shared_gpio_enabled) {
		struct list_head *list;
		struct cam_dev_res *dev_res = NULL;

		mutex_lock(&cam_res->gpio_res_lock);
		/* Count the dev number in the dev_list */
		list_for_each(list, &gpio_res->dev_list)
			dev_num++;

		/*
		 * Need free the gpio if only has last 1 device
		 * in the dev_list, otherwise, not free this
		 * gpio.
		 */
		if (dev_num == 1) {
			dev_res = list_first_entry(&gpio_res->dev_list,
				struct cam_dev_res, list);
			list_del_init(&dev_res->list);
			kfree(dev_res);

			list_del_init(&gpio_res->list);
			kfree(gpio_res);
		} else {
			list_for_each_entry(dev_res,
				&gpio_res->dev_list, list) {
				if (dev_res->dev == dev) {
					list_del_init(&dev_res->list);
					kfree(dev_res);
					need_free = false;
					break;
				}
			}
		}
		mutex_unlock(&cam_res->gpio_res_lock);
	}

	if (need_free)
		gpio_free(gpio);
}

void cam_res_mgr_gpio_free_arry(struct device *dev,
		const struct cam_gpio *array, size_t num)
{
	while (num--)
		cam_res_mgr_gpio_free(dev, (array[num]).gpio);
}
EXPORT_SYMBOL(cam_res_mgr_gpio_free_arry);

int cam_res_mgr_gpio_set_value(unsigned int gpio, int value)
{
	int rc = 0;
	bool found = false;
	struct cam_gpio_res *gpio_res = NULL;

        CAM_DBG(CAM_RES,"cansleep0 GPIO(%d) val(%d)", gpio, value);
	if (cam_res && cam_res->shared_gpio_enabled) {
		mutex_lock(&cam_res->gpio_res_lock);
		list_for_each_entry(gpio_res, &cam_res->gpio_res_list, list) {
			if (gpio == gpio_res->gpio) {
				found = true;
				break;
			}
		}
		mutex_unlock(&cam_res->gpio_res_lock);
	}
        CAM_DBG(CAM_RES,"cansleep1 GPIO(%d) val(%d)", gpio, value);

	/*
	 * Set the value directly if can't find the gpio from
	 * gpio_res_list, otherwise, need add ref count support
	 **/
	if (!found) {
		gpio_set_value_cansleep(gpio, value);
                CAM_DBG(CAM_RES,"cansleep2 GPIO(%d) val(%d)", gpio, value);
	} else {
                CAM_DBG(CAM_RES,"cansleep3 GPIO(%d) val(%d)", gpio, value);
		if (value) {
                        CAM_DBG(CAM_RES,"cansleep4 GPIO(%d) val(%d)", gpio, value);
			gpio_res->power_on_count++;
			if (gpio_res->power_on_count < 2) {
                                CAM_DBG(CAM_RES,"cansleep5 GPIO(%d) val(%d)", gpio, value);
				gpio_set_value_cansleep(gpio, value);
				CAM_DBG(CAM_RES,
					"Shared GPIO(%d) : HIGH", gpio);
			}
		} else {
                        CAM_DBG(CAM_RES,"cansleep6 GPIO(%d) val(%d)", gpio, value);
			gpio_res->power_on_count--;
			if (gpio_res->power_on_count < 1) {
				gpio_set_value_cansleep(gpio, value);
				CAM_DBG(CAM_RES,
					"Shared GPIO(%d) : LOW", gpio);
			}
		}
	}

	return rc;
}
EXPORT_SYMBOL(cam_res_mgr_gpio_set_value);

void cam_res_mgr_shared_clk_config(bool value)
{
	if (!cam_res)
		return;

	mutex_lock(&cam_res->clk_res_lock);
	if (value)
		cam_res->shared_clk_ref_count++;
	else
		cam_res->shared_clk_ref_count--;
	mutex_unlock(&cam_res->clk_res_lock);
}
EXPORT_SYMBOL(cam_res_mgr_shared_clk_config);

static int cam_res_mgr_parse_dt(struct device *dev)
{
	int rc = 0;
	int i;
	struct device_node *of_node = NULL;
	struct cam_res_mgr_dt *dt = &cam_res->dt;

	of_node = dev->of_node;

	dt->num_shared_gpio = of_count_phandle_with_args(of_node,
		"gpios", "#gpio-cells");

	if (dt->num_shared_gpio > MAX_SHARED_GPIO_SIZE ||
		dt->num_shared_gpio <= 0) {
		/*
		 * Not really an error, it means dtsi not configure
		 * the shared gpio.
		 */
		CAM_DBG(CAM_RES, "Invalid GPIO number %d. No shared gpio.",
			dt->num_shared_gpio);
		return -EINVAL;
	}

	for (i = 0; i < dt->num_shared_gpio; i++) {
		rc = cam_soc_util_get_gpio(of_node, i);
		if (rc < 0)
			return rc;
		dt->shared_gpio[i] = rc;
	}

	dt->pinctrl_info.pinctrl = devm_pinctrl_get(dev);
	if (IS_ERR_OR_NULL(dt->pinctrl_info.pinctrl)) {
		CAM_ERR(CAM_RES, "Pinctrl not available");
		return -EINVAL;
	}

	/*
	 * Check the pinctrl state to make sure the gpio
	 * shared enabled.
	 */
	dt->pinctrl_info.gpio_state_active =
		pinctrl_lookup_state(dt->pinctrl_info.pinctrl,
			CAM_RES_MGR_DEFAULT);
	if (IS_ERR_OR_NULL(dt->pinctrl_info.gpio_state_active)) {
		CAM_ERR(CAM_RES,
			"Failed to get the active state pinctrl handle");
		return -EINVAL;
	}

	dt->pinctrl_info.gpio_state_suspend =
		pinctrl_lookup_state(dt->pinctrl_info.pinctrl,
			CAM_RES_MGR_SLEEP);
	if (IS_ERR_OR_NULL(dt->pinctrl_info.gpio_state_suspend)) {
		CAM_ERR(CAM_RES,
			"Failed to get the active state pinctrl handle");
		return -EINVAL;
	}

	devm_pinctrl_put(dt->pinctrl_info.pinctrl);

	return 0;
}

static int cam_res_mgr_probe(struct platform_device *pdev)
{
	int rc = 0;

	cam_res = kzalloc(sizeof(*cam_res), GFP_KERNEL);
	if (!cam_res)
		return -ENOMEM;

	cam_res->dev = &pdev->dev;
	mutex_init(&cam_res->gpio_res_lock);
	mutex_init(&cam_res->clk_res_lock);

	rc = cam_res_mgr_parse_dt(&pdev->dev);
	if (rc) {
		CAM_INFO(CAM_RES, "Disable shared gpio support.");
		cam_res->shared_gpio_enabled = false;
	} else {
		CAM_INFO(CAM_RES, "Enable shared gpio support.");
		cam_res->shared_gpio_enabled = true;
	}

	cam_res->shared_clk_ref_count = 0;
	cam_res->pstatus = PINCTRL_STATUS_PUT;

	INIT_LIST_HEAD(&cam_res->gpio_res_list);

	return 0;
}

static void cam_res_mgr_remove(struct platform_device *pdev)
{
	if (cam_res) {
		cam_res_mgr_free_res();
		kfree(cam_res);
		cam_res = NULL;
	}
}

static const struct of_device_id cam_res_mgr_dt_match[] = {
	{.compatible = "qcom,cam-res-mgr"},
	{}
};
MODULE_DEVICE_TABLE(of, cam_res_mgr_dt_match);

static struct platform_driver cam_res_mgr_driver = {
	.probe = cam_res_mgr_probe,
	.remove = cam_res_mgr_remove,
	.driver = {
		.name = "cam_res_mgr",
		.owner = THIS_MODULE,
		.of_match_table = cam_res_mgr_dt_match,
		.suppress_bind_attrs = true,
	},
};

int cam_res_mgr_init(void)
{
	return platform_driver_register(&cam_res_mgr_driver);
}

void cam_res_mgr_exit(void)
{
	platform_driver_unregister(&cam_res_mgr_driver);
}

MODULE_DESCRIPTION("Camera resource manager driver");
MODULE_LICENSE("GPL v2");
