/* SPDX-License-Identifier: GPL-2.0-only */
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "%s:%d: %s\n", __func__, __LINE__, #x); return 1; } } while (0)

static void setup(unsigned int base, unsigned int count, u8 ee)
{
 memset(&arb, 0, sizeof(arb)); memset(&bus, 0, sizeof(bus));
 memset(apids, 0, sizeof(apids)); memset(ppids, 0, sizeof(ppids));
 memset(core, 0, sizeof(core)); memset(owners, 0, sizeof(owners));
 memset(acc, 0, sizeof(acc)); memset(pic_status, 0, sizeof(pic_status));
 memset(clear, 0, sizeof(clear)); memset(owner_status, 0, sizeof(owner_status));
 memset(mappings, 0, sizeof(mappings)); memset(pic_reads, 0, sizeof(pic_reads));
 memset(pic_writes, 0, sizeof(pic_writes)); memset(summary_reads, 0, sizeof(summary_reads));
 warnings = handled = bad_irqs = summary_count = 0;
 pmic_enable = pmic_latched = 0x90; /* IRQ4 legacy plugin + IRQ7 active Type-C. */
 arb.core = core; arb.core_size = sizeof(core); arb.ee = ee;
 arb.max_periphs = MAX_APIDS; arb.ver_ops = &ops;
 bus.pmic_arb = &arb; bus.domain = &domain; bus.spmic = &controller;
 bus.base_apid = base; bus.apid_count = count; bus.apid_data = apids;
 bus.ppid_to_apid = ppids;
 domain.host_data = &bus; domain.node = &controller;
 controller.dev.of_node = &controller; desc.bus = &bus;
 pmic_arb_init_apid_min_max(&bus);
}
static void entry(unsigned int a, u16 p, u8 write_ee, bool irq_owner)
{
 core[a] = ((u32)p << 8) | (irq_owner ? PMIC_ARB_CHAN_IS_IRQ_OWNER_MASK : 0);
 owners[a] = write_ee;
}
static void read_map(void)
{
 if (_pmic_arb_read_apid_map(&bus, core, PMIC_ARB_PPID_MASK, 8,
                            PMIC_ARB_CHAN_IS_IRQ_OWNER_MASK)) abort();
}
static int translate(u16 p, u8 irq)
{
 struct irq_fwspec spec = { .param_count = 4, .param = { p >> 8, p & 255, irq, 1 } };
 unsigned long hw; unsigned int type;
 return qpnpint_irq_domain_translate(&domain, &spec, &hw, &type);
}
static void pending(unsigned int a, unsigned int irq)
{
 acc[a] = 1; pic_status[a] |= BIT(irq);
 owner_status[(a >> 5) - (bus.base_apid >> 5)] |= BIT(a & 31);
}
static int pending_before_mapping(void)
{
 setup(0, 512, 0);
 entry(172, 0x100, 0, true); entry(209, 0x200, 0, true); entry(211, 0x213, 0, true);
 read_map(); CHECK(!translate(0x100, 0)); CHECK(!translate(0x200, 0));
 pending(211, 4); pmic_arb_chained_irq(&desc);
 CHECK(!warnings); CHECK(clear[211] == BIT(4)); CHECK(!pic_status[211]);
 CHECK(pmic_enable == 0x90 && pmic_latched == 0x90); CHECK(!handled);
 return 0;
}
static int mapped_owned(void)
{
 setup(0, 512, 0); entry(211, 0x213, 0, true); read_map();
 CHECK(!translate(0x213, 7)); mappings[211][7] = 37; pending(211, 7);
 pmic_arb_chained_irq(&desc); CHECK(handled == 1 && !warnings && !pic_writes[211]); return 0;
}
static int foreign_inside_range(void)
{
 setup(0, 512, 0);
 entry(172, 0x100, 0, true); entry(220, 0x200, 0, true); entry(211, 0x213, 1, true);
 read_map(); CHECK(!translate(0x100, 0)); CHECK(!translate(0x200, 0));
 pending(211, 4); pmic_arb_chained_irq(&desc);
 CHECK(!pic_reads[211] && !pic_writes[211]); CHECK(warnings == 1); return 0;
}
static int invalid_zero_entry(void)
{
 setup(0, 512, 0); entry(172, 0x100, 0, true); entry(220, 0x200, 0, true); read_map();
 CHECK(apids[211].irq_ee == INVALID_EE);
 CHECK(!translate(0x100, 0)); CHECK(!translate(0x200, 0));
 /* No owner ACC status: exercise fallback, not just status dispatch. */
 pic_status[211] = BIT(4); acc[211] = 1; pmic_arb_chained_irq(&desc);
 CHECK(!pic_reads[211] && !pic_writes[211]); return 0;
}
static int duplicate_owner(void)
{
 setup(0, 512, 0);
 entry(172, 0x100, 0, true); entry(209, 0x200, 0, true);
 entry(211, 0x213, 0, true); entry(212, 0x213, 1, true); read_map();
 CHECK(apids[211].irq_ee == 1 && apids[212].irq_ee == 1);
 CHECK(fake_ppid_to_apid(&bus, 0x213) == 211);
 CHECK(bus.min_apid == 172 && bus.max_apid == 209);
 CHECK(!translate(0x213, 4)); CHECK(bus.max_apid == 209);
 pending(211, 4); pmic_arb_chained_irq(&desc);
 CHECK(!pic_reads[211] && !pic_writes[211]); return 0;
}
static int foreign_translation(void)
{
 setup(0, 512, 0); entry(172, 0x100, 0, true); entry(209, 0x200, 0, true);
 entry(300, 0x213, 1, true); read_map();
 CHECK(!translate(0x100, 0)); CHECK(!translate(0x200, 0)); CHECK(!translate(0x213, 4));
 CHECK(bus.min_apid == 172 && bus.max_apid == 209);
 pending(300, 4); pmic_arb_chained_irq(&desc); CHECK(!pic_reads[300]); return 0;
}
static int secondary_bus(unsigned int base)
{
 setup(base, 64, 0); entry(base - 1, 0x100, 0, true);
 entry(base + 2, 0x200, 0, true); entry(base + 51, 0x213, 0, true); read_map();
 CHECK(bus.min_apid == base + 2 && bus.max_apid == base + 51);
 CHECK(!translate(0x200, 0)); CHECK(!translate(0x213, 7));
 mappings[base + 51][7] = 37; pending(base + 51, 7); pmic_arb_chained_irq(&desc);
 CHECK(handled == 1 && !warnings && !pic_reads[base - 1]);
 CHECK(summary_count > 0 && summary_reads[0] == (int)(((base + 2) >> 5) - (base >> 5)));
 return 0;
}
static int legacy_lazy(void)
{
 setup(0, 0, 0); ppids[0x100] = 172 | PMIC_ARB_APID_VALID;
 ppids[0x213] = 211 | PMIC_ARB_APID_VALID;
 apids[172] = (struct apid_data){ .ppid = 0x100, .irq_ee = 0 };
 apids[211] = (struct apid_data){ .ppid = 0x213, .irq_ee = 0 };
 CHECK(bus.min_apid == MAX_APIDS - 1 && bus.max_apid == 0);
 CHECK(!translate(0x100, 0)); CHECK(bus.min_apid == 172 && bus.max_apid == 172);
 CHECK(!translate(0x213, 7)); CHECK(bus.min_apid == 172 && bus.max_apid == 211);
 mappings[211][7] = 37; pending(211, 7); pmic_arb_chained_irq(&desc);
 CHECK(handled == 1 && !warnings); return 0;
}
static int ppid_zero(void)
{
 setup(0, 512, 0); entry(211, 0, 0, true); read_map();
 CHECK(apids[211].ppid == 0 && apids[211].irq_ee == 0);
 CHECK(bus.min_apid == 211 && bus.max_apid == 211);
 CHECK(!translate(0, 4)); pending(211, 4); pmic_arb_chained_irq(&desc);
 CHECK(clear[211] == BIT(4) && !warnings); return 0;
}
static int empty_owned(void)
{
 setup(519, 64, 0); entry(549, 0x213, 1, true); read_map();
 CHECK(bus.min_apid > bus.max_apid);
 pending(549, 4); pmic_arb_chained_irq(&desc);
 CHECK(summary_count == 0 && !pic_reads[549] && !warnings); return 0;
}
static int truncated_map(void)
{
 setup(0, 512, 0); arb.core_size = 210 * sizeof(u32);
 entry(172, 0x100, 0, true); entry(211, 0x213, 0, true); read_map();
 CHECK(apids[211].irq_ee == INVALID_EE);
 CHECK(bus.min_apid == 172 && bus.max_apid == 172); return 0;
}
static int nonzero_ee(void)
{
 setup(0, 512, 3); entry(211, 0x213, 3, true); entry(220, 0x200, 0, true); read_map();
 CHECK(bus.min_apid == 211 && bus.max_apid == 211);
 CHECK(apids[210].irq_ee == INVALID_EE); pending(211, 4); pmic_arb_chained_irq(&desc);
 CHECK(clear[211] == BIT(4) && !pic_reads[220] && !warnings); return 0;
}
static int disabled_acc(void)
{
 setup(0, 512, 0); entry(211, 0x213, 0, true); read_map(); CHECK(!translate(0x213, 7));
 pending(211, 7); acc[211] = 0; mappings[211][7] = 37; pmic_arb_chained_irq(&desc);
 CHECK(!handled && !pic_writes[211] && !warnings); return 0;
}
int main(int argc, char **argv)
{
 int ret = 99;
 if (argc != 2) return 99;
 if (!strcmp(argv[1], "pending_before_mapping")) ret = pending_before_mapping();
 if (!strcmp(argv[1], "mapped_owned")) ret = mapped_owned();
 if (!strcmp(argv[1], "foreign_inside_range")) ret = foreign_inside_range();
 if (!strcmp(argv[1], "invalid_zero_entry")) ret = invalid_zero_entry();
 if (!strcmp(argv[1], "duplicate_owner")) ret = duplicate_owner();
 if (!strcmp(argv[1], "foreign_translation")) ret = foreign_translation();
 if (!strcmp(argv[1], "secondary_aligned")) ret = secondary_bus(512);
 if (!strcmp(argv[1], "secondary_unaligned")) ret = secondary_bus(519);
 if (!strcmp(argv[1], "legacy_lazy")) ret = legacy_lazy();
 if (!strcmp(argv[1], "ppid_zero")) ret = ppid_zero();
 if (!strcmp(argv[1], "empty_owned")) ret = empty_owned();
 if (!strcmp(argv[1], "truncated_map")) ret = truncated_map();
 if (!strcmp(argv[1], "nonzero_ee")) ret = nonzero_ee();
 if (!strcmp(argv[1], "disabled_acc")) ret = disabled_acc();
 if (!ret) printf("PASS %s\n", argv[1]);
 return ret;
}
