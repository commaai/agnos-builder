import subprocess
import tempfile
import unittest
from pathlib import Path

from test_gen1_vbus_faults import KERNEL_SOURCE, extract


PREFIX = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#define UFP_EN_CMD 4
struct device { int unused; };
struct mutex { bool held; };
struct gen1_typec_port { struct device *dev; struct mutex lock; };
struct tcpc_dev { void *fwnode; };
struct pmic_typec {
  void *pmic_typec_port;
  void *tcpm_port;
  struct tcpc_dev tcpc;
  void (*pdphy_stop)(struct pmic_typec *);
  void (*port_stop)(struct pmic_typec *);
};
struct pmic_typec_resources { void (*port_shutdown)(struct pmic_typec *); };
struct platform_device { struct device dev; };
static struct {
  int steps[8], count, logs, vconn_failure, role_failure;
  bool irq_live, worker_live;
} fake;
static struct gen1_typec_port port;
static struct pmic_typec tcpm;
static struct pmic_typec_resources resources;
static struct platform_device pdev;
static void step(int id) { assert(fake.count < 8); fake.steps[fake.count++] = id; }
#define dev_err(dev, ...) do { (void)(dev); fake.logs++; } while (0)
static void mutex_lock(struct mutex *lock) { assert(!lock->held); lock->held = true; }
static void mutex_unlock(struct mutex *lock) { assert(lock->held); lock->held = false; }
static void gen1_typec_vbus_cleanup(void *data)
{ assert(!fake.irq_live && !fake.worker_live); step(4); }
static int gen1_typec_set_vconn(struct tcpc_dev *tcpc, bool on)
{ assert(!on && !fake.irq_live && !fake.worker_live); step(5); return fake.vconn_failure; }
static int gen1_typec_set_power_role(struct gen1_typec_port *p, unsigned int role)
{ assert(role == UFP_EN_CMD && p->lock.held && !fake.worker_live); step(6); return fake.role_failure; }
static void *platform_get_drvdata(struct platform_device *device) { return &tcpm; }
static const struct pmic_typec_resources *of_device_get_match_data(struct device *device) { return &resources; }
static void tcpm_unregister_port(void *p) { assert(!fake.irq_live); fake.worker_live = false; step(3); }
static void fwnode_handle_put(void *fwnode) { step(7); }
static void stop_pdphy(struct pmic_typec *p) { step(1); }
static void stop_port(struct pmic_typec *p) { fake.irq_live = false; step(2); }
'''

TESTS = r'''
static void reset(bool gen1)
{
  memset(&fake, 0, sizeof(fake));
  fake.irq_live = fake.worker_live = true;
  tcpm.pmic_typec_port = &port;
  tcpm.pdphy_stop = stop_pdphy;
  tcpm.port_stop = stop_port;
  resources.port_shutdown = gen1 ? qcom_pmic_typec_gen1_port_shutdown : NULL;
}
int main(void)
{
  reset(true);
  qcom_pmic_typec_shutdown(&pdev);
  assert(fake.count == 7);
  for (int i = 0; i < 7; i++) assert(fake.steps[i] == i + 1);
  reset(true);
  fake.vconn_failure = fake.role_failure = -EIO;
  qcom_pmic_typec_shutdown(&pdev);
  assert(fake.count == 7 && fake.logs == 2); /* Attempt every safe-state operation. */
  reset(false);
  qcom_pmic_typec_shutdown(&pdev);
  assert(fake.count == 0 && fake.irq_live && fake.worker_live);
  reset(false);
  qcom_pmic_typec_remove(&pdev);
  assert(fake.count == 4 && fake.steps[3] == 7);
  return 0;
}
'''


class TestTypecShutdown(unittest.TestCase):
  def test_actual_shutdown_order_and_error_paths(self):
    common = (KERNEL_SOURCE / 'drivers/usb/typec/tcpm/qcom/qcom_pmic_typec.c').read_text()
    gen1 = (KERNEL_SOURCE / 'drivers/usb/typec/tcpm/qcom/qcom_pmic_typec_port_gen1.c').read_text()
    production = extract(gen1, 'qcom_pmic_typec_gen1_port_shutdown')
    production += extract(common, 'qcom_pmic_typec_remove') + extract(common, 'qcom_pmic_typec_shutdown')
    with tempfile.TemporaryDirectory() as temp:
      path = Path(temp)
      (path / 'test.c').write_text(PREFIX + production + TESTS)
      build = subprocess.run(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                              str(path / 'test.c'), '-o', str(path / 'test')], capture_output=True, text=True)
      self.assertEqual(build.returncode, 0, build.stderr)
      run = subprocess.run([str(path / 'test')], capture_output=True, text=True)
      self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
      print('4 actual-C shutdown ordering/error scenarios passed')


if __name__ == '__main__':
  unittest.main()
