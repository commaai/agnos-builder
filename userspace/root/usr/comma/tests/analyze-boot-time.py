#!/usr/bin/env python3
import subprocess
import re
from tabulate import tabulate

# serial with timestamps:
# grabserial -d /dev/serial/by-id/usb-FTDI_FT230X* -t

def get_bootsh_time(x):
  out = subprocess.check_output("dmesg | grep 'boot.sh'", shell=True, encoding='utf8')
  for line in out.strip().splitlines():
    if x in line:
      m = re.search(r"boot\.sh\[\d+\]: ([0-9.]+)", line)
      if m:
        return float(m.group(1))
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

  ts['kernel-to-pid1'] = get_bootsh_time("pid1 start") or 0.0
  ts['comma'] = (get_bootsh_time("comma launched") or 0.0) - ts['kernel-to-pid1']

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
