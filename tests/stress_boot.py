#!/usr/bin/env python3
"""Run first-use resource probes on reserved UP rack devices, without test_onroad.

Pass one or more private JSON reservation responses from chestnut.comma.life.
The caller retains responsibility for renewing/releasing its reservations.
"""
import argparse
import concurrent.futures
import io
import json
from pathlib import Path
import shlex
import subprocess
import tarfile
import threading
import time
import uuid

SOURCE = Path(__file__).resolve().parents[1] / 'userspace/root/usr/comma'
DEVICE_ROOT = '/data/boot-resource-stress'
STOP = threading.Event()


class Remote:
  def __init__(self, reservation, output):
    self.name = reservation['devices'][0]
    self.ssh = shlex.split(reservation['ssh'][1])
    self.ssh[1:1] = ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2']
    self.output = output / self.name
    self.output.mkdir(parents=True, exist_ok=True)
    self.was_active = False
    self.installed = False
    self.run_id = uuid.uuid4().hex[:12]

  def command(self, command, data=None, timeout=20, check=True):
    # Station ADB keeps working when stopping comma removes DUT SSH access.
    remote = 'adb shell -T ' + shlex.quote(command)
    try:
      p = subprocess.run(self.ssh + [remote], input=data, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as e:
      if check:
        raise RuntimeError(f'{self.name}: remote command timed out') from None
      return subprocess.CompletedProcess([], 124, e.stdout or b'', e.stderr or b'')
    if check and p.returncode:
      # Keep transport diagnostics private; never put credential-bearing SSH argv in errors.
      (self.output / 'remote-error.log').write_bytes(p.stdout + p.stderr)
      raise RuntimeError(f'{self.name}: remote command failed ({p.returncode}); see remote-error.log')
    return p

  def user(self, command, **kwargs):
    return self.command('sudo -u comma bash -c ' + shlex.quote(command), **kwargs)

  def deploy(self):
    self.command('mkdir -p ' + DEVICE_ROOT + '; chown comma:comma ' + DEVICE_ROOT)
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode='w:gz') as t:
      t.add(SOURCE / 'test_boot_resources.py', arcname='test_boot_resources.py')
      for f in (SOURCE / 'boot_stress').glob('*.py'):
        t.add(f, arcname='boot_stress/' + f.name)
    self.user('tar -xzf - -C ' + DEVICE_ROOT, data=data.getvalue())
    self.was_active = self.command('systemctl is-active comma.service', check=False).stdout.strip() == b'active'
    self.command('systemctl stop comma.service')

  def configure(self, sequence, profile, args):
    output = f'{DEVICE_ROOT}/runs/{self.run_id}/{sequence}'
    config = dict(sequence=sequence, output=output, profile=profile, gpu_delay=args.gpu_delay,
                  iterations=args.iterations, duration=0.15, timeout=5, camera_timeout=10,
                  openpilot=args.openpilot, camera=args.camera)
    self.user('cat > ' + DEVICE_ROOT + '/config.json', data=json.dumps(config).encode())
    return output

  def collect(self, output, label):
    local = self.output / label
    local.mkdir(exist_ok=True)
    result = json.loads(self.command('cat ' + shlex.quote(output + '/result.json')).stdout)
    boot_result = self.command('systemctl show -P Result boot.service').stdout.decode().strip()
    result['boot_result'] = boot_result
    result['boot_finished_at'] = int(self.command(
      'systemctl show -P ExecMainExitTimestampMonotonic boot.service').stdout.strip()) / 1e6
    result['release_after_boot_seconds'] = result['released_at'] - result['boot_finished_at']
    result['ok'] = bool(result['ok'] and boot_result == 'success')
    (local / 'result.json').write_text(json.dumps(result, indent=2))
    archive = self.command('tar -czf - -C ' + shlex.quote(output) + ' .', timeout=30)
    (local / 'diagnostics.tgz').write_bytes(archive.stdout)
    return result

  def baseline(self, args, profile='immediate'):
    label = 'baseline-' + profile
    output = self.configure(label, profile, args)
    # Same user and limits as the boot hook. This validates consumers/API compatibility
    # on a settled device; a client contention failure here remains a real failure.
    command = ['systemd-run', '--wait', '--collect', '--unit=boot-resource-baseline', '--uid=comma',
               '--property=LimitRTPRIO=100', '--property=LimitNICE=-10',
               '/usr/comma/run_in_app_group.sh', '/usr/local/venv/bin/python', DEVICE_ROOT + '/test_boot_resources.py',
               'run', '--config', DEVICE_ROOT + '/config.json']
    self.command(shlex.join(command), check=False, timeout=35)
    result = self.collect(output, label)
    if not result['ok']:
      raise RuntimeError(f'{self.name}: settled baseline failed; inspect before interpreting boot failures')

  def install(self):
    self.installed = True  # uninstall also rolls back a partially installed hook.
    self.command('/usr/local/venv/bin/python ' + DEVICE_ROOT + '/test_boot_resources.py install --directory ' + DEVICE_ROOT)

  def boot(self, number, profile, args):
    label = f'{number:04d}'
    output = self.configure(label, profile, args)
    old = self.command('cat /proc/sys/kernel/random/boot_id').stdout.strip()
    self.command('sync; reboot', check=False, timeout=5)
    deadline = time.monotonic() + args.boot_timeout
    result = None
    while time.monotonic() < deadline:
      p = self.command('cat ' + shlex.quote(output + '/result.json'), check=False, timeout=3)
      if p.returncode == 0:
        candidate = json.loads(p.stdout)
        if candidate['boot_id'].encode() != old and candidate['sequence'] == label:
          result = self.collect(output, label)
          break
      time.sleep(0.25)
    if result is None:
      # A failed boot.sh never runs ExecStartPost. Keep this distinct from a probe failure.
      (self.output / (label + '-boot.log')).write_bytes(self.command(
        'systemctl show boot.service -p Result -p ActiveState; journalctl -b -u boot -u boot-resource-probe --no-pager',
        check=False).stdout)
      raise RuntimeError(f'{self.name}: no fresh result within {args.boot_timeout}s')
    if not result['ok']:
      raise RuntimeError(f'{self.name}: first-use resource failure at boot {number}')
    return result

  def cleanup(self):
    if self.installed:
      p = self.command('/usr/local/venv/bin/python ' + DEVICE_ROOT + '/test_boot_resources.py uninstall --directory ' + DEVICE_ROOT,
                       check=False, timeout=20)
      if p.returncode:
        (self.output / 'cleanup-error.log').write_bytes(p.stdout + p.stderr)
        raise RuntimeError(f'{self.name}: hook cleanup failed; reservation must be retained for recovery')
    if self.was_active:
      self.command('systemctl start comma.service')


def work(reservation, args):
  remote = Remote(reservation, args.output)
  result = dict(device=remote.name, passed=0, cleanup=False)
  try:
    remote.deploy()
    remote.baseline(args)
    if 'audio-clients' in args.profiles:
      remote.baseline(args, 'audio-clients')
    remote.install()
    for number in range(1, args.boots + 1):
      if STOP.is_set():
        break
      profile = args.profiles[(number - 1) % len(args.profiles)]
      record = remote.boot(number, profile, args)
      result['passed'] += 1
      print(json.dumps(dict(device=remote.name, boot=number, profile=profile, ok=True,
                            duration=record['finished_at'] - record['started_at'])), flush=True)
  except Exception as e:
    STOP.set()
    result['error'] = str(e)
    print(json.dumps(result), flush=True)
  finally:
    try:
      remote.cleanup()
      result['cleanup'] = True
    except Exception as e:
      STOP.set()
      result['cleanup_error'] = str(e)
    (remote.output / 'final.json').write_text(json.dumps(result, indent=2))
  return result


def main():
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument('--reservation', type=Path, action='append', required=True)
  parser.add_argument('--output', type=Path, required=True)
  parser.add_argument('--boots', type=int, default=20, help='per device; stop the fleet on first failure')
  parser.add_argument('--profiles', nargs='+', choices=['immediate', 'audio-clients', 'late-gpu'], default=['immediate', 'audio-clients', 'late-gpu'])
  parser.add_argument('--gpu-delay', type=float, default=6)
  parser.add_argument('--iterations', type=int, default=3, help='fresh concurrent audio input/output pairs per boot')
  parser.add_argument('--openpilot', help='built checkout on DUT, required for --camera')
  parser.add_argument('--camera', action='store_true', help='include first camera frames and hardware encoder packets')
  parser.add_argument('--boot-timeout', type=float, default=35)
  args = parser.parse_args()
  if args.boots < 1 or (args.camera and not args.openpilot):
    parser.error('positive --boots and --openpilot for --camera required')
  args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
  reservations = [json.loads(path.read_text()) for path in args.reservation]
  with concurrent.futures.ThreadPoolExecutor(max_workers=len(reservations)) as pool:
    results = list(pool.map(lambda r: work(r, args), reservations))
  (args.output / 'final.json').write_text(json.dumps(dict(failed=STOP.is_set(), devices=results), indent=2))
  return int(STOP.is_set())


if __name__ == '__main__':
  raise SystemExit(main())
