import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'userspace/root/usr/comma/boot.sh').read_text().split('\nrun_init mount_dsp')[0]


def run_fixture(tmp_path, commands):
  source = SOURCE.replace('/run/comma-init-', str(tmp_path / 'init-'))
  subprocess.run(['bash', '-eu', '-c', source + '\n' + commands], check=True, cwd=tmp_path)


def test_successful_jobs_not_repeated(tmp_path):
  run_fixture(tmp_path, '''
function fixture { echo run >> calls; }
run_init fixture
wait "${PIDS[-1]}"
run_init fixture
[ "$(wc -l < calls)" = 1 ]
''')


def test_failed_jobs_retry(tmp_path):
  run_fixture(tmp_path, '''
function fixture { test -e ready; }
run_init fixture
if wait "${PIDS[-1]}"; then exit 1; fi
touch ready
run_init fixture
wait "${PIDS[-1]}"
''')


def test_existing_mounts_checked_without_replacement(tmp_path):
  run_fixture(tmp_path, '''
function part_dev { echo /dev/fixture; }
function mountpoint { return 0; }
function findmnt { case "${*: -1}" in SOURCE) echo /dev/fixture;; FSTYPE) echo tmpfs;; esac; }
function mount { echo unexpected-mount; return 1; }
mount_part userdata /data
mount_tmpfs /tmp -o mode=1777
function findmnt { echo /dev/wrong; }
if mount_part userdata /data; then exit 1; fi
if mount_tmpfs /tmp; then exit 1; fi
''')


def test_mounted_userdata_retry_preserves_live_files(tmp_path):
  data = tmp_path / 'data'
  (data / 'tmp').mkdir(parents=True)
  sentinel = data / 'tmp' / 'live-socket'
  sentinel.write_text('keep')
  source = SOURCE.replace('/data', str(data))
  commands = '''
function mountpoint { return 0; }
function part_dev { echo /dev/fixture; }
function findmnt { echo /dev/fixture; }
function chown { :; }
function rm { echo unexpected-cleanup >&2; return 1; }
mount_data
'''
  subprocess.run(['bash', '-eu', '-c', source + '\n' + commands], check=True)
  assert sentinel.read_text() == 'keep'
