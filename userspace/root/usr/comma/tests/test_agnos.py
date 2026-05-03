#!/usr/bin/env python3
import json
import re
import time
import subprocess

def run(cmd):
  return subprocess.check_output(cmd, shell=True, encoding='utf8')


def test_setup():
  # TODO: write some real unit tests for this
  proc = subprocess.Popen('/usr/comma/setup', shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
  time.sleep(5)
  assert proc.poll() is None
  proc.terminate()

def test_reset():
  proc = subprocess.Popen('/usr/comma/reset', shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
  time.sleep(5)
  assert proc.poll() is None
  proc.terminate()

def test_modem():
  out = run("mmcli -m 0 --output-json")
  mm = json.loads(out)
  from pprint import pprint
  pprint(mm)

  # modem is up
  g = mm['modem']['generic']
  assert g['manufacturer'] == 'QUALCOMM INCORPORATED'
  assert g['model'] == 'QUECTEL Mobile Broadband Module'
  assert g['revision'] == 'EG25GGBR07A08M2G'

  # sim is present
  assert g['sim'] == '/org/freedesktop/ModemManager1/SIM/0'

  # blue prime is active
  out = run("nmcli con show --active")
  assert "blue-prime" in out

def test_wifi():
  out = run("nmcli dev wifi")
  networks = out.strip().splitlines()[1:]
  assert len(networks) > 5

def test_python_shims():
  subprocess.check_call("cd /data/openpilot && scons -h", shell=True, stdout=subprocess.DEVNULL)

def test_dmesg():
  # TODO: ensure no new errors in dmesg. would catch things like the brightness setting bug
  pass

def test_runit_services():
  assert run("cat /proc/1/comm").strip() == "runit"
  assert run("pgrep -a 'systemd|journald|udevd' || true").strip() == ""

  out = run("sv status /run/runit/services/*")
  failed = [line for line in out.splitlines() if not line.startswith("run:")]
  assert failed == []

def test_boot_time():
  out = run("dmesg | grep 'boot.sh'")
  marks = {}
  for line in out.splitlines():
    m = re.search(r"boot\.sh\[\d+\]: ([0-9.]+) (.*)", line)
    if m:
      marks[m.group(2)] = float(m.group(1))

  assert "comma launched" in marks
  print(marks)
