#!/usr/bin/env python3
"""Run the real PMIC-arbiter C with fake MMIO; no kernel build or device needed.

The baseline comes from kernel/linux. The fixed driver is produced by applying
patch0031 to a temporary copy. Requires host cc and git; uses only Python stdlib.
Run: python3 kernel/tests/test_spmi_irq_bounds.py -v
"""
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


TESTS = Path(__file__).resolve().parent
KERNEL = TESTS.parent
PATCH = KERNEL / 'patches/0031-spmi-pmic-arb-bound-irqs-by-hardware-ownership.patch'
DRIVER = Path('drivers/spmi/spmi-pmic-arb.c')
FUNCTIONS = ['cleanup_irq', 'periph_interrupt', 'pmic_arb_chained_irq',
             'qpnpint_irq_domain_translate', 'pmic_arb_init_apid_min_max', '_pmic_arb_read_apid_map']
CASES = ['pending_before_mapping', 'mapped_owned', 'foreign_inside_range', 'invalid_zero_entry',
         'duplicate_owner', 'foreign_translation', 'secondary_aligned', 'secondary_unaligned',
         'legacy_lazy', 'ppid_zero', 'empty_owned', 'truncated_map', 'nonzero_ee', 'disabled_acc']
BASELINE_FAIL = set(CASES) - {'mapped_owned', 'legacy_lazy', 'empty_owned', 'disabled_acc'}


def extract(source, name):
  """Extract a full function verbatim; braces in comments/literals do not count."""
  match = re.search(r'^static [^;\n]+\b' + re.escape(name) + r'\(', source, re.M)
  if not match:
    raise ValueError(name)
  start = source.index('{', match.start())
  tokens = re.compile(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[{}]', re.S)
  depth = 0
  for token in tokens.finditer(source, start):
    if token.group() == '{':
      depth += 1
    elif token.group() == '}':
      depth -= 1
      if depth == 0:
        return source[match.start():token.end()] + '\n'
  raise ValueError('unclosed ' + name)


class TestSpmiIrqBounds(unittest.TestCase):
  @classmethod
  def setUpClass(cls):
    cls.tmp = tempfile.TemporaryDirectory(prefix='spmi-irq-bounds-')
    cls.addClassCleanup(cls.tmp.cleanup)
    root = Path(cls.tmp.name)
    fixed = root / 'fixed' / DRIVER
    fixed.parent.mkdir(parents=True)
    baseline = KERNEL / 'linux' / DRIVER
    shutil.copy2(baseline, fixed)
    subprocess.run(['git', 'apply', '--check', '--whitespace=error', str(PATCH)],
                   cwd=root / 'fixed', check=True, capture_output=True, text=True)
    subprocess.run(['git', 'apply', '--whitespace=error', str(PATCH)],
                   cwd=root / 'fixed', check=True, capture_output=True, text=True)
    cls.binaries = {}
    for label, driver in [('before', baseline), ('fixed', fixed)]:
      extracted = '\n'.join(extract(driver.read_text(), name) for name in FUNCTIONS)
      harness = root / f'{label}.c'
      harness.write_text('#include "spmi_irq_harness.h"\n' + extracted + '\n#include "spmi_irq_cases.c"\n')
      binary = root / f'{label}.test'
      command = ['cc', '-std=gnu11', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
                 '-fsanitize=undefined,bounds', '-fno-sanitize-recover=all', '-I', str(TESTS),
                 str(harness), '-o', str(binary)]
      subprocess.run(command, check=True, capture_output=True, text=True)
      cls.binaries[label] = binary

  def run_cases(self, label):
    for case in CASES:
      with self.subTest(variant=label, case=case):
        result = subprocess.run([str(self.binaries[label]), case], capture_output=True, text=True)
        expected = 1 if label == 'before' and case in BASELINE_FAIL else 0
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

  def test_original_reproduces_failures_and_preserves_controls(self):
    self.run_cases('before')

  def test_patch_fixes_all_cases(self):
    self.run_cases('fixed')


if __name__ == '__main__':
  unittest.main()
