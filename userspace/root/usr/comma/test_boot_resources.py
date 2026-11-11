#!/usr/local/venv/bin/python
"""First-use boot resource probes. Install only on reserved test devices."""
import argparse
import hashlib
import importlib
import json
import os
import pwd
from pathlib import Path
import signal
import subprocess
import sys
import time
import traceback

MODULES = {'audio': 'audio', 'gpu': 'platform', 'drm': 'platform', 'filesystem': 'platform', 'devices': 'platform', 'camera': 'camera'}
HOOK = Path('/etc/systemd/system/boot.service.d/95-resource-stress.conf')
APP_HOOK = Path('/etc/systemd/system/comma.service.d/95-resource-stress.conf')
UNIT = 'boot-resource-probe'


def atomic_json(path, value):
  path = Path(path)
  path.parent.mkdir(parents=True, exist_ok=True)
  tmp = path.with_suffix('.tmp')
  tmp.write_text(json.dumps(value, indent=2))
  tmp.replace(path)


def checked(*args, **kwargs):
  return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout.strip()


def worker(args):
  options = json.loads(Path(args.options).read_text())
  options['artifact_dir'] = str(Path(args.output).parent / (args.probe + '-artifacts'))
  Path(options['artifact_dir']).mkdir(exist_ok=True)
  if args.gate_fd is not None:
    os.read(args.gate_fd, 1)
    os.close(args.gate_fd)
  time.sleep(args.delay)
  result = dict(probe=args.probe, pid=os.getpid(), attempted_at=time.monotonic(),
                affinity=sorted(os.sched_getaffinity(0)), cgroup=Path('/proc/self/cgroup').read_text())
  try:
    if os.geteuid() != pwd.getpwnam('comma').pw_uid:
      raise PermissionError('resource probes must run as comma, not root')
    if any('cpuset' in row.split(':')[1].split(',') and row.split(':')[2].strip() == '/background'
           for row in result['cgroup'].splitlines()):
      raise RuntimeError('probe stayed in the background CPU group; use run_in_app_group.sh')
    # Import only this worker's module, after the delay. In particular, do not
    # warm GPU/PortAudio while the coordinator or another probe starts.
    module = importlib.import_module('boot_stress.' + MODULES[args.probe])
    details = module.run(options | {'probe': args.probe})
    result.update(ok=details.get('ok', True), details=details)
  except Exception:
    result.update(ok=False, error=traceback.format_exc())
  result['finished_at'] = time.monotonic()
  atomic_json(args.output, result)
  return 0 if result['ok'] else 1


def diagnostics(args):
  result = {'at': time.monotonic(), 'tasks': []}
  for pid in args.pids:
    for task in Path(f'/proc/{pid}/task').glob('*'):
      row = {'pid': pid, 'tid': int(task.name)}
      for name in ['comm', 'stack', 'wchan', 'syscall', 'status']:
        try:
          row[name] = (task / name).read_text()
        except OSError as e:
          row[name] = str(e)
      result['tasks'].append(row)
  atomic_json(args.output, result)
  return 0


def kill_group(process):
  # The worker can exit before a native child. Its process group still owns
  # those children, so cleanup must not depend on the worker remaining alive.
  try:
    os.killpg(process.pid, signal.SIGKILL)
  except ProcessLookupError:
    pass
  try:
    process.wait(timeout=0.2)
  except subprocess.TimeoutExpired:
    pass  # A task stuck in the kernel is recorded, never waited on indefinitely.


def collect_failure(out, processes):
  pids = [p.pid for p in processes]
  try:
    subprocess.run(['sudo', '-n', sys.executable, str(Path(__file__).resolve()), 'diagnostics',
                    '--output', str(out / 'kernel-waits.json'), *map(str, pids)],
                   capture_output=True, timeout=2)
  except (OSError, subprocess.TimeoutExpired):
    pass
  for name, command in [('dmesg', ['sudo', '-n', 'dmesg']),
                        ('journal', ['journalctl', '-b', '--no-pager', '-o', 'short-monotonic'])]:
    try:
      p = subprocess.run(command, capture_output=True, timeout=2)
      (out / (name + '.log')).write_bytes(p.stdout + p.stderr)
    except (OSError, subprocess.TimeoutExpired) as e:
      (out / (name + '.log')).write_text(str(e))


def run_probes(options):
  options = options | {'audio_mode': 'portaudio' if options['profile'] == 'audio-clients' else 'raw'}
  out = Path(options['output'])
  out.mkdir(parents=True, exist_ok=False)
  result = dict(boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                started_at=time.monotonic(), sequence=options.get('sequence'), profile=options['profile'], probes={})
  probes = ['audio', 'gpu', 'filesystem', 'devices']
  if options['profile'] != 'late-gpu':
    probes.append('drm')
    if options.get('camera'):
      if not options.get('openpilot'):
        raise ValueError('camera probe requires --openpilot')
      probes.append('camera')
  # A late GPU first use needs its own boot. Never run a preliminary GPU probe
  # (or a camera/rendering consumer which could warm it) in this profile.
  gpu_delay = options.get('gpu_delay', 6.0) if options['profile'] == 'late-gpu' else 0
  options_path = out / 'options.json'
  atomic_json(options_path, options)
  read_gate, write_gate = os.pipe()
  processes = {}
  files = []
  try:
    for name in probes:
      output = out / (name + '.json')
      log = (out / (name + '.log')).open('wb')
      files.append(log)
      delay = gpu_delay if name == 'gpu' else 0
      command = [sys.executable, str(Path(__file__).resolve()), 'worker', '--probe', name,
                 '--options', str(options_path), '--output', str(output), '--gate-fd', str(read_gate), '--delay', str(delay)]
      p = subprocess.Popen(command, stdout=log, stderr=log, pass_fds=(read_gate,), start_new_session=True)
      limit = options.get('camera_timeout', 10.0) if name == 'camera' else options.get('timeout', 5.0)
      if name == 'audio':
        limit = max(8, options['iterations'] * options.get('audio_timeout', 5) + 2) if options['audio_mode'] == 'portaudio' else limit
      processes[name] = (p, output, delay + limit)
    result['released_at'] = time.monotonic()
    os.close(write_gate)
    write_gate = None
    os.close(read_gate)
    read_gate = None
    # Read boot timing after releasing consumers, not before their first use.
    try:
      result['boot_finished_at'] = int(checked('systemctl', 'show', '-P', 'ExecMainExitTimestampMonotonic', 'boot.service', timeout=1)) / 1e6
      result['boot_result'] = checked('systemctl', 'show', '-P', 'Result', 'boot.service', timeout=1)
    except (ValueError, OSError, subprocess.SubprocessError):
      result['boot_finished_at'] = None
    pending = set(probes)
    while pending:
      for name in list(pending):
        p, output, limit = processes[name]
        if p.poll() is not None:
          try:
            record = json.loads(output.read_text())
            record['ok'] = bool(record['ok'] and p.returncode == 0)
          except (OSError, ValueError, KeyError) as e:
            record = dict(ok=False, error=f'worker exited {p.returncode} without a valid result: {e}')
          result['probes'][name] = record
          pending.remove(name)
        elif time.monotonic() - result['released_at'] > limit:
          result['probes'][name] = dict(ok=False, error=f'first use exceeded {limit}s including scheduled delay', pid=p.pid)
          pending.remove(name)
        if name in result['probes'] and not result['probes'][name]['ok']:
          collect_failure(out, [x[0] for x in processes.values()])
          for other in pending:
            result['probes'][other] = dict(ok=False, cancelled=True, error='cancelled after peer failure')
          pending.clear()
          break
      if pending:
        time.sleep(0.005)
    # Non-root systemctl may need dbus.socket, which starts after local-fs.
    # The host verifies boot.service's result as root after collecting this run.
    result['ok'] = all(p['ok'] for p in result['probes'].values()) and result.get('boot_result') in (None, 'success')
  finally:
    for p, _, _ in processes.values():
      kill_group(p)
    for fd in [read_gate, write_gate]:
      if fd is not None:
        os.close(fd)
    for f in files:
      f.close()
    result['finished_at'] = time.monotonic()
    result.setdefault('ok', False)
    atomic_json(out / 'result.json', result)
  return result


def install(args):
  if os.geteuid() != 0:
    raise PermissionError('install/uninstall requires root')
  directory = Path(args.directory).resolve()
  marker = directory / 'installation.json'
  if args.command == 'install':
    if HOOK.exists() or APP_HOOK.exists() or marker.exists():
      raise FileExistsError('resource stress is already installed; remove it before replacing it')
    directory.mkdir(parents=True, exist_ok=True)
    command = ['systemd-run', '--no-block', '--collect', '--unit=' + UNIT,
               '--property=DefaultDependencies=no', '--property=After=boot.service', '--property=Slice=app.slice',
               '--property=LimitRTPRIO=100', '--property=LimitNICE=-10', '--property=RuntimeMaxSec=35',
               '--property=TimeoutStopSec=2', '--uid=comma', '/usr/comma/run_in_app_group.sh', sys.executable, str(Path(__file__).resolve()),
               'run', '--config', str(directory / 'config.json')]
    # systemd command-line quoting, including its percent specifier expansion.
    import shlex
    hook = '[Service]\nExecStartPost=' + shlex.join([x.replace('%', '%%') for x in command]) + '\n'
    app_hook = '[Service]\nExecStart=\nExecStart=/bin/true\nExecStop=\nExecStop=/bin/true\n'
    user = pwd.getpwnam('comma')
    os.chown(directory, user.pw_uid, user.pw_gid)
    was_active = subprocess.run(['systemctl', 'is-active', 'comma.service'], capture_output=True, text=True).stdout.strip() == 'active'
    atomic_json(marker, dict(script=str(Path(__file__).resolve()), was_active=was_active,
                            hooks={str(HOOK): hashlib.sha256(hook.encode()).hexdigest(),
                                   str(APP_HOOK): hashlib.sha256(app_hook.encode()).hexdigest()}))
    checked('systemctl', 'stop', 'comma.service', timeout=5)
    checked('mount', '-o', 'remount,rw', '/')
    try:
      for path, data in [(HOOK, hook), (APP_HOOK, app_hook)]:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data)
    finally:
      checked('mount', '-o', 'remount,ro', '/')
    checked('systemctl', 'daemon-reload')
  else:
    if not marker.exists():
      raise FileNotFoundError('no installation record; refusing to remove unrelated configuration')
    installed = json.loads(marker.read_text())
    paths = [path for path in [HOOK, APP_HOOK] if path.exists()]
    for path in paths:
      if hashlib.sha256(path.read_bytes()).hexdigest() != installed['hooks'].get(str(path)):
        raise RuntimeError(f'{path} changed since installation; refusing to remove it')
    if paths:
      checked('mount', '-o', 'remount,rw', '/')
      try:
        for path in paths:
          path.unlink()
      finally:
        checked('mount', '-o', 'remount,ro', '/')
    checked('systemctl', 'daemon-reload')
    subprocess.run(['systemctl', 'stop', UNIT], capture_output=True, timeout=5)
    marker.unlink()
    if installed['was_active']:
      checked('systemctl', 'start', 'comma.service', timeout=5)
  return 0


def main():
  parser = argparse.ArgumentParser(description=__doc__)
  sub = parser.add_subparsers(dest='command', required=True)
  run = sub.add_parser('run')
  run.add_argument('--config', type=Path)
  run.add_argument('--output', type=Path)
  run.add_argument('--profile', choices=['immediate', 'audio-clients', 'late-gpu'], default='immediate')
  run.add_argument('--gpu-delay', type=float, default=6)
  run.add_argument('--iterations', type=int, default=3)
  run.add_argument('--duration', type=float, default=0.15)
  run.add_argument('--openpilot')
  run.add_argument('--camera', action='store_true')
  run.add_argument('--timeout', type=float, default=5)
  run.add_argument('--camera-timeout', type=float, default=10)
  child = sub.add_parser('worker')
  child.add_argument('--probe', choices=MODULES, required=True)
  child.add_argument('--options', required=True)
  child.add_argument('--output', required=True)
  child.add_argument('--gate-fd', type=int)
  child.add_argument('--delay', type=float, default=0)
  diag = sub.add_parser('diagnostics')
  diag.add_argument('--output', required=True)
  diag.add_argument('pids', nargs='+', type=int)
  for action in ['install', 'uninstall']:
    p = sub.add_parser(action)
    p.add_argument('--directory', default='/data/boot-resource-stress')
  args = parser.parse_args()
  if args.command == 'worker':
    return worker(args)
  if args.command == 'diagnostics':
    return diagnostics(args)
  if args.command in ('install', 'uninstall'):
    return install(args)
  options = vars(args).copy()
  if args.config:
    options.update(json.loads(args.config.read_text()))
  options.pop('config', None)
  options.pop('command', None)
  if not options.get('output'):
    parser.error('run needs --output or a config containing output')
  options['output'] = str(options['output'])
  if (options['profile'] not in ('immediate', 'audio-clients', 'late-gpu') or not 1 <= options['iterations'] <= 10 or
      not 0 <= options['gpu_delay'] <= 10 or not 0 < options['duration'] <= 0.5 or
      not 0 < options['timeout'] <= 10 or not 0 < options['camera_timeout'] <= 15):
    parser.error('invalid resource stress configuration')
  return 0 if run_probes(options)['ok'] else 1


if __name__ == '__main__':
  raise SystemExit(main())
