#!/usr/bin/env python3
import subprocess
from tabulate import tabulate

# serial with timestamps:
# grabserial -d /dev/serial/by-id/usb-FTDI_FT230X* -t

# systemd-analyze critical-chain comma.service

# boot chart:
# systemd-analyze plot > /tmp/bootup.svg

def get_journal_time(x):
  out = subprocess.check_output("journalctl -x -o short-monotonic", shell=True, encoding='utf8')
  jlines = out.strip().splitlines()
  for l in jlines:
    if x in l:
      t = l.split('[')[1].split(']')[0]
      return float(t)
  return None

if __name__ == "__main__":
  ts = {
    "PON": 1.5,  # estimate from powering on to XBL

    # these are dumped over serial, use the ones from the XBL
    "XBL": 2.4,
    "ABL": 3.7,  # 3s of this is waiting for fastboot + factory reset tapping
  }
  def tot_since_kern():
    return sum(ts.values()) - (ts['PON'] + ts['XBL'] + ts['ABL'])

  out = subprocess.check_output("systemd-analyze", shell=True, encoding='utf8')
  l = out.splitlines()[0].split(' ')
  ts['kernel'] = float(l[3][:-1])
  #ts['systemd'] = float(l[6][:-1])

  ts['comma'] = get_journal_time("Started comma.service") - tot_since_kern()

  # print
  tot = 0
  total = sum(ts.values())
  tab = []
  for s, t in ts.items():
    tot += t
    tab.append([
      s,
      round(t, 2),
      round(tot, 2),
      str(round(t/total * 100)) + "%",
    ])

  # TODO: add openpilot time-to-onroad
  tab.append(['onroad', '?', '?', '-'])
  print(tabulate(tab))
