/* Copyright (c) 2016-2018, The Linux Foundation. All rights reserved.
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

#include <linux/module.h>
#include <linux/slab.h>
#include <linux/platform_device.h>
#include <linux/dma-mapping.h>
#include <media/v4l2-fh.h>
#include <media/v4l2-device.h>
#include <media/v4l2-event.h>
#include <media/v4l2-ioctl.h>
#include <media/cam_req_mgr.h>
#include <media/cam_defs.h>
#include "cam_req_mgr_dev.h"
#include "cam_req_mgr_util.h"
#include "cam_req_mgr_core.h"
#include "cam_subdev.h"
#include "cam_mem_mgr.h"
#include "cam_debug_util.h"
/*
 * linux/slub_def.h was an internal SLUB header (removed from
 * the public include path); it was pulled in for ksize() which is unused here.
 * Dropped — linux/slab.h (included above) provides the standard allocator API.
 */
#include <linux/pm_qos.h>

#define CAM_REQ_MGR_EVENT_MAX 30
#define CAMERA_DISABLE_PC_LATENCY 100
#define CAMERA_ENABLE_PC_LATENCY PM_QOS_DEFAULT_VALUE

static struct cam_req_mgr_device g_dev;
struct kmem_cache *g_cam_req_mgr_timer_cachep;
static struct pm_qos_request cam_pm_qos_request;

static int cam_media_device_setup(struct device *dev)
{
	int rc;

	g_dev.v4l2_dev->mdev = kzalloc(sizeof(*g_dev.v4l2_dev->mdev),
		GFP_KERNEL);
	if (!g_dev.v4l2_dev->mdev) {
		rc = -ENOMEM;
		goto mdev_fail;
	}

	media_device_init(g_dev.v4l2_dev->mdev);
	g_dev.v4l2_dev->mdev->dev = dev;
	strscpy(g_dev.v4l2_dev->mdev->model, CAM_REQ_MGR_VNODE_NAME,
		sizeof(g_dev.v4l2_dev->mdev->model));

	rc = media_device_register(g_dev.v4l2_dev->mdev);
	if (rc)
		goto media_fail;

	return rc;

media_fail:
	kfree(g_dev.v4l2_dev->mdev);
	g_dev.v4l2_dev->mdev = NULL;
mdev_fail:
	return rc;
}

static void cam_media_device_cleanup(void)
{
	if (g_dev.video)
		media_entity_cleanup(&g_dev.video->entity);
	media_device_unregister(g_dev.v4l2_dev->mdev);
	media_device_cleanup(g_dev.v4l2_dev->mdev);
	kfree(g_dev.v4l2_dev->mdev);
	g_dev.v4l2_dev->mdev = NULL;
}

static int cam_v4l2_device_setup(struct device *dev)
{
	int rc;

	g_dev.v4l2_dev = kzalloc(sizeof(*g_dev.v4l2_dev),
		GFP_KERNEL);
	if (!g_dev.v4l2_dev)
		return -ENOMEM;

	rc = v4l2_device_register(dev, g_dev.v4l2_dev);
	if (rc)
		goto reg_fail;

	return rc;

reg_fail:
	kfree(g_dev.v4l2_dev);
	g_dev.v4l2_dev = NULL;
	return rc;
}

static void cam_v4l2_device_cleanup(void)
{
	v4l2_device_unregister(g_dev.v4l2_dev);
	kfree(g_dev.v4l2_dev);
	g_dev.v4l2_dev = NULL;
}

static void cam_pm_qos_add_request(void)
{
	/*
	 * The global PM-QoS class API (pm_qos_*_request +
	 * PM_QOS_CPU_DMA_LATENCY) was replaced by the dedicated CPU-latency
	 * QoS API. cpu_latency_qos_add_request() implies the CPU-DMA-latency
	 * target, so the class argument is gone.
	 */
	cpu_latency_qos_add_request(&cam_pm_qos_request, PM_QOS_DEFAULT_VALUE);
}

static void cam_pm_qos_remove_request(void)
{
	CAM_INFO(CAM_SENSOR, "%s: remove request", __func__);
	cpu_latency_qos_remove_request(&cam_pm_qos_request);
}

static void cam_pm_qos_update_request(int val) {
	CAM_INFO(CAM_SENSOR, "%s: update request %d", __func__, val);
	cpu_latency_qos_update_request(&cam_pm_qos_request, val);
}

static int cam_req_mgr_open(struct file *filep)
{
	int rc;

	mutex_lock(&g_dev.cam_lock);

	g_dev.open_cnt++;

	if (g_dev.open_cnt == 1) {
		CAM_INFO(CAM_CRM, "%s:%d disalbe lpm", __func__, __LINE__);
		/* register msm_v4l2_pm_qos_request */
		cam_pm_qos_add_request();
		cam_pm_qos_update_request(CAMERA_DISABLE_PC_LATENCY);
	}

	if (g_dev.open_cnt > 1) {
		rc = -EALREADY;
		goto end;
	}

	rc = v4l2_fh_open(filep);
	if (rc) {
		CAM_ERR(CAM_CRM, "v4l2_fh_open failed: %d", rc);
		goto end;
	}

	spin_lock_bh(&g_dev.cam_eventq_lock);
	g_dev.cam_eventq = filep->private_data;
	spin_unlock_bh(&g_dev.cam_eventq_lock);

	rc = cam_mem_mgr_init(g_dev.v4l2_dev->dev);
	if (rc) {
		CAM_ERR(CAM_CRM, "mem mgr init failed");
		goto mem_mgr_init_fail;
	}

	mutex_unlock(&g_dev.cam_lock);
	return rc;

mem_mgr_init_fail:
	v4l2_fh_release(filep);
end:
	if (g_dev.open_cnt <= 1) {
		/* remove msm_v4l2_pm_qos_request */
		cam_pm_qos_update_request(CAMERA_ENABLE_PC_LATENCY);
		cam_pm_qos_remove_request();
	}
	g_dev.open_cnt--;
	mutex_unlock(&g_dev.cam_lock);
	return rc;
}

static unsigned int cam_req_mgr_poll(struct file *f,
	struct poll_table_struct *pll_table)
{
	int rc = 0;
	struct v4l2_fh *eventq = f->private_data;

	if (!eventq)
		return -EINVAL;

	poll_wait(f, &eventq->wait, pll_table);
	if (v4l2_event_pending(eventq))
		rc = POLLPRI;

	return rc;
}

static int cam_req_mgr_close(struct file *filep)
{
	struct v4l2_subdev *sd;
	struct v4l2_fh *vfh = filep->private_data;
	struct v4l2_subdev_fh *subdev_fh = to_v4l2_subdev_fh(vfh);

	mutex_lock(&g_dev.cam_lock);

	if (g_dev.open_cnt <= 0) {
		mutex_unlock(&g_dev.cam_lock);
		return -EINVAL;
	}

	g_dev.open_cnt--;
	if (g_dev.open_cnt > 0) {
		CAM_ERR(CAM_CRM, "%s:%d open_cnt %d", __func__, __LINE__, g_dev.open_cnt);
		mutex_unlock(&g_dev.cam_lock);
		return 0;
	}
	cam_req_mgr_handle_core_shutdown();
	list_for_each_entry(sd, &g_dev.v4l2_dev->subdevs, list) {
		if (!(sd->flags & V4L2_SUBDEV_FL_HAS_DEVNODE))
			continue;
		if (sd->internal_ops && sd->internal_ops->close) {
			CAM_DBG(CAM_CRM, "Invoke subdev close for device %s",
				sd->name);
			sd->internal_ops->close(sd, subdev_fh);
		}
	}

	v4l2_fh_release(filep);

	spin_lock_bh(&g_dev.cam_eventq_lock);
	g_dev.cam_eventq = NULL;
	spin_unlock_bh(&g_dev.cam_eventq_lock);

	cam_req_mgr_util_free_hdls();
	cam_mem_mgr_deinit();

	CAM_INFO(CAM_CRM, "%s:%d enable lpm", __func__, __LINE__);
	cam_pm_qos_update_request(CAMERA_ENABLE_PC_LATENCY);
	/* remove msm_v4l2_pm_qos_request */
	cam_pm_qos_remove_request();
	mutex_unlock(&g_dev.cam_lock);

	return 0;
}

static struct v4l2_file_operations g_cam_fops = {
	.owner  = THIS_MODULE,
	.open   = cam_req_mgr_open,
	.poll   = cam_req_mgr_poll,
	.release = cam_req_mgr_close,
	.unlocked_ioctl   = video_ioctl2,
#ifdef CONFIG_COMPAT
	.compat_ioctl32 = video_ioctl2,
#endif
};

static int cam_subscribe_event(struct v4l2_fh *fh,
	const struct v4l2_event_subscription *sub)
{
	return v4l2_event_subscribe(fh, sub, CAM_REQ_MGR_EVENT_MAX, NULL);
}

static int cam_unsubscribe_event(struct v4l2_fh *fh,
	const struct v4l2_event_subscription *sub)
{
	return v4l2_event_unsubscribe(fh, sub);
}

static long cam_private_ioctl(struct file *file, void *fh,
	bool valid_prio, unsigned int cmd, void *arg)
{
	int rc;
	struct cam_control *k_ioctl;

	if ((!arg) || (cmd != VIDIOC_CAM_CONTROL))
		return -EINVAL;

	k_ioctl = (struct cam_control *)arg;

	if (!k_ioctl->handle)
		return -EINVAL;

	switch (k_ioctl->op_code) {
	case CAM_REQ_MGR_CREATE_SESSION: {
		struct cam_req_mgr_session_info ses_info;

		if (k_ioctl->size != sizeof(ses_info))
			return -EINVAL;

		if (copy_from_user(&ses_info,
			(void *)k_ioctl->handle,
			k_ioctl->size)) {
			return -EFAULT;
		}

		rc = cam_req_mgr_create_session(&ses_info);
		if (!rc)
			if (copy_to_user((void *)k_ioctl->handle,
				&ses_info, k_ioctl->size))
				rc = -EFAULT;
		}
		break;

	case CAM_REQ_MGR_DESTROY_SESSION: {
		struct cam_req_mgr_session_info ses_info;

		if (k_ioctl->size != sizeof(ses_info))
			return -EINVAL;

		if (copy_from_user(&ses_info,
			(void *)k_ioctl->handle,
			k_ioctl->size)) {
			return -EFAULT;
		}

		rc = cam_req_mgr_destroy_session(&ses_info);
		}
		break;

	case CAM_REQ_MGR_LINK: {
		struct cam_req_mgr_link_info link_info;

		if (k_ioctl->size != sizeof(link_info))
			return -EINVAL;

		if (copy_from_user(&link_info,
			(void *)k_ioctl->handle,
			k_ioctl->size)) {
			return -EFAULT;
		}

		rc = cam_req_mgr_link(&link_info);
		if (!rc)
			if (copy_to_user((void *)k_ioctl->handle,
				&link_info, k_ioctl->size))
				rc = -EFAULT;
		}
		break;

	case CAM_REQ_MGR_UNLINK: {
		struct cam_req_mgr_unlink_info unlink_info;

		if (k_ioctl->size != sizeof(unlink_info))
			return -EINVAL;

		if (copy_from_user(&unlink_info,
			(void *)k_ioctl->handle,
			k_ioctl->size)) {
			return -EFAULT;
		}

		rc = cam_req_mgr_unlink(&unlink_info);
		}
		break;

	case CAM_REQ_MGR_SCHED_REQ: {
		struct cam_req_mgr_sched_request sched_req;

		if (k_ioctl->size != sizeof(sched_req))
			return -EINVAL;

		if (copy_from_user(&sched_req,
			(void *)k_ioctl->handle,
			k_ioctl->size)) {
			return -EFAULT;
		}

		rc = cam_req_mgr_schedule_request(&sched_req);
		}
		break;

	case CAM_REQ_MGR_FLUSH_REQ: {
		struct cam_req_mgr_flush_info flush_info;

		if (k_ioctl->size != sizeof(flush_info))
			return -EINVAL;

		if (copy_from_user(&flush_info,
			(void *)k_ioctl->handle,
			k_ioctl->size)) {
			return -EFAULT;
		}

		rc = cam_req_mgr_flush_requests(&flush_info);
		}
		break;

	case CAM_REQ_MGR_SYNC_MODE: {
		struct cam_req_mgr_sync_mode sync_info;

		if (k_ioctl->size != sizeof(sync_info))
			return -EINVAL;

		if (copy_from_user(&sync_info,
			(void *)k_ioctl->handle,
			k_ioctl->size)) {
			return -EFAULT;
		}

		rc = cam_req_mgr_sync_config(&sync_info);
		}
		break;
	case CAM_REQ_MGR_ALLOC_BUF: {
		struct cam_mem_mgr_alloc_cmd cmd;

		if (k_ioctl->size != sizeof(cmd))
			return -EINVAL;

		if (copy_from_user(&cmd,
			(void *)k_ioctl->handle,
			k_ioctl->size)) {
			rc = -EFAULT;
			break;
		}

		rc = cam_mem_mgr_alloc_and_map(&cmd);
		if (!rc)
			if (copy_to_user((void *)k_ioctl->handle,
				&cmd, k_ioctl->size)) {
				rc = -EFAULT;
				break;
			}
		}
		break;
	case CAM_REQ_MGR_MAP_BUF: {
		struct cam_mem_mgr_map_cmd cmd;

		if (k_ioctl->size != sizeof(cmd))
			return -EINVAL;

		if (copy_from_user(&cmd,
			(void *)k_ioctl->handle,
			k_ioctl->size)) {
			rc = -EFAULT;
			break;
		}

		rc = cam_mem_mgr_map(&cmd);
		if (!rc)
			if (copy_to_user((void *)k_ioctl->handle,
				&cmd, k_ioctl->size)) {
				rc = -EFAULT;
				break;
			}
		}
		break;
	case CAM_REQ_MGR_RELEASE_BUF: {
		struct cam_mem_mgr_release_cmd cmd;

		if (k_ioctl->size != sizeof(cmd))
			return -EINVAL;

		if (copy_from_user(&cmd,
			(void *)k_ioctl->handle,
			k_ioctl->size)) {
			rc = -EFAULT;
			break;
		}

		rc = cam_mem_mgr_release(&cmd);
		}
		break;
	case CAM_REQ_MGR_CACHE_OPS: {
		struct cam_mem_cache_ops_cmd cmd;

		if (k_ioctl->size != sizeof(cmd))
			return -EINVAL;

		if (copy_from_user(&cmd,
			(void *)k_ioctl->handle,
			k_ioctl->size)) {
			rc = -EFAULT;
			break;
		}

		rc = cam_mem_mgr_cache_ops(&cmd);
		if (rc)
			rc = -EINVAL;
		}
		break;
	case CAM_REQ_MGR_LINK_CONTROL: {
		struct cam_req_mgr_link_control cmd;

		if (k_ioctl->size != sizeof(cmd))
			return -EINVAL;

		if (copy_from_user(&cmd,
			(void __user *)k_ioctl->handle,
			k_ioctl->size)) {
			rc = -EFAULT;
			break;
		}

		rc = cam_req_mgr_link_control(&cmd);
		if (rc)
			rc = -EINVAL;
		}
		break;
	default:
		return -ENOIOCTLCMD;
	}

	return rc;
}

static const struct v4l2_ioctl_ops g_cam_ioctl_ops = {
	.vidioc_subscribe_event = cam_subscribe_event,
	.vidioc_unsubscribe_event = cam_unsubscribe_event,
	.vidioc_default = cam_private_ioctl,
};

static int cam_video_device_setup(void)
{
	int rc;

	g_dev.video = video_device_alloc();
	if (!g_dev.video) {
		rc = -ENOMEM;
		goto video_fail;
	}

	g_dev.video->v4l2_dev = g_dev.v4l2_dev;

	strscpy(g_dev.video->name, "cam-req-mgr",
		sizeof(g_dev.video->name));
	g_dev.video->release = video_device_release;
	g_dev.video->fops = &g_cam_fops;
	g_dev.video->ioctl_ops = &g_cam_ioctl_ops;
	g_dev.video->minor = -1;
	g_dev.video->vfl_type = VFL_TYPE_VIDEO;
	/*
	 * __video_register_device() now WARNs and fails with -EINVAL
	 * when device_caps is 0 (the field became mandatory after 4.9). Set the
	 * caps for this cam-req-mgr v4l2 node so registration succeeds; without
	 * this cam_req_mgr_probe() faults here, g_dev.state never becomes true,
	 * and every camera subdev defers forever on the camera root device.
	 */
	g_dev.video->device_caps = V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_STREAMING;
	rc = media_entity_pads_init(&g_dev.video->entity, 0, NULL);
	if (rc)
		goto v4l2_fail;

	g_dev.video->entity.function = CAM_VNODE_DEVICE_TYPE;
	g_dev.video->entity.name = video_device_node_name(g_dev.video);

	rc = video_register_device(g_dev.video, VFL_TYPE_VIDEO, -1);
	if (rc)
		goto entity_fail;

	return rc;

entity_fail:
	media_entity_cleanup(&g_dev.video->entity);
v4l2_fail:
	video_device_release(g_dev.video);
	g_dev.video = NULL;
video_fail:
	return rc;
}

int cam_req_mgr_notify_message(struct cam_req_mgr_message *msg,
	uint32_t id,
	uint32_t type)
{
	struct v4l2_event event;
	struct cam_req_mgr_message *ev_header;

	if (!msg)
		return -EINVAL;

	event.id = id;
	event.type = type;
	ev_header = CAM_REQ_MGR_GET_PAYLOAD_PTR(event,
		struct cam_req_mgr_message);
	memcpy(ev_header, msg, sizeof(struct cam_req_mgr_message));
	v4l2_event_queue(g_dev.video, &event);

	return 0;
}
EXPORT_SYMBOL(cam_req_mgr_notify_message);

static void cam_video_device_cleanup(void)
{
	video_unregister_device(g_dev.video);
	g_dev.video = NULL;
}

int cam_register_subdev(struct cam_subdev *csd)
{
	struct v4l2_subdev *sd;
	int rc;

	if (g_dev.state != true) {
		/*
		 * The camera root device (g_dev) is brought up in
		 * cam_req_mgr_late_init() at late_initcall time, but the HW subdev
		 * drivers (csiphy/cpas/cci/isp/...) probe earlier at device_initcall
		 * time. Return -EPROBE_DEFER (not -ENODEV) so the driver core retries
		 * their probe after the root device is ready, instead of failing them
		 * permanently. On 4.9 the initcall timing happened to line up; on
		 * mainline deferred probe is the correct mechanism.
		 */
		CAM_DBG(CAM_CRM, "camera root device not ready yet, defer");
		return -EPROBE_DEFER;
	}

	if (!csd || !csd->name) {
		CAM_ERR(CAM_CRM, "invalid arguments");
		return -EINVAL;
	}

	mutex_lock(&g_dev.dev_lock);

	sd = &csd->sd;
	v4l2_subdev_init(sd, csd->ops);
	sd->owner = THIS_MODULE;
	sd->internal_ops = csd->internal_ops;
	snprintf(sd->name, ARRAY_SIZE(sd->name), csd->name);
	v4l2_set_subdevdata(sd, csd->token);

	sd->flags = csd->sd_flags;
	sd->entity.num_pads = 0;
	sd->entity.pads = NULL;
	sd->entity.function = csd->ent_function;

	rc = v4l2_device_register_subdev(g_dev.v4l2_dev, sd);
	if (rc) {
		CAM_ERR(CAM_CRM, "register subdev failed");
		goto reg_fail;
	}
	g_dev.count++;

	/*
	 * The legacy code REFUSED registering a devnode-backed subdev
	 * once cam_dev_mgr_create_subdev_nodes() had run ("dynamic node not
	 * allowed"). That assumed every HW subdev probed before the late_initcall.
	 * On mainline, deferred probe means cam-isp/jpeg/fd register AFTER node
	 * creation, so they'd be refused and their probe would fail — and their
	 * subdev /dev nodes would never appear. Instead, if nodes were already
	 * created, create this new subdev's node now. v4l2_device_register_subdev_
	 * nodes() is idempotent (skips subdevs that already have sd->devnode).
	 */
	if (g_dev.subdev_nodes_created &&
		(csd->sd_flags & V4L2_SUBDEV_FL_HAS_DEVNODE)) {
		rc = v4l2_device_register_subdev_nodes(g_dev.v4l2_dev);
		if (rc)
			CAM_ERR(CAM_CRM,
				"late subdev node create failed for %s rc=%d",
				csd->name, rc);
	}

reg_fail:
	mutex_unlock(&g_dev.dev_lock);
	return rc;
}
EXPORT_SYMBOL(cam_register_subdev);

int cam_unregister_subdev(struct cam_subdev *csd)
{
	if (g_dev.state != true) {
		CAM_ERR(CAM_CRM, "camera root device not ready yet");
		return -ENODEV;
	}

	mutex_lock(&g_dev.dev_lock);
	v4l2_device_unregister_subdev(&csd->sd);
	g_dev.count--;
	mutex_unlock(&g_dev.dev_lock);

	return 0;
}
EXPORT_SYMBOL(cam_unregister_subdev);

static void cam_req_mgr_remove(struct platform_device *pdev)
{
	cam_req_mgr_core_device_deinit();
	kmem_cache_destroy(g_cam_req_mgr_timer_cachep);
	g_cam_req_mgr_timer_cachep = NULL;
	cam_req_mgr_util_deinit();
	cam_media_device_cleanup();
	cam_video_device_cleanup();
	cam_v4l2_device_cleanup();
	mutex_destroy(&g_dev.dev_lock);
	mutex_destroy(&g_dev.cam_lock);
	g_dev.state = false;
	g_dev.subdev_nodes_created = false;
}

static int cam_req_mgr_probe(struct platform_device *pdev)
{
	int rc;

	rc = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64));
	if (rc)
		return rc;

	rc = cam_v4l2_device_setup(&pdev->dev);
	if (rc)
		return rc;

	rc = cam_media_device_setup(&pdev->dev);
	if (rc)
		goto media_setup_fail;

	g_dev.open_cnt = 0;
	mutex_init(&g_dev.cam_lock);
	spin_lock_init(&g_dev.cam_eventq_lock);
	g_dev.subdev_nodes_created = false;
	mutex_init(&g_dev.dev_lock);

	rc = cam_req_mgr_util_init();
	if (rc) {
		CAM_ERR(CAM_CRM, "cam req mgr util init is failed");
		goto req_mgr_util_fail;
	}

	rc = cam_req_mgr_core_device_init();
	if (rc) {
		CAM_ERR(CAM_CRM, "core device setup failed");
		goto req_mgr_core_fail;
	}

	if (g_cam_req_mgr_timer_cachep == NULL) {
		g_cam_req_mgr_timer_cachep = kmem_cache_create("crm_timer",
			sizeof(struct cam_req_mgr_timer), 64,
			SLAB_CONSISTENCY_CHECKS | SLAB_RED_ZONE |
			SLAB_POISON | SLAB_STORE_USER, NULL);
		if (!g_cam_req_mgr_timer_cachep) {
			CAM_ERR(CAM_CRM,
				"Failed to create kmem_cache for crm_timer");
			rc = -ENOMEM;
			goto timer_setup_fail;
		} else
			/*
			 * struct kmem_cache is opaque in
			 * mainline (the private ->name member lived in the
			 * downstream linux/slub_def.h, now removed). Drop the
			 * debug deref; the cache name is the literal above.
			 */
			CAM_DBG(CAM_CRM, "Name : crm_timer");
	}

	/* Publish only after every state used by open and close is initialized. */
	rc = cam_video_device_setup();
	if (rc)
		goto video_setup_fail;
	g_dev.state = true;
	return rc;

video_setup_fail:
	kmem_cache_destroy(g_cam_req_mgr_timer_cachep);
	g_cam_req_mgr_timer_cachep = NULL;
timer_setup_fail:
	cam_req_mgr_core_device_deinit();
req_mgr_core_fail:
	cam_req_mgr_util_deinit();
req_mgr_util_fail:
	mutex_destroy(&g_dev.dev_lock);
	mutex_destroy(&g_dev.cam_lock);
	cam_media_device_cleanup();
media_setup_fail:
	cam_v4l2_device_cleanup();
	return rc;
}

static const struct of_device_id cam_req_mgr_dt_match[] = {
	{.compatible = "qcom,cam-req-mgr"},
	{}
};
MODULE_DEVICE_TABLE(of, cam_req_mgr_dt_match);

static struct platform_driver cam_req_mgr_driver = {
	.probe = cam_req_mgr_probe,
	.remove = cam_req_mgr_remove,
	.driver = {
		.name = "cam_req_mgr",
		.owner = THIS_MODULE,
		.of_match_table = cam_req_mgr_dt_match,
		.suppress_bind_attrs = true,
	},
};

static int cam_dev_mgr_create_subdev_nodes(void)
{
	int rc;
	struct v4l2_subdev *sd;

	if (!g_dev.v4l2_dev)
		return -EINVAL;

	if (g_dev.state != true) {
		CAM_ERR(CAM_CRM, "camera root device not ready yet");
		return -ENODEV;
	}

	mutex_lock(&g_dev.dev_lock);
	if (g_dev.subdev_nodes_created)	{
		rc = -EEXIST;
		goto create_fail;
	}

	rc = v4l2_device_register_subdev_nodes(g_dev.v4l2_dev);
	if (rc) {
		CAM_ERR(CAM_CRM, "failed to register the sub devices");
		goto create_fail;
	}

	list_for_each_entry(sd, &g_dev.v4l2_dev->subdevs, list) {
		if (!(sd->flags & V4L2_SUBDEV_FL_HAS_DEVNODE))
			continue;
		sd->entity.name = video_device_node_name(sd->devnode);
		CAM_DBG(CAM_CRM, "created node :%s", sd->entity.name);
	}

	g_dev.subdev_nodes_created = true;

create_fail:
	mutex_unlock(&g_dev.dev_lock);
	return rc;
}

int cam_req_mgr_init(void)
{
	return platform_driver_register(&cam_req_mgr_driver);
}

int cam_req_mgr_late_init(void)
{
	return cam_dev_mgr_create_subdev_nodes();
}

void cam_req_mgr_exit(void)
{
	platform_driver_unregister(&cam_req_mgr_driver);
}

MODULE_DESCRIPTION("Camera Request Manager");
MODULE_LICENSE("GPL v2");
