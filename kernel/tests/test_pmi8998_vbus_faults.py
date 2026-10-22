import re
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_gen1_vbus_faults import KERNEL_SOURCE, extract


PREFIX = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define BIT(n) (1U << (n))
#define GENMASK(hi, lo) (((~0U) >> (31 - (hi))) & ((~0U) << (lo)))
#define REGULATOR_EVENT_FAIL 1
#define REGULATOR_EVENT_OVER_CURRENT 2
#define REGULATOR_ERROR_FAIL 1
#define REGULATOR_ERROR_OVER_CURRENT 2
#define IRQ_HANDLED 1
typedef int irqreturn_t;
struct device { int unused; };
struct regmap { int unused; };
struct regulator_desc { unsigned int enable_reg; };
struct regulator_dev { struct device dev; struct regmap *regmap; struct regulator_desc *desc; };
static struct {
  unsigned int command, halt, fault, status;
  int writes, updates, reads, status_reads, ready_after, poll_limit;
  uint64_t fail_writes, fail_updates, fail_reads;
  unsigned long event;
  int notifications, errors;
  bool unlocked;
} fake;
#define dev_err(dev, ...) do { (void)(dev); fake.errors++; } while (0)
static int regmap_write(struct regmap *map, unsigned int address, unsigned int value)
{
  assert(address == 0x11d0 && value == 0xa5);
  if (fake.fail_writes & (UINT64_C(1) << ++fake.writes)) return -EIO;
  fake.unlocked = true;
  return 0;
}
static int regmap_update_bits(struct regmap *map, unsigned int address, unsigned int mask, unsigned int value)
{
  assert(address == 0x1140 || address == 0x11c0);
  bool failed = fake.fail_updates & (UINT64_C(1) << ++fake.updates);
  if (address == 0x11c0) { assert(fake.unlocked); fake.unlocked = false; }
  if (failed) return -EIO;
  unsigned int *reg = address == 0x1140 ? &fake.command : &fake.halt;
  *reg = (*reg & ~mask) | (value & mask);
  return 0;
}
static int regmap_read(struct regmap *map, unsigned int address, unsigned int *value)
{
  if (fake.fail_reads & (UINT64_C(1) << ++fake.reads)) return -EIO;
  switch (address) {
    case 0x1140: *value = fake.command; break;
    case 0x1110: *value = fake.fault; break;
    case 0x1109:
      fake.status_reads++;
      *value = fake.status_reads >= fake.ready_after ? fake.status : 0;
      break;
    default: assert(false);
  }
  return 0;
}
#define regmap_read_poll_timeout(map, address, value, condition, delay, timeout) \
  ({ int result = 0, count = 0; \
     assert((delay) == 1000 && (timeout) == 250000); \
     do { result = regmap_read(map, address, &(value)); \
       if (result || (condition)) break; \
     } while (++count < fake.poll_limit); \
     result ? result : (condition) ? 0 : -ETIMEDOUT; })
static int regulator_enable_regmap(struct regulator_dev *rdev)
{ return regmap_update_bits(rdev->regmap, rdev->desc->enable_reg, 1, 1); }
static int regulator_disable_regmap(struct regulator_dev *rdev)
{ return regmap_update_bits(rdev->regmap, rdev->desc->enable_reg, 1, 0); }
static void regulator_notifier_call_chain(struct regulator_dev *rdev, unsigned long event, void *data)
{ fake.notifications++; fake.event = event; }
'''

TESTS = r'''
static struct regulator_desc desc = { .enable_reg = 0x1140 };
static struct regmap map;
static struct regulator_dev rdev = { .regmap = &map, .desc = &desc };
static void reset(void)
{
  memset(&fake, 0, sizeof(fake));
  fake.status = 0x0a;
  fake.ready_after = 1;
  fake.poll_limit = 4;
}
static void test_enable_waits_for_softstart_and_state(void)
{
  reset();
  fake.ready_after = 3;
  assert(pmi8998_vbus_enable(&rdev) == 0);
  assert(fake.status_reads == 3 && fake.command == 1 && fake.halt == 1);
  assert(pmi8998_vbus_disable(&rdev) == 0);
  assert(fake.command == 0 && fake.halt == 0);
}
static void test_enable_timeout_rolls_back(void)
{
  reset();
  fake.ready_after = 100;
  assert(pmi8998_vbus_enable(&rdev) == -ETIMEDOUT);
  assert(fake.status_reads == 4 && !fake.command && !fake.halt);
}
static void test_softstart_alone_is_not_ready(void)
{
  reset();
  fake.status = 0x08;
  assert(pmi8998_vbus_enable(&rdev) == -ETIMEDOUT);
  assert(!fake.command && !fake.halt);
}
static void test_enable_status_io_error_rolls_back(void)
{
  reset();
  fake.fail_reads = UINT64_C(1) << 1;
  assert(pmi8998_vbus_enable(&rdev) == -EIO);
  assert(!fake.command && !fake.halt);
}
static void test_unlock_and_halt_errors_do_not_enable_output(void)
{
  reset();
  fake.fail_writes = UINT64_C(1) << 1;
  assert(pmi8998_vbus_enable(&rdev) == -EIO);
  assert(!fake.command);
  reset();
  fake.fail_updates = UINT64_C(1) << 1;
  assert(pmi8998_vbus_enable(&rdev) == -EIO);
  assert(!fake.command);
}
static void test_command_write_error_rolls_back_halt(void)
{
  reset();
  fake.fail_updates = UINT64_C(1) << 2;
  assert(pmi8998_vbus_enable(&rdev) == -EIO);
  assert(!fake.command && !fake.halt);
}
static void test_failed_rollback_is_reported_without_claiming_ready(void)
{
  reset();
  fake.ready_after = 100;
  fake.fail_updates = UINT64_C(1) << 3;
  assert(pmi8998_vbus_enable(&rdev) == -ETIMEDOUT);
  assert(fake.command == 1 && fake.halt == 1 && fake.errors == 1);
}
static void test_disable_failure_and_retry(void)
{
  reset();
  fake.command = fake.halt = 1;
  fake.fail_updates = UINT64_C(1) << 1;
  assert(pmi8998_vbus_disable(&rdev) == -EIO);
  assert(fake.command == 1 && fake.halt == 1);
  assert(pmi8998_vbus_disable(&rdev) == 0);
  assert(fake.command == 0 && fake.halt == 0);
}
static void test_disable_halt_restore_failure_is_not_atomic(void)
{
  reset();
  fake.command = fake.halt = 1;
  fake.fail_updates = UINT64_C(1) << 2;
  assert(pmi8998_vbus_disable(&rdev) == -EIO);
  assert(fake.command == 0 && fake.halt == 1);
  assert(pmi8998_vbus_disable(&rdev) == 0);
  assert(fake.command == 0 && fake.halt == 0);
}
static void test_actual_error_flags(void)
{
  unsigned int flags = 99;
  reset();
  assert(pmi8998_vbus_get_error_flags(&rdev, &flags) == 0 && flags == 0);
  fake.command = 1;
  assert(pmi8998_vbus_get_error_flags(&rdev, &flags) == 0 && flags == 0);
  fake.fault = 2;
  assert(pmi8998_vbus_get_error_flags(&rdev, &flags) == 0 && flags == REGULATOR_ERROR_OVER_CURRENT);
  fake.fault = 1;
  assert(pmi8998_vbus_get_error_flags(&rdev, &flags) == 0 && flags == REGULATOR_ERROR_FAIL);
  fake.fault = 0;
  fake.status = 8;
  assert(pmi8998_vbus_get_error_flags(&rdev, &flags) == 0 && flags == REGULATOR_ERROR_FAIL);
  fake.fail_reads = UINT64_C(1) << (fake.reads + 1);
  assert(pmi8998_vbus_get_error_flags(&rdev, &flags) == -EIO);
}
static void test_standard_fault_notifier_events(void)
{
  reset();
  assert(pmi8998_vbus_fail_irq(0, &rdev) == IRQ_HANDLED);
  assert(fake.notifications == 1 && fake.event == REGULATOR_EVENT_FAIL);
  assert(pmi8998_vbus_oc_irq(1, &rdev) == IRQ_HANDLED);
  assert(fake.notifications == 2 && fake.event == REGULATOR_EVENT_OVER_CURRENT);
}
'''


class TestPmi8998VbusFaults(unittest.TestCase):
  def test_actual_provider_c_fault_paths(self):
    source = (KERNEL_SOURCE / 'drivers/regulator/qcom_usb_vbus-regulator.c').read_text()
    constants = source[source.index('#define CMD_OTG'):source.index('struct qcom_usb_vbus_reg_data')]
    production = '\n'.join(extract(source, name) for name in (
      'pmi8998_halt_1_in_8', 'pmi8998_vbus_enable', 'pmi8998_vbus_disable',
      'pmi8998_vbus_get_error_flags', 'pmi8998_vbus_fail_irq', 'pmi8998_vbus_oc_irq'))
    cases = re.findall(r'^static void (test_\w+)\(void\)', TESTS, re.M)
    main = 'int main(void) {\n' + ''.join(f'puts("{case}"); fflush(stdout); {case}();\n' for case in cases) + 'return 0; }\n'
    with tempfile.TemporaryDirectory() as temp:
      path = Path(temp)
      (path / 'test.c').write_text(PREFIX + constants + production + TESTS + main)
      build = subprocess.run(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                              str(path / 'test.c'), '-o', str(path / 'test')], capture_output=True, text=True)
      self.assertEqual(build.returncode, 0, build.stderr)
      run = subprocess.run([str(path / 'test')], capture_output=True, text=True)
      self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
      print(f'{len(cases)} actual provider C fault scenarios passed')


if __name__ == '__main__':
  unittest.main()
