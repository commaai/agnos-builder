import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPT=Path(__file__).resolve().parents[1]/'userspace/root/usr/comma/test_boot_resources.py'
spec=importlib.util.spec_from_file_location('boot_resources',SCRIPT)
probe=importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class TestSupervisor(unittest.TestCase):
  def run_fake(self, fault, profile='immediate'):
    children=[]
    commands=[]
    real_popen=subprocess.Popen
    def spawn(command, **kwargs):
      name=command[command.index('--probe')+1]
      output=command[command.index('--output')+1]
      gate=int(command[command.index('--gate-fd')+1])
      commands.append(command)
      code='import os,time,json; os.read('+str(gate)+',1); '
      if name=='gpu' and fault=='hang':
        code+='time.sleep(10)'
      elif name=='gpu' and fault=='missing':
        code+='pass'
      else:
        code+='open('+repr(output)+',"w").write(json.dumps({"ok":True}))'
      child=real_popen([command[0],'-c',code],**kwargs)
      children.append(child)
      return child
    with tempfile.TemporaryDirectory() as directory:
      options=dict(output=directory+'/result',profile=profile,iterations=1,timeout=.15,camera_timeout=.15,gpu_delay=.02)
      def systemctl(*args, **kwargs):return 'success' if 'Result' in args else '1'
      with patch.object(probe.subprocess,'Popen',spawn),patch.object(probe,'checked',systemctl),patch.object(probe,'collect_failure'):
        start=time.monotonic()
        result=probe.run_probes(options)
        self.assertLess(time.monotonic()-start,2)
      self.assertTrue(all(child.poll() is not None for child in children))
      self.assertEqual(json.loads((Path(options['output'])/'result.json').read_text())['ok'],result['ok'])
    return result,commands

  def test_hung_first_use_is_failure_and_is_killed(self):
    result,_=self.run_fake('hang')
    self.assertFalse(result['ok'])
    self.assertIn('exceeded',result['probes']['gpu']['error'])

  def test_successful_exit_without_result_is_not_a_pass(self):
    result,_=self.run_fake('missing')
    self.assertFalse(result['ok'])
    self.assertIn('without a valid result',result['probes']['gpu']['error'])

  def test_late_gpu_trial_has_no_early_graphics_consumer(self):
    result,commands=self.run_fake(None,'late-gpu')
    self.assertTrue(result['ok'])
    names=[c[c.index('--probe')+1] for c in commands]
    self.assertNotIn('drm',names)
    self.assertNotIn('camera',names)
    gpu=next(c for c in commands if c[c.index('--probe')+1]=='gpu')
    self.assertEqual(float(gpu[gpu.index('--delay')+1]),.02)


if __name__ == '__main__':
  unittest.main()
