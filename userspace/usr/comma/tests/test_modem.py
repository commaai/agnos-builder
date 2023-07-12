#!/usr/bin/env python3
import os
import json
import subprocess
import time

def mmcli(cmd):
  try:
    out = subprocess.check_output(["mmcli", "-J", *cmd])
    return json.loads(out)
  except Exception as e:
    raise Exception(f"modem command failed: {cmd}") from e

def test_modem():
  # wait for the modem to come back up after flashing
  n = 0
  cnt = 0
  while n == 0:
    n = len(mmcli(["-L"])['modem-list'])
    if n > 1:
      raise Exception(f"Wrong number of modems ({n})")

    cnt += 1
    if cnt > 100:
      raise Exception("Modem never came up")

    time.sleep(1)

  cnt = 0
  while True:
    modem = mmcli(["-m", "any"])
    if modem['modem']['generic']['sim'] != '--':
      break

    cnt += 1
    if cnt > 100:
      raise Exception("SIM missing")

    time.sleep(1)

  # force to LTE
  #os.system("mmcli -m any --set-allowed-modes='4g'")

  # set initial eps bearer apn
  #sim_id = mmcli(['-i', '0'])['sim']['properties']['iccid']
  #if sim_id.startswith('8901410'):
  #  os.system('mmcli -m any --3gpp-set-initial-eps-bearer-settings="apn=Broadband"')

  print("waiting for cell connection")
  time.sleep(7)

  expected = [
    # key, expected value, error msg
    (['generic', 'manufacturer'], "QUALCOMM INCORPORATED", "Modem: wrong manufacturer"),
    (['generic', 'model'], "QUECTEL Mobile Broadband Module", "Modem: wrong model"),
    (['generic', 'revision'], "EG25GGBR07A08M2G", "Modem: wrong revision"),
    (['generic', 'carrier-configuration'], ["VoLTE-ATT", "Commercial-TMO_VoLTE"], "Modem: wrong carrier configuration"),
    (['generic', 'carrier-configuration-revision'], ["0501033C", "05010505"], "Modem: wrong carrier configuration revision"),

    (['generic', 'supported-capabilities'], [['gsm-umts, lte'], ], "Modem: wrong capabilities"),
    (['3gpp', 'operator-name'], ["--", "AT&T", "T-Mobile"], "Modem: wrong operator"),
  ]
  for key, val, err_msg in expected:
    v = modem['modem']
    for k in key:
      v = v.get(k)
    if isinstance(val, list):
      assert v in val, f"{err_msg} ({v})"
    else:
      assert v == val, f"{err_msg} ({v})"

  os.system("date >> /data/tmp/modem_log")
  os.system("sudo su -c 'tail /data/tmp/modem_log > /dev/console'")
  os.system("sudo su -c 'wc -l /data/tmp/modem_log > /dev/console'")
  os.sync()

  time.sleep(2)
  os.system("sudo reboot")

if __name__ == "__main__":
  test_modem()
