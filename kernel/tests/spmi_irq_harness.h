/* SPDX-License-Identifier: GPL-2.0-only */
/* Fake MMIO/IRQ boundary for executing extracted, unmodified driver functions. */
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
#define __iomem
#define BIT(n) (1U << (n))
#define GENMASK(h,l) ((UINT32_MAX >> (31 - (h))) & (UINT32_MAX << (l)))
#define FIELD_PREP(mask,val) (((unsigned long)(val) << __builtin_ctz(mask)) & (mask))
#define FIELD_GET(mask,val) (((unsigned long)(val) & (mask)) >> __builtin_ctz(mask))
#define FIELD_MAX(mask) ((mask) >> __builtin_ctz(mask))
#define HWIRQ_SID_MASK GENMASK(28,24)
#define HWIRQ_PID_MASK GENMASK(23,16)
#define HWIRQ_IRQID_MASK GENMASK(15,13)
#define HWIRQ_APID_MASK GENMASK(12,0)
#define spec_to_hwirq(s,p,i,a) (FIELD_PREP(HWIRQ_SID_MASK,s) | FIELD_PREP(HWIRQ_PID_MASK,p) | FIELD_PREP(HWIRQ_IRQID_MASK,i) | FIELD_PREP(HWIRQ_APID_MASK,a))
#define PMIC_ARB_MAX_PPID BIT(13)
#define PMIC_ARB_APID_VALID BIT(15)
#define PMIC_ARB_PPID_MASK GENMASK(11,0)
#define PMIC_ARB_CHAN_IS_IRQ_OWNER_MASK BIT(24)
#define INVALID_EE 0xff
#define SPMI_OWNERSHIP_PERIPH2OWNER(x) ((x) & 7)
#define SPMI_PIC_ACC_ENABLE_BIT BIT(0)
#define IRQ_TYPE_SENSE_MASK 0xf
#define MAX_APIDS 8192

struct spmi_pmic_arb_bus;
struct apid_data { u16 ppid; u8 write_ee, irq_ee; };
struct pmic_arb_ver_ops {
 void *(*owner_acc_status)(struct spmi_pmic_arb_bus *, u8, int);
 void *(*acc_enable)(struct spmi_pmic_arb_bus *, u16);
 void *(*irq_status)(struct spmi_pmic_arb_bus *, u16);
 void *(*irq_clear)(struct spmi_pmic_arb_bus *, u16);
 u32 (*apid_map_offset)(u16);
 void *(*apid_owner)(struct spmi_pmic_arb_bus *, u16);
 int (*ppid_to_apid)(struct spmi_pmic_arb_bus *, u16);
};
struct spmi_pmic_arb {
 void *core;
 size_t core_size;
 u8 ee;
 int max_periphs;
 const struct pmic_arb_ver_ops *ver_ops;
};
struct fake_dev { void *of_node; };
struct spmi_controller { struct fake_dev dev; };
struct irq_domain { void *host_data; void *node; };
struct spmi_pmic_arb_bus {
 struct spmi_pmic_arb *pmic_arb;
 struct irq_domain *domain;
 struct spmi_controller *spmic;
 u16 base_apid;
 int apid_count;
 u16 *ppid_to_apid;
 u16 last_apid;
 struct apid_data *apid_data;
 u16 min_apid, max_apid;
};
struct irq_chip { int unused; };
struct irq_desc { struct spmi_pmic_arb_bus *bus; struct irq_chip chip; };
struct irq_fwspec { int param_count; u32 param[4]; };

static struct spmi_pmic_arb arb;
static struct spmi_pmic_arb_bus bus;
static struct spmi_controller controller;
static struct irq_domain domain;
static struct irq_desc desc;
static struct apid_data apids[MAX_APIDS];
static u16 ppids[PMIC_ARB_MAX_PPID];
static u32 core[MAX_APIDS], owners[MAX_APIDS];
static u32 acc[MAX_APIDS], pic_status[MAX_APIDS], clear[MAX_APIDS];
static u32 owner_status[MAX_APIDS / 32];
static unsigned int mappings[MAX_APIDS][8];
static unsigned int pic_reads[MAX_APIDS], pic_writes[MAX_APIDS];
static int summary_reads[MAX_APIDS / 32], summary_count;
static unsigned int warnings, handled, bad_irqs;
static u8 pmic_enable, pmic_latched;

static void log_discard(const void *dev, const char *fmt, ...) { (void)dev; (void)fmt; }
#define dev_dbg log_discard
#define dev_err log_discard
#define dev_err_ratelimited log_discard
#define WARN_ONCE(cond,...) do { if (cond) warnings++; } while (0)
#define irq_desc_get_handler_data(d) ((d)->bus)
#define irq_desc_get_chip(d) (&(d)->chip)
#define chained_irq_enter(c,d) do { (void)(c); (void)(d); } while (0)
#define chained_irq_exit(c,d) do { (void)(c); (void)(d); } while (0)
#define irq_domain_get_of_node(d) ((d)->node)
static void handle_bad_irq(struct irq_desc *d) { (void)d; bad_irqs++; }
static void generic_handle_irq(unsigned int irq) { if (!irq) abort(); handled++; }
static unsigned int irq_find_mapping(struct irq_domain *d, unsigned long hw)
{
 (void)d;
 return mappings[FIELD_GET(HWIRQ_APID_MASK,hw)][FIELD_GET(HWIRQ_IRQID_MASK,hw)];
}

static int index_in(const void *p, const u32 *a, size_t n)
{
 uintptr_t x = (uintptr_t)p, lo = (uintptr_t)a;
 return x >= lo && x < lo + n * sizeof(*a) ? (int)((x - lo) / sizeof(*a)) : -1;
}
static u32 readl_relaxed(const void *p)
{
 int i;
 if ((i = index_in(p, acc, MAX_APIDS)) >= 0 ||
     (i = index_in(p, pic_status, MAX_APIDS)) >= 0) pic_reads[i]++;
 return *(const u32 *)p;
}
static void writel_relaxed(u32 value, void *p)
{
 int i = index_in(p, clear, MAX_APIDS);
 if (i < 0) { fprintf(stderr, "unexpected MMIO write\n"); abort(); }
 pic_writes[i]++;
 clear[i] |= value;
 pic_status[i] &= ~value;
 if (!pic_status[i]) {
  unsigned int relative_bucket = (i >> 5) - (bus.base_apid >> 5);
  owner_status[relative_bucket] &= ~BIT(i & 31);
 }
}
static void *fake_owner_status(struct spmi_pmic_arb_bus *b, u8 ee, int bucket)
{
 if (b != &bus || ee != arb.ee || bucket < 0 || bucket >= MAX_APIDS / 32) abort();
 summary_reads[summary_count++] = bucket;
 return &owner_status[bucket];
}
static void *fake_acc(struct spmi_pmic_arb_bus *b, u16 a) { (void)b; return &acc[a]; }
static void *fake_status(struct spmi_pmic_arb_bus *b, u16 a) { (void)b; return &pic_status[a]; }
static void *fake_clear(struct spmi_pmic_arb_bus *b, u16 a) { (void)b; return &clear[a]; }
static void *fake_owner(struct spmi_pmic_arb_bus *b, u16 a) { (void)b; return &owners[a]; }
static u32 fake_map_offset(u16 a) { return sizeof(u32) * a; }
static int fake_ppid_to_apid(struct spmi_pmic_arb_bus *b, u16 p)
{
 return b->ppid_to_apid[p] & PMIC_ARB_APID_VALID ? (int)(b->ppid_to_apid[p] & ~PMIC_ARB_APID_VALID) : -ENODEV;
}
static const struct pmic_arb_ver_ops ops = {
 .owner_acc_status = fake_owner_status, .acc_enable = fake_acc,
 .irq_status = fake_status, .irq_clear = fake_clear,
 .apid_map_offset = fake_map_offset, .apid_owner = fake_owner,
 .ppid_to_apid = fake_ppid_to_apid,
};
