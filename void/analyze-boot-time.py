#!/usr/bin/env python3
"""Analyze boot time on AGNOS (works on both Ubuntu/systemd and Void/runit).

Data sources:
  - dmesg: KPI counters from Qualcomm IMEM (bootloader timing via MPM clock)
  - dmesg: monotonic timestamps for kernel/hardware milestones
  - systemd: journalctl -o short-monotonic (Ubuntu)
  - rsyslog: /var/log/messages (Void — first kernel message timestamp used as
    reference for dmesg time 0, all service timestamps converted relative to that)
"""
import os
import re
import subprocess
import sys


def run(cmd):
  return subprocess.check_output(cmd, shell=True, encoding='utf8').strip()


def is_systemd():
  return os.path.exists("/run/systemd/system")


def parse_dmesg():
  """Parse dmesg for KPI counters and key milestones."""
  dmesg = run("dmesg")
  kpi = {}
  milestones = {}

  for line in dmesg.splitlines():
    m = re.match(r'\[\s*([\d.]+)\]', line)
    if not m:
      continue
    ts = float(m.group(1))

    # Qualcomm KPI counters from IMEM boot_stats
    if 'KPI: Bootloader start count' in line:
      kpi['bl_start'] = int(line.split('=')[1])
    elif 'KPI: Bootloader end count' in line:
      kpi['bl_end'] = int(line.split('=')[1])
    elif 'KPI: Bootloader load kernel count' in line:
      kpi['bl_load_kernel'] = int(line.split('=')[1])
    elif 'KPI: Kernel MPM timestamp' in line:
      kpi['kernel_mpm'] = int(line.split('=')[1])
    elif 'KPI: Kernel MPM Clock frequency' in line:
      kpi['mpm_freq'] = int(line.split('=')[1])

    # Kernel milestones (first match wins)
    checks = [
      ('rootfs_mount', 'VFS: Mounted root'),
      ('freeing_init', 'Freeing unused kernel memory'),
      ('udevd', 'udevd['),
      ('ipa_fws', "ipa_fws: Brought out of reset"),
      ('cdsp', "cdsp: Brought out of reset"),
      ('adsp', "adsp: Brought out of reset"),
      ('modem', "modem: Brought out of reset"),
      ('wlan', "wlan: driver loaded"),
    ]
    for key, pattern in checks:
      if key not in milestones and pattern in line:
        milestones[key] = ts

  return kpi, milestones


def parse_systemd_services(kern_offset):
  """Parse journalctl for service milestones (Ubuntu/systemd)."""
  try:
    out = run("journalctl -x -o short-monotonic")
  except subprocess.CalledProcessError:
    return {}

  services = {}
  checks = [
    ('sshd', 'sshd', 'Accepted\\|Server listening'),
    ('comma_start', 'comma service', 'Starting comma.service'),
    ('comma_done', 'comma finished', 'Finished comma.service'),
    ('multi_user', 'multi-user target', 'Reached target multi-user.target'),
  ]

  for line in out.splitlines():
    m = re.search(r'\[\s*([\d.]+)\]', line)
    if not m:
      continue
    ts = float(m.group(1))

    for key, label, pattern in checks:
      if key not in services and re.search(pattern, line):
        services[key] = (label, ts + kern_offset)

  return services


def parse_runit_services(kern_offset):
  """Placeholder — runit service timestamps not reliably measurable.

  rsyslog starts after services, so its timestamps for sshd/comma/etc
  all cluster at rsyslog's own start time rather than actual service start.
  Would need /dev/kmsg markers in run scripts for accurate measurement.
  """
  return {}


def main():
  kpi, milestones = parse_dmesg()
  freq = kpi.get('mpm_freq', 32768)
  kern_offset = kpi.get('kernel_mpm', 0) / freq if 'kernel_mpm' in kpi else 0

  # Build timeline
  timeline = []

  # Bootloader phase (from KPI counters)
  if 'bl_start' in kpi:
    timeline.append(('XBL start', kpi['bl_start'] / freq))
  if 'bl_end' in kpi:
    timeline.append(('ABL end', kpi['bl_end'] / freq))
  if 'kernel_mpm' in kpi:
    timeline.append(('kernel entry', kern_offset))

  # Kernel milestones (same on both systems)
  milestone_labels = {
    'rootfs_mount': 'rootfs mounted',
    'freeing_init': 'userspace start',
    'udevd': 'udevd started',
    'ipa_fws': 'IPA firmware',
    'cdsp': 'CDSP ready',
    'adsp': 'ADSP ready',
    'modem': 'modem ready',
    'wlan': 'WLAN loaded',
  }
  for key, label in milestone_labels.items():
    if key in milestones:
      timeline.append((label, milestones[key] + kern_offset))

  # Service milestones (init-system specific)
  if is_systemd():
    services = parse_systemd_services(kern_offset)
  else:
    services = parse_runit_services(kern_offset)

  for key, (label, ts) in services.items():
    timeline.append((label, ts))

  if not timeline:
    print("No boot data found")
    sys.exit(1)

  # Sort and print
  timeline.sort(key=lambda x: x[1])

  init_name = "systemd" if is_systemd() else "runit"
  print(f"AGNOS boot analysis ({init_name})")
  print()
  print(f"{'Phase':<25} {'Time':>8} {'Delta':>8} {'%':>5}")
  print("-" * 50)
  prev = 0
  total = timeline[-1][1]
  for label, ts in timeline:
    delta = ts - prev
    pct = ts / total * 100 if total > 0 else 0
    print(f"{label:<25} {ts:>7.2f}s {delta:>+7.2f}s {pct:>4.0f}%")
    prev = ts

  print("-" * 50)
  print(f"{'TOTAL':<25} {total:>7.2f}s")


if __name__ == "__main__":
  main()
