#!/usr/bin/env python3
import json
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

def test_color_calibration():
  out = subprocess.check_output("journalctl -u weston", shell=True, encoding='utf8')
  assert out.count("Successfully setup color correction") == 3

def test_python_shims():
  subprocess.check_call("cd /data/openpilot && scons -h", shell=True, stdout=subprocess.DEVNULL)

def test_dmesg():
  # TODO: ensure no new errors in dmesg. would catch things like the brightness setting bug
  pass

def test_systemd_services():
  pass

def test_boot_time():
  out = subprocess.check_output("systemd-analyze", shell=True, encoding='utf8')

  a = out.splitlines()[0]
  print(out, a)

  # check weston service

  # check comma service

