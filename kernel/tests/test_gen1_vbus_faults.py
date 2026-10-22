import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


KERNEL_SOURCE = Path(os.environ.get('AGNOS_USB_KERNEL_SOURCE', Path(__file__).resolve().parents[2] / 'build/linux'))
SOURCE = KERNEL_SOURCE / 'drivers/usb/typec/tcpm/qcom/qcom_pmic_typec_port_gen1.c'


def extract(source, name):
  start = re.search(rf'^(?:static )?(?:int|void|struct|irqreturn_t) {name}\b', source, re.M).start()
  opening = source.index('{', start)
  depth = 1
  end = opening + 1
  while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
  return source[start:end] + (';' if source[end:end + 1] == ';' else '') + '\n'


PREFIX = r'''
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t u32;
#define USBIN_CMD_IL_REG 0x40
#define USBIN_SUSPEND 1
#define TYPEC_STATUS_4_REG 0x0e
#define TYPEC_VBUS_STATUS 0x40
#define TYPEC_VBUS_ERROR 0x20
#define TYPEC_VCONN_OVERCURRENT 0x04
#define TYPEC_SW_CTRL_REG 0x68
#define CC_ORIENTATION 2
#define VCONN_EN_ORIENTATION 0x40
#define VCONN_EN_VALUE 8
#define VCONN_OVERCURRENT_INT_EN 0x20
#define REGULATOR_EVENT_FAIL 0x100
#define REGULATOR_EVENT_OVER_CURRENT 0x200
#define NOTIFY_DONE 0
#define NOTIFY_OK 1
#define IRQ_HANDLED 1
#define container_of(ptr, type, member) ((type *)((char *)(ptr) - offsetof(type, member)))
typedef int irqreturn_t;
struct device { int unused; };
struct tcpm_port { int unused; };
struct regulator { int unused; };
struct regmap { int unused; };
struct mutex { int held; };
struct notifier_block { int unused; };
struct pmic_typec;
struct tcpc_dev { struct pmic_typec *owner; };
struct pmic_typec { struct tcpc_dev tcpc; void *pmic_typec_port; };
#define tcpc_to_tcpm(tcpc) ((tcpc)->owner)
static struct {
  unsigned int usbin, typec_status, typec_control, source_errors;
  uint64_t fail_updates;
  int read_failure, enable_failure, disable_failure, force_failure, query_failure;
  int reads, updates, enables, disables, forces, hardware_enables, references;
  int errors, events, recoveries, cc_events, errorflags_failure;
  bool hardware_on, halt, failed_enable_leaves_on, failed_enable_leaves_halt;
  bool failed_disable_turns_off, turn_off_after_query;
} fake;
#define dev_err(dev, ...) do { (void)(dev); fake.errors++; } while (0)
#define dev_warn_ratelimited(dev, ...) do { (void)(dev); fake.errors++; } while (0)
static void mutex_lock(struct mutex *lock) { assert(!lock->held); lock->held = 1; }
static void mutex_unlock(struct mutex *lock) { assert(lock->held); lock->held = 0; }
static int take_failure(int *failure) { int ret = *failure; *failure = 0; return ret; }
static int regmap_read(struct regmap *map, unsigned int address, unsigned int *value)
{
  fake.reads++;
  int ret = take_failure(&fake.read_failure);
  if (ret) return ret;
  assert(address == 0x1340 || address == 0x130e);
  *value = address == 0x1340 ? fake.usbin : fake.typec_status;
  return 0;
}
static int regmap_update_bits(struct regmap *map, unsigned int address, unsigned int mask, unsigned int value)
{
  fake.updates++;
  assert(address == 0x1340 || address == 0x1368);
  if (fake.fail_updates & (UINT64_C(1) << fake.updates)) return -EREMOTEIO;
  unsigned int *reg = address == 0x1340 ? &fake.usbin : &fake.typec_control;
  *reg = (*reg & ~mask) | (value & mask);
  return 0;
}
static int regulator_enable(struct regulator *regulator)
{
  fake.enables++;
  int ret = take_failure(&fake.enable_failure);
  if (ret) {
    if (fake.failed_enable_leaves_on) fake.hardware_on = true;
    if (fake.failed_enable_leaves_halt) fake.halt = true;
    return ret;
  }
  if (!fake.hardware_on) { fake.hardware_enables++; fake.hardware_on = true; }
  fake.references++;
  fake.halt = true;
  return 0;
}
static int regulator_disable(struct regulator *regulator)
{
  fake.disables++;
  assert(fake.references > 0); /* An unbalanced disable must fail this test. */
  int ret = take_failure(&fake.disable_failure);
  if (ret) { if (fake.failed_disable_turns_off) fake.hardware_on = false; return ret; }
  if (--fake.references == 0) fake.hardware_on = fake.halt = false;
  return 0;
}
static int regulator_force_disable(struct regulator *regulator)
{
  fake.forces++;
  int ret = take_failure(&fake.force_failure);
  if (ret) return ret;
  fake.hardware_on = fake.halt = false;
  return 0;
}
static int regulator_is_enabled(struct regulator *regulator)
{
  int ret = take_failure(&fake.query_failure);
  if (ret) return ret;
  ret = fake.hardware_on;
  if (fake.turn_off_after_query) { fake.hardware_on = false; fake.turn_off_after_query = false; }
  return ret;
}
static void tcpm_vbus_change(struct tcpm_port *port) { fake.events++; }
static void tcpm_cc_change(struct tcpm_port *port) { fake.cc_events++; }
static void tcpm_port_error_recovery(struct tcpm_port *port) { assert(port); fake.recoveries++; }
static void disable_irq(int irq) { }
static int regulator_get_error_flags(struct regulator *regulator, unsigned int *flags)
{
  *flags = fake.source_errors;
  return take_failure(&fake.errorflags_failure);
}
'''

TESTS = r'''
static struct gen1_typec_port port;
static struct pmic_typec tcpm;
static struct regulator regulator;
static struct regmap map;
static struct device device;
static struct tcpm_port registered_port;

static void reset(unsigned int usbin)
{
  memset(&fake, 0, sizeof(fake));
  memset(&port, 0, sizeof(port));
  memset(&tcpm, 0, sizeof(tcpm));
  fake.usbin = usbin;
  port.base = 0x1300;
  port.dev = &device;
  port.regmap = &map;
  port.vbus = &regulator;
  port.tcpm_port = &registered_port;
  tcpm.pmic_typec_port = &port;
  tcpm.tcpc.owner = &tcpm;
}
static int set(bool on) { return gen1_typec_set_vbus(&tcpm.tcpc, on, false); }
static void fail_enable_and_rollback(void)
{
  fake.enable_failure = -EBUSY;
  fake.fail_updates = UINT64_C(1) << 2;
  assert(set(true) == -EBUSY);
  assert(port.usbin_saved && !port.vbus_enabled && port.usbin_restore == 0);
  assert(fake.usbin == 0xa5 && fake.references == 0 && fake.errors >= 1);
}
static void test_read_and_suspend_errors(void)
{
  reset(0xa4);
  fake.read_failure = -EIO;
  assert(set(true) == -EIO);
  assert(!port.usbin_saved && fake.usbin == 0xa4 && fake.enables == 0);
  reset(0xa4);
  fake.fail_updates = UINT64_C(1) << 1;
  assert(set(true) == -EREMOTEIO);
  assert(!port.usbin_saved && fake.usbin == 0xa4 && fake.enables == 0);
}
static void test_enable_error_successful_rollback(void)
{
  reset(0xa4);
  fake.enable_failure = -EBUSY;
  assert(set(true) == -EBUSY);
  assert(!port.usbin_saved && !port.vbus_enabled && fake.usbin == 0xa4);
  assert(fake.references == 0 && fake.events == 0 && fake.errors == 0);
}
static void test_enable_error_failed_rollback_off_retry(void)
{
  reset(0xa4);
  fail_enable_and_rollback();
  assert(set(false) == 0);
  assert(!port.usbin_saved && fake.usbin == 0xa4 && fake.disables == 0);
}
static void test_enable_retry_keeps_original_snapshot(void)
{
  reset(0xa4);
  fail_enable_and_rollback();
  assert(set(true) == 0);
  assert(port.usbin_saved && port.usbin_restore == 0 && fake.reads == 1);
  assert(set(false) == 0);
  assert(fake.usbin == 0xa4 && fake.references == 0 && fake.events == 2);
}
static void test_enable_retry_failure_keeps_original_snapshot(void)
{
  reset(0xa4);
  fail_enable_and_rollback();
  fake.enable_failure = -EAGAIN;
  fake.fail_updates |= UINT64_C(1) << 4;
  assert(set(true) == -EAGAIN);
  assert(port.usbin_saved && port.usbin_restore == 0 && fake.reads == 1);
  assert(set(false) == 0 && fake.usbin == 0xa4 && fake.disables == 0);
}
static void test_resuspend_error_keeps_pending_restore(void)
{
  reset(0xa4);
  fail_enable_and_rollback();
  fake.fail_updates |= UINT64_C(1) << 3;
  assert(set(true) == -EREMOTEIO);
  assert(port.usbin_saved && port.usbin_restore == 0 && fake.enables == 1);
  assert(set(false) == 0 && fake.usbin == 0xa4);
}
static void test_originally_suspended_input_is_restored(void)
{
  reset(0xa5);
  fake.enable_failure = -EBUSY;
  fake.fail_updates = UINT64_C(1) << 2;
  assert(set(true) == -EBUSY);
  assert(port.usbin_saved && port.usbin_restore == 1);
  assert(set(false) == 0 && !port.usbin_saved && fake.usbin == 0xa5);
}
static void test_disable_failure_keeps_owned_reference(void)
{
  reset(0xa4);
  assert(set(true) == 0);
  fake.disable_failure = -EIO;
  assert(set(false) == -EIO);
  assert(port.vbus_enabled && port.usbin_saved && fake.references == 1);
  assert(fake.usbin == 0xa5 && fake.hardware_on && fake.events == 1);
  assert(set(false) == 0);
  assert(!port.vbus_enabled && !port.usbin_saved && fake.references == 0);
}
static void test_restore_failure_after_source_off_retries_without_disable(void)
{
  reset(0xa4);
  assert(set(true) == 0);
  fake.fail_updates = UINT64_C(1) << 2;
  assert(set(false) == -EREMOTEIO);
  assert(!port.vbus_enabled && port.usbin_saved && !fake.hardware_on);
  assert(fake.references == 0 && fake.events == 2);
  assert(set(false) == 0 && fake.disables == 1 && fake.usbin == 0xa4);
}
static void test_teardown_retries_pending_restore_and_is_idempotent(void)
{
  reset(0xa4);
  fail_enable_and_rollback();
  fake.fail_updates |= UINT64_C(1) << 3;
  gen1_typec_vbus_cleanup(&tcpm);
  assert(port.usbin_saved && fake.usbin == 0xa5);
  gen1_typec_vbus_cleanup(&tcpm);
  assert(!port.usbin_saved && fake.usbin == 0xa4);
  gen1_typec_vbus_cleanup(&tcpm);
  assert(fake.disables == 0 && fake.updates == 4);
}
static void test_bootloader_off_does_not_enable_output(void)
{
  reset(0xa4);
  assert(gen1_typec_init_vbus(&tcpm) == 0);
  assert(fake.enables == 0 && fake.disables == 0 && fake.forces == 1 && fake.updates == 0);
}
static void test_bootloader_source_is_balanced_and_normalized(void)
{
  reset(0xa5);
  fake.hardware_on = true;
  assert(gen1_typec_init_vbus(&tcpm) == 0);
  assert(!fake.hardware_on && fake.hardware_enables == 0 && fake.references == 0);
  assert(fake.enables == 0 && fake.disables == 0 && fake.forces == 1 && fake.usbin == 0xa4);
}
static void test_bootloader_query_and_force_errors_abort(void)
{
  reset(0xa5);
  fake.hardware_on = true;
  fake.query_failure = -EIO;
  assert(gen1_typec_init_vbus(&tcpm) == -EIO);
  assert(fake.enables == 0 && fake.disables == 0 && fake.forces == 1 && !fake.hardware_on);
  reset(0xa5);
  fake.hardware_on = true;
  fake.force_failure = -EBUSY;
  assert(gen1_typec_init_vbus(&tcpm) == -EBUSY);
  assert(!port.vbus_enabled && port.vbus_uncertain && port.usbin_saved && fake.hardware_on);
}
static void test_bootloader_force_error_remains_pending_for_cleanup(void)
{
  reset(0xa5);
  fake.hardware_on = true;
  fake.force_failure = -EIO;
  assert(gen1_typec_init_vbus(&tcpm) == -EIO);
  assert(!port.vbus_enabled && port.vbus_uncertain && port.usbin_saved && fake.references == 0);
  gen1_typec_vbus_cleanup(&tcpm);
  assert(!fake.hardware_on && fake.references == 0 && fake.usbin == 0xa4);
}
static void test_bootloader_restore_error_is_retried_by_cleanup(void)
{
  reset(0xa5);
  fake.hardware_on = true;
  fake.fail_updates = UINT64_C(1) << 1;
  assert(gen1_typec_init_vbus(&tcpm) == -EREMOTEIO);
  assert(!port.vbus_enabled && port.usbin_saved && fake.references == 0);
  gen1_typec_vbus_cleanup(&tcpm);
  assert(fake.disables == 0 && fake.forces == 1 && fake.usbin == 0xa4 && !port.usbin_saved);
}
static void test_force_cleanup_never_changes_consumer_reference_counts(void)
{
  reset(0xa5);
  fake.hardware_on = true;
  fake.references = 1;
  assert(gen1_typec_init_vbus(&tcpm) == 0);
  assert(!fake.hardware_on && fake.references == 1 && fake.enables == 0 && fake.disables == 0);
}
static void test_failed_enable_partial_output_is_forced_off(void)
{
  reset(0xa4);
  fake.enable_failure = -ETIMEDOUT;
  fake.failed_enable_leaves_on = true;
  assert(set(true) == -ETIMEDOUT);
  assert(fake.enables == 1 && fake.disables == 0 && fake.forces == 1 && fake.references == 0);
  assert(!fake.hardware_on && !port.usbin_saved && fake.usbin == 0xa4);
}
static void test_failed_enable_partial_output_force_failure_stays_pending(void)
{
  reset(0xa4);
  fake.enable_failure = -ETIMEDOUT;
  fake.failed_enable_leaves_on = true;
  fake.force_failure = -EIO;
  assert(set(true) == -ETIMEDOUT);
  assert(fake.hardware_on && !port.vbus_enabled && port.vbus_uncertain);
  assert(port.usbin_saved && fake.usbin == 0xa5 && fake.references == 0);
  assert(set(false) == 0 && fake.references == 0 && fake.usbin == 0xa4);
}
static void test_failed_enable_unknown_output_keeps_input_suspended(void)
{
  reset(0xa4);
  fake.enable_failure = -EIO;
  fake.force_failure = -EREMOTEIO;
  assert(set(true) == -EIO);
  assert(port.vbus_uncertain && port.usbin_saved && fake.usbin == 0xa5);
  assert(set(false) == 0 && fake.usbin == 0xa4 && !port.vbus_uncertain);
}
static void test_source_off_query_error_is_retryable_without_disable(void)
{
  reset(0xa4);
  assert(set(true) == 0);
  fake.query_failure = -EREMOTEIO;
  assert(set(false) == -EREMOTEIO);
  assert(!port.vbus_enabled && port.vbus_uncertain && port.usbin_saved);
  assert(fake.references == 0 && fake.usbin == 0xa5);
  assert(set(false) == 0 && fake.disables == 1 && fake.usbin == 0xa4);
}
static void test_get_vbus_requires_real_source_status(void)
{
  reset(0xa4);
  assert(set(true) == 0);
  assert(gen1_typec_get_vbus(&tcpm.tcpc) == 1);
  fake.hardware_on = false;
  assert(gen1_typec_get_vbus(&tcpm.tcpc) == 0);
  fake.hardware_on = true;
  fake.source_errors = 1;
  assert(gen1_typec_get_vbus(&tcpm.tcpc) == 0);
  fake.source_errors = 0;
  fake.errorflags_failure = -EIO;
  assert(gen1_typec_get_vbus(&tcpm.tcpc) == 0);
  port.vbus_fault = true;
  assert(gen1_typec_get_vbus(&tcpm.tcpc) == 0);
}
static void test_regulator_fault_notifier_and_stop_lifetime(void)
{
  reset(0xa4);
  assert(gen1_typec_vbus_event(&port.vbus_notifier, 1, NULL) == NOTIFY_DONE);
  assert(!port.vbus_fault && fake.recoveries == 0);
  assert(gen1_typec_vbus_event(&port.vbus_notifier, REGULATOR_EVENT_FAIL, NULL) == NOTIFY_OK);
  assert(port.vbus_fault && fake.recoveries == 1);
  gen1_typec_port_stop(&tcpm);
  assert(port.tcpm_port == NULL);
  gen1_typec_vbus_event(&port.vbus_notifier, REGULATOR_EVENT_OVER_CURRENT, NULL);
  assert(fake.recoveries == 1);
}
static void test_typec_irq_recovers_vconn_and_vbus_faults(void)
{
  reset(0xa4);
  fake.typec_status = TYPEC_VCONN_OVERCURRENT;
  gen1_typec_irq(0, &port);
  assert(fake.recoveries == 1);
  fake.typec_status = TYPEC_VBUS_ERROR;
  gen1_typec_irq(0, &port);
  assert(fake.recoveries == 2);
  gen1_typec_port_stop(&tcpm);
  gen1_typec_irq(0, &port);
  assert(fake.recoveries == 2);
}
static void test_no_resourcing_after_boot_query_race(void)
{
  reset(0xa5);
  fake.hardware_on = true;
  fake.turn_off_after_query = true;
  assert(gen1_typec_init_vbus(&tcpm) == 0);
  assert(fake.enables == 0 && fake.hardware_enables == 0 && fake.forces == 1);
}
static void test_cmd_off_failed_halt_rollback_stays_pending(void)
{
  reset(0xa4);
  fake.enable_failure = -EIO;
  fake.failed_enable_leaves_halt = true;
  fake.force_failure = -EREMOTEIO;
  assert(set(true) == -EIO);
  assert(!fake.hardware_on && fake.halt && port.usbin_saved && port.vbus_uncertain);
  assert(set(false) == 0);
  assert(!fake.halt && fake.usbin == 0xa4 && fake.enables == 1 && fake.forces == 2);
}
static void test_on_request_after_partial_owned_disable_reconciles_first(void)
{
  reset(0xa4);
  assert(set(true) == 0);
  fake.disable_failure = -EIO;
  fake.failed_disable_turns_off = true;
  assert(set(false) == -EIO);
  assert(!fake.hardware_on && fake.halt && port.vbus_enabled && port.vbus_uncertain);
  assert(set(true) == 0);
  assert(fake.hardware_on && port.vbus_enabled && !port.vbus_uncertain && fake.references == 1);
  assert(fake.enables == 2 && fake.disables == 2);
  assert(set(false) == 0 && fake.references == 0 && fake.usbin == 0xa4);
}
static void test_vconn_off_writes_without_orientation_read(void)
{
  reset(0xa4);
  fake.typec_control = VCONN_EN_VALUE | VCONN_OVERCURRENT_INT_EN | VCONN_EN_ORIENTATION;
  fake.read_failure = -EIO;
  assert(gen1_typec_set_vconn(&tcpm.tcpc, false) == 0);
  assert(fake.reads == 0 && !(fake.typec_control & (VCONN_EN_VALUE | VCONN_OVERCURRENT_INT_EN)));
  assert(gen1_typec_set_vconn(&tcpm.tcpc, true) == -EIO);
  assert(fake.updates == 1);
}
'''


class TestGen1VbusFaults(unittest.TestCase):
  def test_actual_c_fault_paths(self):
    source = SOURCE.read_text()
    production = '\n'.join(extract(source, name) for name in (
      'gen1_typec_port', 'gen1_typec_get_vbus', 'gen1_typec_restore_usbin', 'gen1_typec_stop_vbus', 'gen1_typec_set_vbus',
      'gen1_typec_vbus_event', 'gen1_typec_vbus_cleanup', 'gen1_typec_init_vbus', 'gen1_typec_irq', 'gen1_typec_port_stop',
      'gen1_typec_set_vconn'))
    cases = re.findall(r'^static void (test_\w+)\(void\)', TESTS, re.M)
    main = 'int main(void) {\n' + ''.join(f'puts("{case}"); fflush(stdout); {case}();\n' for case in cases) + 'return 0; }\n'
    with tempfile.TemporaryDirectory() as temp:
      path = Path(temp)
      (path / 'test.c').write_text(PREFIX + production + TESTS + main)
      build = subprocess.run(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                              str(path / 'test.c'), '-o', str(path / 'test')], capture_output=True, text=True)
      self.assertEqual(build.returncode, 0, build.stderr)
      run = subprocess.run([str(path / 'test')], capture_output=True, text=True)
      self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
      print(f'{len(cases)} actual-C fault scenarios passed')


if __name__ == '__main__':
  unittest.main()
