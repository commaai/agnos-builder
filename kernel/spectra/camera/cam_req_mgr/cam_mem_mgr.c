/* Copyright (c) 2016-2019, The Linux Foundation. All rights reserved.
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

/*
 * Memory backend ported from the downstream Qualcomm ION
 * heap API (msm_ion_client_create / ion_alloc / ion_handle / ion_map_kernel /
 * ion_import_dma_buf_fd / ion_phys ...) to the mainline dma-buf framework.
 *
 * Mainline removed ION entirely. The in-kernel consumer side of the dma-buf
 * *heaps* framework (dma_heap_find / dma_heap_buffer_alloc) is NOT exported for
 * built-in drivers (dma_heap_buffer_alloc() is static in
 * drivers/dma-buf/dma-heap.c and only yields a userspace fd; there is no
 * heap-by-name lookup for kernel consumers). So for the KERNEL-side allocations
 * (cam_mem_mgr_request_mem / reserve_memory_region / alloc_and_map) this file
 * provides a minimal page-backed dma-buf *exporter* (the cam_mem_mgr_buf_ops
 * below) that is the functional equivalent of the legacy non-secure ION system
 * heap: pages from the buddy allocator, wrapped in a real struct dma_buf with a
 * proper sg_table. cam_smmu then consumes that dma_buf through its normal
 * dma_buf_attach()/dma_buf_map_attachment() path, exactly as it does for an
 * imported userspace buffer.
 *
 * Userspace buffers (the camerad streaming data path on mici) arrive as fds via
 * cam_mem_mgr_map() and are imported with dma_buf_get(fd); cam_smmu's
 * cam_smmu_map_user_iova() takes the fd directly and does the attach/map itself.
 *
 * Kernel CPU mappings use dma_buf_vmap()/dma_buf_vunmap() with struct iosys_map.
 *
 * SECURE / PROTECTED_MODE (stage-2) path: mainline secure assignment goes
 * through qcom_scm_assign_mem, which is not wired here. The non-secure data
 * path does not use it. cam_smmu still owns the stage-2 ION stubs
 * (cam_smmu_compat.h). Allocation of a PROTECTED_MODE buffer in this file
 * falls back to the same page exporter (non-secure backing), so it must not be
 * used for secure content.
 */

#include <linux/module.h>
#include <linux/types.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/dma-buf.h>
#include <linux/dma-mapping.h>
#include <linux/iosys-map.h>
#include <linux/scatterlist.h>
#include <linux/highmem.h>
#include <linux/vmalloc.h>
#include <linux/mm.h>
#include <asm/cacheflush.h>

#include "cam_req_mgr_util.h"
#include "cam_mem_mgr.h"
#include "cam_smmu_api.h"
#include "cam_debug_util.h"

static struct cam_mem_table tbl;
static atomic_t cam_mem_mgr_state = ATOMIC_INIT(CAM_MEM_MGR_UNINITIALIZED);

/*
 * ---------------------------------------------------------------------------
 * Minimal page-backed dma-buf exporter (mainline replacement for the ION system
 * heap on the kernel-allocation path). Single contiguous-list backing buffer;
 * no dynamic attach migration. Produces a real sg_table that cam_smmu maps.
 * ---------------------------------------------------------------------------
 */

/* allocation orders, largest first, to reduce IOMMU TLB pressure (mirrors the
 * mainline system heap's 1MB/64K/4K choice).
 */
static const unsigned int cam_mem_orders[] = { 8, 4, 0 };

struct cam_mem_buffer {
	struct sg_table sg_table;
	struct list_head attachments;
	struct mutex lock;
	unsigned long len;
	unsigned int flags;
	int vmap_cnt;
	void *vaddr;
};

struct cam_mem_attachment {
	struct device *dev;
	struct sg_table table;
	struct list_head list;
	bool mapped;
};

static int cam_mem_dup_sg_table(struct sg_table *from, struct sg_table *to)
{
	struct scatterlist *sg, *new_sg;
	int ret, i;

	ret = sg_alloc_table(to, from->orig_nents, GFP_KERNEL);
	if (ret)
		return ret;

	new_sg = to->sgl;
	for_each_sgtable_sg(from, sg, i) {
		sg_set_page(new_sg, sg_page(sg), sg->length, sg->offset);
		new_sg = sg_next(new_sg);
	}

	return 0;
}

static int cam_mem_buf_attach(struct dma_buf *dmabuf,
	struct dma_buf_attachment *attachment)
{
	struct cam_mem_buffer *buffer = dmabuf->priv;
	struct cam_mem_attachment *a;
	int ret;

	a = kzalloc(sizeof(*a), GFP_KERNEL);
	if (!a)
		return -ENOMEM;

	ret = cam_mem_dup_sg_table(&buffer->sg_table, &a->table);
	if (ret) {
		kfree(a);
		return ret;
	}

	a->dev = attachment->dev;
	INIT_LIST_HEAD(&a->list);
	a->mapped = false;
	attachment->priv = a;

	mutex_lock(&buffer->lock);
	list_add(&a->list, &buffer->attachments);
	mutex_unlock(&buffer->lock);

	return 0;
}

static void cam_mem_buf_detach(struct dma_buf *dmabuf,
	struct dma_buf_attachment *attachment)
{
	struct cam_mem_buffer *buffer = dmabuf->priv;
	struct cam_mem_attachment *a = attachment->priv;

	mutex_lock(&buffer->lock);
	list_del(&a->list);
	mutex_unlock(&buffer->lock);

	sg_free_table(&a->table);
	kfree(a);
}

static struct sg_table *cam_mem_buf_map(struct dma_buf_attachment *attachment,
	enum dma_data_direction direction)
{
	struct cam_mem_attachment *a = attachment->priv;
	struct sg_table *table = &a->table;
	int ret;

	ret = dma_map_sgtable(attachment->dev, table, direction, 0);
	if (ret)
		return ERR_PTR(ret);

	a->mapped = true;
	return table;
}

static void cam_mem_buf_unmap(struct dma_buf_attachment *attachment,
	struct sg_table *table, enum dma_data_direction direction)
{
	struct cam_mem_attachment *a = attachment->priv;

	a->mapped = false;
	dma_unmap_sgtable(attachment->dev, table, direction, 0);
}

static void *cam_mem_buf_do_vmap(struct cam_mem_buffer *buffer)
{
	struct scatterlist *sg;
	int npages = PAGE_ALIGN(buffer->len) / PAGE_SIZE;
	struct page **pages = vmalloc(array_size(npages, sizeof(*pages)));
	struct page **tmp = pages;
	int i, j;
	void *vaddr;
	pgprot_t prot;

	if (!pages)
		return ERR_PTR(-ENOMEM);

	for_each_sgtable_sg(&buffer->sg_table, sg, i) {
		int npages_this_entry = PAGE_ALIGN(sg->length) / PAGE_SIZE;
		struct page *page = sg_page(sg);

		for (j = 0; j < npages_this_entry; j++)
			*(tmp++) = page++;
	}

	/*
	 * Uncached buffers (no CAM_MEM_FLAG_CACHE) must be mapped write-combine,
	 * NOT cached PAGE_KERNEL. The camera SMMU context banks are non-coherent
	 * ("non-coherent table walk"), so a HW block reading through them does
	 * not snoop the CPU cache. The ICP HFI queues (qtbl/cmd_q/msg_q/dbg_q/
	 * sfr) are allocated uncached and the host CPU writes the queue headers
	 * through THIS kva; with a cached mapping those writes sit in the
	 * D-cache and the A5 reads stale queue descriptors -> it never finds the
	 * queues, never posts ICP_INIT_RESP_SUCCESS, and watchdogs. WC makes the
	 * writes immediately visible, matching the legacy uncached ION system
	 * heap. Cached buffers (CAM_MEM_FLAG_CACHE) keep PAGE_KERNEL and rely on
	 * the explicit cache ops in cam_mem_mgr_cache_op().
	 */
	if (buffer->flags & CAM_MEM_FLAG_CACHE)
		prot = PAGE_KERNEL;
	else
		prot = pgprot_writecombine(PAGE_KERNEL);

	vaddr = vmap(pages, npages, VM_MAP, prot);
	vfree(pages);

	if (!vaddr)
		return ERR_PTR(-ENOMEM);

	return vaddr;
}

static int cam_mem_buf_vmap(struct dma_buf *dmabuf, struct iosys_map *map)
{
	struct cam_mem_buffer *buffer = dmabuf->priv;
	void *vaddr;
	int ret = 0;

	mutex_lock(&buffer->lock);
	if (buffer->vmap_cnt) {
		buffer->vmap_cnt++;
		iosys_map_set_vaddr(map, buffer->vaddr);
		goto out;
	}

	vaddr = cam_mem_buf_do_vmap(buffer);
	if (IS_ERR(vaddr)) {
		ret = PTR_ERR(vaddr);
		goto out;
	}

	buffer->vaddr = vaddr;
	buffer->vmap_cnt++;
	iosys_map_set_vaddr(map, buffer->vaddr);
out:
	mutex_unlock(&buffer->lock);

	return ret;
}

static void cam_mem_buf_vunmap(struct dma_buf *dmabuf, struct iosys_map *map)
{
	struct cam_mem_buffer *buffer = dmabuf->priv;

	mutex_lock(&buffer->lock);
	if (!--buffer->vmap_cnt) {
		vunmap(buffer->vaddr);
		buffer->vaddr = NULL;
	}
	mutex_unlock(&buffer->lock);
	iosys_map_clear(map);
}

static int cam_mem_buf_mmap(struct dma_buf *dmabuf, struct vm_area_struct *vma)
{
	struct cam_mem_buffer *buffer = dmabuf->priv;
	struct sg_table *table = &buffer->sg_table;
	unsigned long addr = vma->vm_start;
	struct sg_page_iter piter;
	int ret;

	/*
	 * Match the userspace mapping attribute to the buffer's cache attribute
	 * (same rationale as cam_mem_buf_do_vmap): the camera SMMU is
	 * non-coherent, so uncached (no CAM_MEM_FLAG_CACHE) buffers must be
	 * mapped write-combine in userspace too, or camerad's CPU writes race
	 * the HW through the cache. Cached buffers keep the default prot and
	 * rely on explicit cam_mem_mgr_cache_op() maintenance.
	 */
	if (!(buffer->flags & CAM_MEM_FLAG_CACHE))
		vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);

	for_each_sgtable_page(table, &piter, vma->vm_pgoff) {
		struct page *page = sg_page_iter_page(&piter);

		ret = remap_pfn_range(vma, addr, page_to_pfn(page), PAGE_SIZE,
				vma->vm_page_prot);
		if (ret)
			return ret;
		addr += PAGE_SIZE;
		if (addr >= vma->vm_end)
			return 0;
	}

	return 0;
}

static void cam_mem_buf_release(struct dma_buf *dmabuf)
{
	struct cam_mem_buffer *buffer = dmabuf->priv;
	struct sg_table *table;
	struct scatterlist *sg;
	int i;

	table = &buffer->sg_table;
	for_each_sgtable_sg(table, sg, i)
		__free_pages(sg_page(sg), get_order(sg->length));
	sg_free_table(table);
	kfree(buffer);
}

static const struct dma_buf_ops cam_mem_mgr_buf_ops = {
	.attach = cam_mem_buf_attach,
	.detach = cam_mem_buf_detach,
	.map_dma_buf = cam_mem_buf_map,
	.unmap_dma_buf = cam_mem_buf_unmap,
	.release = cam_mem_buf_release,
	.mmap = cam_mem_buf_mmap,
	.vmap = cam_mem_buf_vmap,
	.vunmap = cam_mem_buf_vunmap,
};

static struct page *cam_mem_alloc_largest_available(unsigned long size,
	unsigned int max_order)
{
	struct page *page;
	unsigned int i;
	static const gfp_t gfp = GFP_KERNEL | __GFP_ZERO | __GFP_NOWARN | __GFP_COMP;

	for (i = 0; i < ARRAY_SIZE(cam_mem_orders); i++) {
		if (size < (PAGE_SIZE << cam_mem_orders[i]))
			continue;
		if (max_order < cam_mem_orders[i])
			continue;
		page = alloc_pages(gfp, cam_mem_orders[i]);
		if (!page)
			continue;
		return page;
	}
	return NULL;
}

/*
 * Allocate a page-backed buffer and export it as a dma_buf. Mainline
 * replacement for ion_alloc()/ion_share_dma_buf(). @flags carries the
 * CAM_MEM_FLAG_* intent. Uncached allocations are prepared before exposing
 * write-combine aliases; attachments use normal DMA API mapping.
 */
static struct dma_buf *cam_mem_util_buffer_alloc(size_t len, unsigned int flags)
{
	struct cam_mem_buffer *buffer;
	DEFINE_DMA_BUF_EXPORT_INFO(exp_info);
	unsigned long size_remaining = PAGE_ALIGN(len);
	unsigned int max_order = cam_mem_orders[0];
	struct dma_buf *dmabuf;
	struct scatterlist *sg;
	struct list_head pages;
	struct page *page, *tmp_page;
	struct sg_table *table;
	int ret = -ENOMEM;
	int i = 0;

	buffer = kzalloc(sizeof(*buffer), GFP_KERNEL);
	if (!buffer)
		return ERR_PTR(-ENOMEM);

	INIT_LIST_HEAD(&buffer->attachments);
	mutex_init(&buffer->lock);
	buffer->len = len;
	buffer->flags = flags;

	INIT_LIST_HEAD(&pages);
	while (size_remaining > 0) {
		page = cam_mem_alloc_largest_available(size_remaining,
				max_order);
		if (!page)
			goto free_buffer;

		list_add_tail(&page->lru, &pages);
		size_remaining -= page_size(page);
		max_order = compound_order(page);
		i++;
	}

	table = &buffer->sg_table;
	if (sg_alloc_table(table, i, GFP_KERNEL))
		goto free_buffer;

	sg = table->sgl;
	list_for_each_entry_safe(page, tmp_page, &pages, lru) {
		sg_set_page(sg, page, page_size(page), 0);
		sg = sg_next(sg);
		list_del(&page->lru);
	}

	if (!(flags & CAM_MEM_FLAG_CACHE)) {
		/* Complete cached page zeroing before exposing write-combine aliases. */
		ret = dma_map_sgtable(tbl.dev, table, DMA_TO_DEVICE, 0);
		if (ret)
			goto free_pages;
		dma_unmap_sgtable(tbl.dev, table, DMA_TO_DEVICE, 0);
	}

	exp_info.exp_name = "cam_mem_mgr";
	exp_info.ops = &cam_mem_mgr_buf_ops;
	/*
	 * Export the PAGE_ALIGNed size, not the raw len. The backing memory is
	 * already PAGE_ALIGN(len) (see size_remaining above), and the dma-buf
	 * core mmap bounds check is
	 *   vma->vm_pgoff + vma_pages(vma) > dmabuf->size >> PAGE_SHIFT
	 * vma_pages() rounds the userspace mmap length UP to whole pages, so an
	 * unaligned dmabuf->size truncates the RHS down and a full-length
	 * MAP_SHARED mmap (camerad alloc_w_mmu_hdl) fails -EINVAL -> MAP_FAILED.
	 */
	exp_info.size = PAGE_ALIGN(buffer->len);
	exp_info.flags = O_RDWR;
	exp_info.priv = buffer;

	dmabuf = dma_buf_export(&exp_info);
	if (IS_ERR(dmabuf)) {
		ret = PTR_ERR(dmabuf);
		goto free_pages;
	}

	return dmabuf;

free_pages:
	for_each_sgtable_sg(table, sg, i)
		__free_pages(sg_page(sg), get_order(sg->length));
	sg_free_table(table);
free_buffer:
	list_for_each_entry_safe(page, tmp_page, &pages, lru)
		__free_pages(page, compound_order(page));
	kfree(buffer);
	return ERR_PTR(ret);
}

static int cam_mem_util_map_cpu_va(struct dma_buf *dmabuf,
	struct iosys_map *map,
	uint64_t *vaddr,
	size_t *len)
{
	int rc;

	rc = dma_buf_vmap_unlocked(dmabuf, map);
	if (rc) {
		CAM_ERR(CAM_MEM, "kernel map fail rc=%d", rc);
		return -ENOSPC;
	}

	*vaddr = (uintptr_t)map->vaddr;
	*len = dmabuf->size;

	return 0;
}

static void cam_mem_util_unmap_cpu_va(struct dma_buf *dmabuf,
	struct iosys_map *map)
{
	if (map->vaddr)
		dma_buf_vunmap_unlocked(dmabuf, map);
	iosys_map_clear(map);
}

static int cam_mem_util_get_dma_dir(uint32_t flags)
{
	int rc = -EINVAL;

	if (flags & CAM_MEM_FLAG_HW_READ_ONLY)
		rc = DMA_TO_DEVICE;
	else if (flags & CAM_MEM_FLAG_HW_WRITE_ONLY)
		rc = DMA_FROM_DEVICE;
	else if (flags & CAM_MEM_FLAG_HW_READ_WRITE)
		rc = DMA_BIDIRECTIONAL;
	else if (flags & CAM_MEM_FLAG_PROTECTED_MODE)
		rc = DMA_BIDIRECTIONAL;

	return rc;
}

int cam_mem_mgr_init(struct device *dev)
{
	int i;
	int bitmap_size;

	memset(tbl.bufq, 0, sizeof(tbl.bufq));

	bitmap_size = BITS_TO_LONGS(CAM_MEM_BUFQ_MAX) * sizeof(long);
	tbl.bitmap = kzalloc(bitmap_size, GFP_KERNEL);
	if (!tbl.bitmap)
		return -ENOMEM;

	tbl.bits = bitmap_size * BITS_PER_BYTE;
	bitmap_zero(tbl.bitmap, tbl.bits);
	/* We need to reserve slot 0 because 0 is invalid */
	set_bit(0, tbl.bitmap);

	for (i = 1; i < CAM_MEM_BUFQ_MAX; i++) {
		tbl.bufq[i].fd = -1;
		tbl.bufq[i].buf_handle = -1;
	}
	mutex_init(&tbl.m_lock);
	tbl.dev = dev;
	atomic_set(&cam_mem_mgr_state, CAM_MEM_MGR_INITIALIZED);
	return 0;
}

static int32_t cam_mem_get_slot(void)
{
	int32_t idx;

	mutex_lock(&tbl.m_lock);
	idx = find_first_zero_bit(tbl.bitmap, tbl.bits);
	if (idx >= CAM_MEM_BUFQ_MAX || idx <= 0) {
		mutex_unlock(&tbl.m_lock);
		return -ENOMEM;
	}

	set_bit(idx, tbl.bitmap);
	tbl.bufq[idx].active = true;
	mutex_init(&tbl.bufq[idx].q_lock);
	mutex_unlock(&tbl.m_lock);

	return idx;
}

static void cam_mem_put_slot(int32_t idx)
{
	mutex_lock(&tbl.m_lock);
	mutex_lock(&tbl.bufq[idx].q_lock);
	tbl.bufq[idx].active = false;
	mutex_unlock(&tbl.bufq[idx].q_lock);
	mutex_destroy(&tbl.bufq[idx].q_lock);
	clear_bit(idx, tbl.bitmap);
	mutex_unlock(&tbl.m_lock);
}

int cam_mem_get_io_buf(int32_t buf_handle, int32_t mmu_handle,
	dma_addr_t *iova_ptr, size_t *len_ptr)
{
	int rc = 0, idx;

	if (!atomic_read(&cam_mem_mgr_state)) {
		CAM_ERR(CAM_CRM, "failed. mem_mgr not initialized");
		return -EINVAL;
	}

	idx = CAM_MEM_MGR_GET_HDL_IDX(buf_handle);
	if (idx >= CAM_MEM_BUFQ_MAX || idx <= 0) {
		CAM_ERR(CAM_MEM, "io buf %x invalid index %d", buf_handle, idx);
		return -EINVAL;
	}

	if (!tbl.bufq[idx].active) {
		CAM_ERR(CAM_MEM, "io buf %x inactive index %d", buf_handle, idx);
		return -EINVAL;
	}

	mutex_lock(&tbl.bufq[idx].q_lock);
	if (buf_handle != tbl.bufq[idx].buf_handle) {
		CAM_ERR(CAM_MEM, "io buf %x index %d holds %x",
			buf_handle, idx, tbl.bufq[idx].buf_handle);
		rc = -EINVAL;
		goto handle_mismatch;
	}

	if (CAM_MEM_MGR_IS_SECURE_HDL(buf_handle))
		rc = cam_smmu_get_stage2_iova(mmu_handle,
			tbl.bufq[idx].fd,
			iova_ptr,
			len_ptr);
	else
		rc = cam_smmu_get_iova(mmu_handle,
			tbl.bufq[idx].fd,
			iova_ptr,
			len_ptr);
	if (rc < 0)
		CAM_ERR(CAM_MEM, "fail to get buf hdl :%d", buf_handle);

handle_mismatch:
	mutex_unlock(&tbl.bufq[idx].q_lock);
	return rc;
}
EXPORT_SYMBOL(cam_mem_get_io_buf);

int cam_mem_get_cpu_buf(int32_t buf_handle, uint64_t *vaddr_ptr, size_t *len)
{
	int rc = 0;
	int idx;
	struct dma_buf *dmabuf = NULL;
	uint64_t kvaddr = 0;
	size_t klen = 0;

	if (!atomic_read(&cam_mem_mgr_state)) {
		CAM_ERR(CAM_CRM, "failed. mem_mgr not initialized");
		return -EINVAL;
	}
	if (!buf_handle || !vaddr_ptr || !len)
		return -EINVAL;

	idx = CAM_MEM_MGR_GET_HDL_IDX(buf_handle);
	if (idx >= CAM_MEM_BUFQ_MAX || idx <= 0)
		return -EINVAL;

	if (!tbl.bufq[idx].active)
		return -EPERM;

	mutex_lock(&tbl.bufq[idx].q_lock);
	if (buf_handle != tbl.bufq[idx].buf_handle) {
		rc = -EINVAL;
		goto exit_func;
	}

	dmabuf = tbl.bufq[idx].dma_buf;
	if (!dmabuf) {
		CAM_ERR(CAM_MEM, "Invalid DMA buffer pointer");
		rc = -EINVAL;
		goto exit_func;
	}

	if (tbl.bufq[idx].flags & CAM_MEM_FLAG_KMD_ACCESS) {
		if (!tbl.bufq[idx].kmdvaddr) {
			rc = cam_mem_util_map_cpu_va(dmabuf,
				&tbl.bufq[idx].kmap, &kvaddr, &klen);
			if (rc)
				goto exit_func;
			tbl.bufq[idx].kmdvaddr = kvaddr;
		}
	} else {
		rc = -EINVAL;
		goto exit_func;
	}

	*vaddr_ptr = tbl.bufq[idx].kmdvaddr;
	*len = tbl.bufq[idx].len;

exit_func:
	mutex_unlock(&tbl.bufq[idx].q_lock);
	return rc;
}
EXPORT_SYMBOL(cam_mem_get_cpu_buf);

int cam_mem_mgr_cache_ops(struct cam_mem_cache_ops_cmd *cmd)
{
	int rc = 0, idx;
	enum dma_data_direction dir;
	struct dma_buf *dmabuf;

	if (!atomic_read(&cam_mem_mgr_state)) {
		CAM_ERR(CAM_CRM, "failed. mem_mgr not initialized");
		return -EINVAL;
	}

	if (!cmd)
		return -EINVAL;

	idx = CAM_MEM_MGR_GET_HDL_IDX(cmd->buf_handle);
	if (idx >= CAM_MEM_BUFQ_MAX || idx <= 0)
		return -EINVAL;

	mutex_lock(&tbl.bufq[idx].q_lock);

	if (!tbl.bufq[idx].active) {
		rc = -EINVAL;
		goto fail;
	}

	if (cmd->buf_handle != tbl.bufq[idx].buf_handle) {
		rc = -EINVAL;
		goto fail;
	}

	dmabuf = tbl.bufq[idx].dma_buf;
	if (!dmabuf) {
		rc = -EINVAL;
		goto fail;
	}

	/*
	 * ION's msm_ion_do_cache_op / ION_IOC_*_CACHES became the generic
	 * dma_buf begin/end CPU access ops, which drive the exporter's cache
	 * maintenance. Map the legacy CLEAN/INV/CLEAN_INV intent onto a
	 * begin+end CPU-access cycle in the appropriate direction. Only meaningful
	 * for cached buffers; uncached buffers are a no-op (matches ION's
	 * ION_IS_CACHED gate).
	 */
	switch (cmd->mem_cache_ops) {
	case CAM_MEM_CLEAN_CACHE:
		dir = DMA_TO_DEVICE;
		break;
	case CAM_MEM_INV_CACHE:
		dir = DMA_FROM_DEVICE;
		break;
	case CAM_MEM_CLEAN_INV_CACHE:
		dir = DMA_BIDIRECTIONAL;
		break;
	default:
		CAM_ERR(CAM_MEM, "invalid cache ops :%d", cmd->mem_cache_ops);
		rc = -EINVAL;
		goto fail;
	}

	if (tbl.bufq[idx].flags & CAM_MEM_FLAG_CACHE) {
		rc = dma_buf_begin_cpu_access(dmabuf, dir);
		if (rc) {
			CAM_ERR(CAM_MEM, "begin cpu access failed %d", rc);
			goto fail;
		}
		rc = dma_buf_end_cpu_access(dmabuf, dir);
		if (rc)
			CAM_ERR(CAM_MEM, "end cpu access failed %d", rc);
	}
fail:
	mutex_unlock(&tbl.bufq[idx].q_lock);
	return rc;
}
EXPORT_SYMBOL(cam_mem_mgr_cache_ops);

static int cam_mem_util_get_dma_buf(size_t len,
	unsigned int flags,
	struct dma_buf **buf)
{
	if (!buf) {
		CAM_ERR(CAM_MEM, "Invalid params");
		return -EINVAL;
	}

	*buf = cam_mem_util_buffer_alloc(len, flags);
	if (IS_ERR_OR_NULL(*buf))
		return -ENOMEM;

	return 0;
}

static int cam_mem_util_get_dma_buf_fd(size_t len,
	unsigned int flags,
	struct dma_buf **buf,
	int *fd)
{
	int rc = 0;

	if (!buf || !fd) {
		CAM_ERR(CAM_MEM, "Invalid params");
		return -EINVAL;
	}

	*buf = cam_mem_util_buffer_alloc(len, flags);
	if (IS_ERR_OR_NULL(*buf))
		return -ENOMEM;

	/*
	 * dma_buf_export() returns one reference. dma_buf_fd() installs the fd
	 * which consumes that reference into the file. Take a second reference
	 * (get_dma_buf) so the dma_buf we store in the buffer-queue table stays
	 * valid independently of the fd, and is dropped via dma_buf_put() on
	 * release — this mirrors the legacy ion_alloc()+ion_share_dma_buf_fd()
	 * model where the handle and the shared fd were separate references.
	 */
	get_dma_buf(*buf);

	*fd = dma_buf_fd(*buf, O_CLOEXEC);
	if (*fd < 0) {
		CAM_ERR(CAM_MEM, "get fd fail");
		rc = -EINVAL;
		goto get_fd_fail;
	}

	return rc;

get_fd_fail:
	dma_buf_put(*buf);
	return rc;
}

static int cam_mem_util_ion_alloc(struct cam_mem_mgr_alloc_cmd *cmd,
	struct dma_buf **dmabuf,
	int *fd)
{
	int rc;

	rc = cam_mem_util_get_dma_buf_fd(cmd->len,
		cmd->flags,
		dmabuf,
		fd);

	return rc;
}


static int cam_mem_util_check_flags(struct cam_mem_mgr_alloc_cmd *cmd)
{
	if (!cmd->flags) {
		CAM_ERR(CAM_MEM, "Invalid flags");
		return -EINVAL;
	}

	if (cmd->num_hdl > CAM_MEM_MMU_MAX_HANDLE) {
		CAM_ERR(CAM_MEM, "Num of mmu hdl exceeded maximum(%d)",
			CAM_MEM_MMU_MAX_HANDLE);
		return -EINVAL;
	}

	if (cmd->flags & CAM_MEM_FLAG_PROTECTED_MODE &&
		cmd->flags & CAM_MEM_FLAG_KMD_ACCESS) {
		CAM_ERR(CAM_MEM, "Kernel mapping in secure mode not allowed");
		return -EINVAL;
	}

	return 0;
}

static int cam_mem_util_check_map_flags(struct cam_mem_mgr_map_cmd *cmd)
{
	if (!cmd->flags) {
		CAM_ERR(CAM_MEM, "Invalid flags");
		return -EINVAL;
	}

	if (cmd->num_hdl > CAM_MEM_MMU_MAX_HANDLE) {
		CAM_ERR(CAM_MEM, "Num of mmu hdl exceeded maximum(%d)",
			CAM_MEM_MMU_MAX_HANDLE);
		return -EINVAL;
	}

	if (cmd->flags & CAM_MEM_FLAG_PROTECTED_MODE &&
		cmd->flags & CAM_MEM_FLAG_KMD_ACCESS) {
		CAM_ERR(CAM_MEM, "Kernel mapping in secure mode not allowed");
		return -EINVAL;
	}

	if (cmd->flags & CAM_MEM_FLAG_HW_SHARED_ACCESS) {
		CAM_ERR(CAM_MEM,
			"Shared memory buffers are not allowed to be mapped");
		return -EINVAL;
	}

	return 0;
}

static int cam_mem_util_map_hw_va(uint32_t flags,
	int32_t *mmu_hdls,
	int32_t num_hdls,
	int fd,
	dma_addr_t *hw_vaddr,
	size_t *len,
	enum cam_smmu_region_id region)
{
	int i;
	int rc = -1;
	int dir = cam_mem_util_get_dma_dir(flags);

	if (dir < 0) {
		CAM_ERR(CAM_MEM, "fail to map DMA direction");
		return dir;
	}

	if (flags & CAM_MEM_FLAG_PROTECTED_MODE) {
		for (i = 0; i < num_hdls; i++) {
			rc = cam_smmu_map_stage2_iova(mmu_hdls[i],
				fd,
				dir,
				NULL,
				(ion_phys_addr_t *)hw_vaddr,
				len);

			if (rc < 0) {
				CAM_ERR(CAM_MEM,
					"Failed to securely map to smmu");
				goto multi_map_fail;
			}
		}
	} else {
		for (i = 0; i < num_hdls; i++) {
			rc = cam_smmu_map_user_iova(mmu_hdls[i],
				fd,
				dir,
				(dma_addr_t *)hw_vaddr,
				len,
				region);

			if (rc < 0) {
				CAM_ERR(CAM_MEM, "Failed to map to smmu");
				goto multi_map_fail;
			}
		}
	}

	return rc;
multi_map_fail:
	if (flags & CAM_MEM_FLAG_PROTECTED_MODE)
		for (--i; i > 0; i--)
			cam_smmu_unmap_stage2_iova(mmu_hdls[i], fd);
	else
		for (--i; i > 0; i--)
			cam_smmu_unmap_user_iova(mmu_hdls[i],
				fd,
				CAM_SMMU_REGION_IO);
	return rc;

}

int cam_mem_mgr_alloc_and_map(struct cam_mem_mgr_alloc_cmd *cmd)
{
	int rc;
	int32_t idx;
	struct dma_buf *dmabuf = NULL;
	int ion_fd = -1;
	dma_addr_t hw_vaddr = 0;
	size_t len;

	if (!atomic_read(&cam_mem_mgr_state)) {
		CAM_ERR(CAM_CRM, "failed. mem_mgr not initialized");
		return -EINVAL;
	}

	if (!cmd) {
		CAM_ERR(CAM_MEM, " Invalid argument");
		return -EINVAL;
	}
	len = cmd->len;

	rc = cam_mem_util_check_flags(cmd);
	if (rc) {
		CAM_ERR(CAM_MEM, "Invalid flags: flags = %X", cmd->flags);
		return rc;
	}

	rc = cam_mem_util_ion_alloc(cmd,
		&dmabuf,
		&ion_fd);
	if (rc) {
		CAM_ERR(CAM_MEM, "Buffer allocation failed");
		return rc;
	}

	idx = cam_mem_get_slot();
	if (idx < 0) {
		CAM_ERR(CAM_MEM, "Failed to get slot");
		rc = -ENOMEM;
		goto slot_fail;
	}

	if ((cmd->flags & CAM_MEM_FLAG_HW_READ_WRITE) ||
		(cmd->flags & CAM_MEM_FLAG_HW_SHARED_ACCESS) ||
		(cmd->flags & CAM_MEM_FLAG_PROTECTED_MODE)) {

		enum cam_smmu_region_id region;

		if (cmd->flags & CAM_MEM_FLAG_HW_READ_WRITE)
			region = CAM_SMMU_REGION_IO;


		if (cmd->flags & CAM_MEM_FLAG_HW_SHARED_ACCESS)
			region = CAM_SMMU_REGION_SHARED;

		rc = cam_mem_util_map_hw_va(cmd->flags,
			cmd->mmu_hdls,
			cmd->num_hdl,
			ion_fd,
			&hw_vaddr,
			&len,
			region);
		if (rc)
			goto map_hw_fail;
	}

	mutex_lock(&tbl.bufq[idx].q_lock);
	tbl.bufq[idx].fd = ion_fd;
	tbl.bufq[idx].dma_buf = dmabuf;
	tbl.bufq[idx].flags = cmd->flags;
	tbl.bufq[idx].buf_handle = GET_MEM_HANDLE(idx, ion_fd);
	if (cmd->flags & CAM_MEM_FLAG_PROTECTED_MODE)
		CAM_MEM_MGR_SET_SECURE_HDL(tbl.bufq[idx].buf_handle, true);
	tbl.bufq[idx].kmdvaddr = 0;

	if (cmd->num_hdl > 0)
		tbl.bufq[idx].vaddr = hw_vaddr;
	else
		tbl.bufq[idx].vaddr = 0;

	tbl.bufq[idx].len = cmd->len;
	tbl.bufq[idx].num_hdl = cmd->num_hdl;
	memcpy(tbl.bufq[idx].hdls, cmd->mmu_hdls,
		sizeof(int32_t) * cmd->num_hdl);
	tbl.bufq[idx].is_imported = false;
	mutex_unlock(&tbl.bufq[idx].q_lock);

	cmd->out.buf_handle = tbl.bufq[idx].buf_handle;
	cmd->out.fd = tbl.bufq[idx].fd;
	cmd->out.vaddr = 0;

	CAM_DBG(CAM_MEM, "buf handle: %x, fd: %d, len: %zu",
		cmd->out.buf_handle, cmd->out.fd,
		tbl.bufq[idx].len);

	return rc;

map_hw_fail:
	cam_mem_put_slot(idx);
slot_fail:
	dma_buf_put(dmabuf);
	return rc;
}

int cam_mem_mgr_map(struct cam_mem_mgr_map_cmd *cmd)
{
	int32_t idx;
	int rc;
	struct dma_buf *dmabuf;
	dma_addr_t hw_vaddr = 0;
	size_t len = 0;

	if (!atomic_read(&cam_mem_mgr_state)) {
		CAM_ERR(CAM_CRM, "failed. mem_mgr not initialized");
		return -EINVAL;
	}

	if (!cmd || (cmd->fd < 0)) {
		CAM_ERR(CAM_MEM, "Invalid argument");
		return -EINVAL;
	}

	if (cmd->num_hdl > CAM_MEM_MMU_MAX_HANDLE)
		return -EINVAL;

	rc = cam_mem_util_check_map_flags(cmd);
	if (rc) {
		CAM_ERR(CAM_MEM, "Invalid flags: flags = %X", cmd->flags);
		return rc;
	}

	dmabuf = dma_buf_get(cmd->fd);
	if (IS_ERR_OR_NULL((void *)(dmabuf))) {
		CAM_ERR(CAM_MEM, "Failed to import dma buf fd");
		return -EINVAL;
	}

	if ((cmd->flags & CAM_MEM_FLAG_HW_READ_WRITE) ||
		(cmd->flags & CAM_MEM_FLAG_PROTECTED_MODE)) {
		rc = cam_mem_util_map_hw_va(cmd->flags,
			cmd->mmu_hdls,
			cmd->num_hdl,
			cmd->fd,
			&hw_vaddr,
			&len,
			CAM_SMMU_REGION_IO);
		if (rc)
			goto map_fail;
	} else {
		len = dmabuf->size;
	}

	idx = cam_mem_get_slot();
	if (idx < 0) {
		rc = -ENOMEM;
		goto map_fail;
	}

	mutex_lock(&tbl.bufq[idx].q_lock);
	tbl.bufq[idx].fd = cmd->fd;
	tbl.bufq[idx].dma_buf = dmabuf;
	tbl.bufq[idx].flags = cmd->flags;
	tbl.bufq[idx].buf_handle = GET_MEM_HANDLE(idx, cmd->fd);
	if (cmd->flags & CAM_MEM_FLAG_PROTECTED_MODE)
		CAM_MEM_MGR_SET_SECURE_HDL(tbl.bufq[idx].buf_handle, true);
	tbl.bufq[idx].kmdvaddr = 0;

	if (cmd->num_hdl > 0)
		tbl.bufq[idx].vaddr = hw_vaddr;
	else
		tbl.bufq[idx].vaddr = 0;

	tbl.bufq[idx].len = len;
	tbl.bufq[idx].num_hdl = cmd->num_hdl;
	memcpy(tbl.bufq[idx].hdls, cmd->mmu_hdls,
		sizeof(int32_t) * cmd->num_hdl);
	tbl.bufq[idx].is_imported = true;
	mutex_unlock(&tbl.bufq[idx].q_lock);

	cmd->out.buf_handle = tbl.bufq[idx].buf_handle;
	cmd->out.vaddr = 0;

	return rc;

map_fail:
	dma_buf_put(dmabuf);
	return rc;
}

static int cam_mem_util_unmap_hw_va(int32_t idx,
	enum cam_smmu_region_id region,
	enum cam_smmu_mapping_client client)
{
	int i;
	uint32_t flags;
	int32_t *mmu_hdls;
	int num_hdls;
	int fd;
	int rc = -EINVAL;

	if (idx >= CAM_MEM_BUFQ_MAX || idx <= 0) {
		CAM_ERR(CAM_MEM, "Incorrect index");
		return rc;
	}

	flags = tbl.bufq[idx].flags;
	mmu_hdls = tbl.bufq[idx].hdls;
	num_hdls = tbl.bufq[idx].num_hdl;
	fd = tbl.bufq[idx].fd;

	if (flags & CAM_MEM_FLAG_PROTECTED_MODE) {
		for (i = 0; i < num_hdls; i++) {
			rc = cam_smmu_unmap_stage2_iova(mmu_hdls[i], fd);
			if (rc < 0)
				goto unmap_end;
		}
	} else {
		for (i = 0; i < num_hdls; i++) {
			if (client == CAM_SMMU_MAPPING_USER) {
			rc = cam_smmu_unmap_user_iova(mmu_hdls[i],
				fd, region);
			} else if (client == CAM_SMMU_MAPPING_KERNEL) {
				rc = cam_smmu_unmap_kernel_iova(mmu_hdls[i],
					tbl.bufq[idx].dma_buf, region);
			} else {
				CAM_ERR(CAM_MEM,
					"invalid caller for unmapping : %d",
					client);
				rc = -EINVAL;
			}
			if (rc < 0)
				goto unmap_end;
		}
	}

	return rc;

unmap_end:
	CAM_ERR(CAM_MEM, "unmapping failed");
	return rc;
}

static void cam_mem_mgr_unmap_active_buf(int idx)
{
	enum cam_smmu_region_id region = CAM_SMMU_REGION_SHARED;

	/*
	 * Balance the lazy kernel vmap taken by cam_mem_get_cpu_buf() for
	 * KMD_ACCESS buffers. The leaked-buffer cleanup path drops the dma_buf
	 * ref directly (it does not route through cam_mem_util_unmap()), so the
	 * vunmap must happen here or the exporter's vmapping_counter is still
	 * non-zero when the buffer's last ref is dropped -> dma_buf_release()
	 * BUG_ON(dmabuf->vmapping_counter). Mirrors cam_mem_util_unmap().
	 */
	if (tbl.bufq[idx].dma_buf && tbl.bufq[idx].kmdvaddr)
		cam_mem_util_unmap_cpu_va(tbl.bufq[idx].dma_buf,
			&tbl.bufq[idx].kmap);

	if (tbl.bufq[idx].flags & CAM_MEM_FLAG_HW_SHARED_ACCESS)
		region = CAM_SMMU_REGION_SHARED;
	else if (tbl.bufq[idx].flags & CAM_MEM_FLAG_HW_READ_WRITE)
		region = CAM_SMMU_REGION_IO;

	cam_mem_util_unmap_hw_va(idx, region, CAM_SMMU_MAPPING_USER);
}

static int cam_mem_mgr_cleanup_table(void)
{
	int i;

	mutex_lock(&tbl.m_lock);
	for (i = 1; i < CAM_MEM_BUFQ_MAX; i++) {
		if (!tbl.bufq[i].active) {
			CAM_DBG(CAM_MEM,
				"Buffer inactive at idx=%d, continuing", i);
			continue;
		} else {
			CAM_DBG(CAM_MEM,
			"Active buffer at idx=%d, possible leak needs unmapping",
			i);
			cam_mem_mgr_unmap_active_buf(i);
		}

		mutex_lock(&tbl.bufq[i].q_lock);
		if (tbl.bufq[i].dma_buf) {
			dma_buf_put(tbl.bufq[i].dma_buf);
			tbl.bufq[i].dma_buf = NULL;
		}
		tbl.bufq[i].fd = -1;
		tbl.bufq[i].flags = 0;
		tbl.bufq[i].buf_handle = -1;
		tbl.bufq[i].vaddr = 0;
		tbl.bufq[i].len = 0;
		memset(tbl.bufq[i].hdls, 0,
			sizeof(int32_t) * tbl.bufq[i].num_hdl);
		tbl.bufq[i].num_hdl = 0;
		tbl.bufq[i].dma_buf = NULL;
		tbl.bufq[i].active = false;
		mutex_unlock(&tbl.bufq[i].q_lock);
		mutex_destroy(&tbl.bufq[i].q_lock);
	}
	bitmap_zero(tbl.bitmap, tbl.bits);
	/* We need to reserve slot 0 because 0 is invalid */
	set_bit(0, tbl.bitmap);
	mutex_unlock(&tbl.m_lock);

	return 0;
}

void cam_mem_mgr_deinit(void)
{
	atomic_set(&cam_mem_mgr_state, CAM_MEM_MGR_UNINITIALIZED);
	cam_mem_mgr_cleanup_table();
	mutex_lock(&tbl.m_lock);
	bitmap_zero(tbl.bitmap, tbl.bits);
	kfree(tbl.bitmap);
	tbl.bitmap = NULL;
	tbl.dev = NULL;
	mutex_unlock(&tbl.m_lock);
	mutex_destroy(&tbl.m_lock);
}

static int cam_mem_util_unmap(int32_t idx,
	enum cam_smmu_mapping_client client)
{
	int rc = 0;
	enum cam_smmu_region_id region = CAM_SMMU_REGION_SHARED;

	if (idx >= CAM_MEM_BUFQ_MAX || idx <= 0) {
		CAM_ERR(CAM_MEM, "Incorrect index");
		return -EINVAL;
	}

	CAM_DBG(CAM_MEM, "Flags = %X idx %d", tbl.bufq[idx].flags, idx);

	mutex_lock(&tbl.m_lock);
	if ((!tbl.bufq[idx].active) &&
		(tbl.bufq[idx].vaddr) == 0) {
		CAM_WARN(CAM_MEM, "Buffer at idx=%d is already unmapped,",
			idx);
		mutex_unlock(&tbl.m_lock);
		return 0;
	}


	/*
	 * Balance any kernel vmap. NOT gated on CAM_MEM_FLAG_KMD_ACCESS:
	 * cam_mem_mgr_request_mem() vmaps the buffer UNCONDITIONALLY (its
	 * callers, e.g. the ICP HFI qtbl/cmd_q/msg_q allocs, request
	 * HW_SHARED_ACCESS without KMD_ACCESS), while cam_mem_get_cpu_buf()
	 * vmaps lazily for KMD_ACCESS. Either way kmdvaddr is set, so key the
	 * vunmap on kmdvaddr, not the flag — otherwise the exporter's
	 * vmapping_counter is still non-zero at dma_buf_release() ->
	 * BUG_ON(dmabuf->vmapping_counter) (hit on cam_icp_free_hfi_mem).
	 */
	if (tbl.bufq[idx].dma_buf && tbl.bufq[idx].kmdvaddr)
		cam_mem_util_unmap_cpu_va(tbl.bufq[idx].dma_buf,
			&tbl.bufq[idx].kmap);

	/* SHARED flag gets precedence, all other flags after it */
	if (tbl.bufq[idx].flags & CAM_MEM_FLAG_HW_SHARED_ACCESS) {
		region = CAM_SMMU_REGION_SHARED;
	} else {
		if (tbl.bufq[idx].flags & CAM_MEM_FLAG_HW_READ_WRITE)
			region = CAM_SMMU_REGION_IO;
	}

	if ((tbl.bufq[idx].flags & CAM_MEM_FLAG_HW_READ_WRITE) ||
		(tbl.bufq[idx].flags & CAM_MEM_FLAG_HW_SHARED_ACCESS) ||
		(tbl.bufq[idx].flags & CAM_MEM_FLAG_PROTECTED_MODE))
		rc = cam_mem_util_unmap_hw_va(idx, region, client);


	mutex_lock(&tbl.bufq[idx].q_lock);
	tbl.bufq[idx].flags = 0;
	tbl.bufq[idx].buf_handle = -1;
	tbl.bufq[idx].vaddr = 0;
	tbl.bufq[idx].kmdvaddr = 0;
	memset(tbl.bufq[idx].hdls, 0,
		sizeof(int32_t) * CAM_MEM_MMU_MAX_HANDLE);

	CAM_DBG(CAM_MEM,
		"Buffer at idx = %d freeing dma_buf %pK, fd = %d, imported %d",
		idx, tbl.bufq[idx].dma_buf, tbl.bufq[idx].fd,
		tbl.bufq[idx].is_imported);

	if (tbl.bufq[idx].dma_buf) {
		dma_buf_put(tbl.bufq[idx].dma_buf);
		tbl.bufq[idx].dma_buf = NULL;
	}

	tbl.bufq[idx].fd = -1;
	tbl.bufq[idx].is_imported = false;
	tbl.bufq[idx].len = 0;
	tbl.bufq[idx].num_hdl = 0;
	tbl.bufq[idx].active = false;
	mutex_unlock(&tbl.bufq[idx].q_lock);
	mutex_destroy(&tbl.bufq[idx].q_lock);
	clear_bit(idx, tbl.bitmap);
	mutex_unlock(&tbl.m_lock);

	return rc;
}

int cam_mem_mgr_release(struct cam_mem_mgr_release_cmd *cmd)
{
	int idx;
	int rc;

	if (!atomic_read(&cam_mem_mgr_state)) {
		CAM_ERR(CAM_CRM, "failed. mem_mgr not initialized");
		return -EINVAL;
	}

	if (!cmd) {
		CAM_ERR(CAM_MEM, "Invalid argument");
		return -EINVAL;
	}

	idx = CAM_MEM_MGR_GET_HDL_IDX(cmd->buf_handle);
	if (idx >= CAM_MEM_BUFQ_MAX || idx <= 0) {
		CAM_ERR(CAM_MEM, "Incorrect index extracted from mem handle");
		return -EINVAL;
	}

	if (!tbl.bufq[idx].active) {
		CAM_ERR(CAM_MEM, "Released buffer state should be active");
		return -EINVAL;
	}

	if (tbl.bufq[idx].buf_handle != cmd->buf_handle) {
		CAM_ERR(CAM_MEM,
			"Released buf handle not matching within table");
		return -EINVAL;
	}

	CAM_DBG(CAM_MEM, "Releasing hdl = %u", cmd->buf_handle);
	rc = cam_mem_util_unmap(idx, CAM_SMMU_MAPPING_USER);

	return rc;
}

int cam_mem_mgr_request_mem(struct cam_mem_mgr_request_desc *inp,
	struct cam_mem_mgr_memory_desc *out)
{
	struct dma_buf *buf = NULL;
	int ion_fd = -1;
	int rc = 0;
	uint64_t kvaddr;
	dma_addr_t iova = 0;
	size_t request_len = 0;
	uint32_t mem_handle;
	int32_t idx;
	int32_t smmu_hdl = 0;
	int32_t num_hdl = 0;
	struct iosys_map kmap = {0};

	enum cam_smmu_region_id region = CAM_SMMU_REGION_SHARED;

	if (!atomic_read(&cam_mem_mgr_state)) {
		CAM_ERR(CAM_CRM, "failed. mem_mgr not initialized");
		return -EINVAL;
	}

	if (!inp || !out) {
		CAM_ERR(CAM_MEM, "Invalid params");
		return -EINVAL;
	}

	if (!(inp->flags & CAM_MEM_FLAG_HW_READ_WRITE ||
		inp->flags & CAM_MEM_FLAG_HW_SHARED_ACCESS ||
		inp->flags & CAM_MEM_FLAG_CACHE)) {
		CAM_ERR(CAM_MEM, "Invalid flags for request mem");
		return -EINVAL;
	}

	rc = cam_mem_util_get_dma_buf(inp->size,
		inp->flags,
		&buf);

	if (rc) {
		CAM_ERR(CAM_MEM, "Buffer alloc failed for shared buffer");
		goto ion_fail;
	} else {
		CAM_DBG(CAM_MEM, "Got dma_buf = %pK", buf);
	}

	rc = cam_mem_util_map_cpu_va(buf, &kmap, &kvaddr, &request_len);
	if (rc) {
		CAM_ERR(CAM_MEM, "Failed to get kernel vaddr");
		goto map_fail;
	}

	if (!inp->smmu_hdl) {
		CAM_ERR(CAM_MEM, "Invalid SMMU handle");
		rc = -EINVAL;
		goto smmu_fail;
	}

	/* SHARED flag gets precedence, all other flags after it */
	if (inp->flags & CAM_MEM_FLAG_HW_SHARED_ACCESS) {
		region = CAM_SMMU_REGION_SHARED;
	} else {
		if (inp->flags & CAM_MEM_FLAG_HW_READ_WRITE)
			region = CAM_SMMU_REGION_IO;
	}

	rc = cam_smmu_map_kernel_iova(inp->smmu_hdl,
		buf,
		CAM_SMMU_MAP_RW,
		&iova,
		&request_len,
		region);

	if (rc < 0) {
		CAM_ERR(CAM_MEM, "SMMU mapping failed");
		goto smmu_fail;
	}

	smmu_hdl = inp->smmu_hdl;
	num_hdl = 1;

	idx = cam_mem_get_slot();
	if (idx < 0) {
		rc = -ENOMEM;
		goto slot_fail;
	}

	mutex_lock(&tbl.bufq[idx].q_lock);
	mem_handle = GET_MEM_HANDLE(idx, ion_fd);
	tbl.bufq[idx].dma_buf = buf;
	tbl.bufq[idx].fd = -1;
	tbl.bufq[idx].flags = inp->flags;
	tbl.bufq[idx].buf_handle = mem_handle;
	tbl.bufq[idx].kmdvaddr = kvaddr;
	tbl.bufq[idx].kmap = kmap;

	tbl.bufq[idx].vaddr = iova;

	tbl.bufq[idx].len = inp->size;
	tbl.bufq[idx].num_hdl = num_hdl;
	memcpy(tbl.bufq[idx].hdls, &smmu_hdl,
		sizeof(int32_t));
	tbl.bufq[idx].is_imported = false;
	mutex_unlock(&tbl.bufq[idx].q_lock);

	out->kva = kvaddr;
	out->iova = (uint32_t)iova;
	out->smmu_hdl = smmu_hdl;
	out->mem_handle = mem_handle;
	out->len = inp->size;
	out->region = region;

	return rc;
slot_fail:
	cam_smmu_unmap_kernel_iova(inp->smmu_hdl,
	buf, region);
smmu_fail:
	cam_mem_util_unmap_cpu_va(buf, &kmap);
map_fail:
	dma_buf_put(buf);
ion_fail:
	return rc;
}
EXPORT_SYMBOL(cam_mem_mgr_request_mem);

int cam_mem_mgr_release_mem(struct cam_mem_mgr_memory_desc *inp)
{
	int32_t idx;
	int rc;

	if (!atomic_read(&cam_mem_mgr_state)) {
		CAM_ERR(CAM_CRM, "failed. mem_mgr not initialized");
		return -EINVAL;
	}

	if (!inp) {
		CAM_ERR(CAM_MEM, "Invalid argument");
		return -EINVAL;
	}

	idx = CAM_MEM_MGR_GET_HDL_IDX(inp->mem_handle);
	if (idx >= CAM_MEM_BUFQ_MAX || idx <= 0) {
		CAM_ERR(CAM_MEM, "Incorrect index extracted from mem handle");
		return -EINVAL;
	}

	if (!tbl.bufq[idx].active) {
		if (tbl.bufq[idx].vaddr == 0) {
			CAM_ERR(CAM_MEM, "buffer is released already");
			return 0;
		}
		CAM_ERR(CAM_MEM, "Released buffer state should be active");
		return -EINVAL;
	}

	if (tbl.bufq[idx].buf_handle != inp->mem_handle) {
		CAM_ERR(CAM_MEM,
			"Released buf handle not matching within table");
		return -EINVAL;
	}

	CAM_DBG(CAM_MEM, "Releasing hdl = %X", inp->mem_handle);
	rc = cam_mem_util_unmap(idx, CAM_SMMU_MAPPING_KERNEL);

	return rc;
}
EXPORT_SYMBOL(cam_mem_mgr_release_mem);

int cam_mem_mgr_reserve_memory_region(struct cam_mem_mgr_request_desc *inp,
	enum cam_smmu_region_id region,
	struct cam_mem_mgr_memory_desc *out)
{
	struct dma_buf *buf = NULL;
	int rc = 0;
	int ion_fd = -1;
	dma_addr_t iova = 0;
	size_t request_len = 0;
	uint32_t mem_handle;
	int32_t idx;
	int32_t smmu_hdl = 0;
	int32_t num_hdl = 0;

	if (!atomic_read(&cam_mem_mgr_state)) {
		CAM_ERR(CAM_CRM, "failed. mem_mgr not initialized");
		return -EINVAL;
	}

	if (!inp || !out) {
		CAM_ERR(CAM_MEM, "Invalid param(s)");
		return -EINVAL;
	}

	if (!inp->smmu_hdl) {
		CAM_ERR(CAM_MEM, "Invalid SMMU handle");
		return -EINVAL;
	}

	if (region != CAM_SMMU_REGION_SECHEAP) {
		CAM_ERR(CAM_MEM, "Only secondary heap supported");
		return -EINVAL;
	}

	rc = cam_mem_util_get_dma_buf(inp->size,
		0,
		&buf);

	if (rc) {
		CAM_ERR(CAM_MEM, "Buffer alloc failed for sec heap buffer");
		goto ion_fail;
	} else {
		CAM_DBG(CAM_MEM, "Got dma_buf = %pK", buf);
	}

	rc = cam_smmu_reserve_sec_heap(inp->smmu_hdl,
		buf,
		&iova,
		&request_len);

	if (rc) {
		CAM_ERR(CAM_MEM, "Reserving secondary heap failed");
		goto smmu_fail;
	}

	smmu_hdl = inp->smmu_hdl;
	num_hdl = 1;

	idx = cam_mem_get_slot();
	if (idx < 0) {
		rc = -ENOMEM;
		goto slot_fail;
	}

	mutex_lock(&tbl.bufq[idx].q_lock);
	mem_handle = GET_MEM_HANDLE(idx, ion_fd);
	tbl.bufq[idx].fd = -1;
	tbl.bufq[idx].dma_buf = buf;
	tbl.bufq[idx].flags = inp->flags;
	tbl.bufq[idx].buf_handle = mem_handle;
	tbl.bufq[idx].kmdvaddr = 0;

	tbl.bufq[idx].vaddr = iova;

	tbl.bufq[idx].len = request_len;
	tbl.bufq[idx].num_hdl = num_hdl;
	memcpy(tbl.bufq[idx].hdls, &smmu_hdl,
		sizeof(int32_t));
	tbl.bufq[idx].is_imported = false;
	mutex_unlock(&tbl.bufq[idx].q_lock);

	out->kva = 0;
	out->iova = (uint32_t)iova;
	out->smmu_hdl = smmu_hdl;
	out->mem_handle = mem_handle;
	out->len = request_len;
	out->region = region;

	return rc;

slot_fail:
	cam_smmu_release_sec_heap(smmu_hdl);
smmu_fail:
	dma_buf_put(buf);
ion_fail:
	return rc;
}
EXPORT_SYMBOL(cam_mem_mgr_reserve_memory_region);

int cam_mem_mgr_free_memory_region(struct cam_mem_mgr_memory_desc *inp)
{
	int32_t idx;
	int rc;
	int32_t smmu_hdl;

	if (!atomic_read(&cam_mem_mgr_state)) {
		CAM_ERR(CAM_CRM, "failed. mem_mgr not initialized");
		return -EINVAL;
	}

	if (!inp) {
		CAM_ERR(CAM_MEM, "Invalid argument");
		return -EINVAL;
	}

	if (inp->region != CAM_SMMU_REGION_SECHEAP) {
		CAM_ERR(CAM_MEM, "Only secondary heap supported");
		return -EINVAL;
	}

	idx = CAM_MEM_MGR_GET_HDL_IDX(inp->mem_handle);
	if (idx >= CAM_MEM_BUFQ_MAX || idx <= 0) {
		CAM_ERR(CAM_MEM, "Incorrect index extracted from mem handle");
		return -EINVAL;
	}

	if (!tbl.bufq[idx].active) {
		if (tbl.bufq[idx].vaddr == 0) {
			CAM_ERR(CAM_MEM, "buffer is released already");
			return 0;
		}
		CAM_ERR(CAM_MEM, "Released buffer state should be active");
		return -EINVAL;
	}

	if (tbl.bufq[idx].buf_handle != inp->mem_handle) {
		CAM_ERR(CAM_MEM,
			"Released buf handle not matching within table");
		return -EINVAL;
	}

	if (tbl.bufq[idx].num_hdl != 1) {
		CAM_ERR(CAM_MEM,
			"Sec heap region should have only one smmu hdl");
		return -ENODEV;
	}

	memcpy(&smmu_hdl, tbl.bufq[idx].hdls,
		sizeof(int32_t));
	if (inp->smmu_hdl != smmu_hdl) {
		CAM_ERR(CAM_MEM,
			"Passed SMMU handle doesn't match with internal hdl");
		return -ENODEV;
	}

	rc = cam_smmu_release_sec_heap(inp->smmu_hdl);
	if (rc) {
		CAM_ERR(CAM_MEM,
			"Sec heap region release failed");
		return -ENODEV;
	}

	CAM_DBG(CAM_MEM, "Releasing hdl = %X", inp->mem_handle);
	rc = cam_mem_util_unmap(idx, CAM_SMMU_MAPPING_KERNEL);
	if (rc)
		CAM_ERR(CAM_MEM, "unmapping secondary heap failed");

	return rc;
}
EXPORT_SYMBOL(cam_mem_mgr_free_memory_region);
