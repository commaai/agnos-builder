#!/usr/bin/env python3
import subprocess
from tabulate import tabulate

# serial with timestamps:
# grabserial -d /dev/serial/by-id/usb-FTDI_FT230X* -t

# systemd-analyze critical-chain weston-ready.service
# systemd-analyze critical-chain comma.service

if __name__ == "__main__":
  ts = {
    # these are dumped over serial, use the ones from the XBL
    "XBL": 2.4,
    "ABL": 3.7,  # 3s of this is waiting for fastboot + factory reset tapping
  }

  out = subprocess.check_output("systemd-analyze", shell=True, encoding='utf8')
  l = out.splitlines()[0].split(' ')
  ts['kernel'] = float(l[3][:-1])
  ts['graphical.target'] = float(l[6][:-1])

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
  print(tabulate(tab))
