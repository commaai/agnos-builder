#!/usr/bin/env python3

import os
import re
import argparse

RED = '\033[91m'
GREEN = '\033[92m'
YELLOW = '\033[93m'
ENDC = '\033[0m'

def split_line(l):
  try:
    parts = l.split('] ')
    ts = float(parts[0][1:])
    line = '] '.join(parts[1:])
    return ts, line
  except ValueError:
    return None, l

def find_matching_idx(lines, line, disable_known_mismatches):
  def cleanup(l):
    if disable_known_mismatches:
      return l

    if 'wlan:' in l:
      l = re.sub(r'\[\d+\]', '', l)
      l = re.sub(r'\[\d+:\d+:\d+\.\d+\]', '', l)
      l = re.sub(r'\[\d+:', '', l)
      l = re.sub(r'\[kworker/u16:\d', '', l)

    return l

  for i, l in enumerate(lines):
    if cleanup(line) in cleanup(l):
      return i
  return None

def print_columns(l1, l2):
  c1 = RED if len(l2) == 0 else ENDC
  c2 = GREEN if len(l1) == 0 else ENDC

  col_width = (os.get_terminal_size().columns // 2) - 4
  print(f"{c1}{l1[:col_width]:<{col_width}} {YELLOW}|{ENDC} {c2}{l2[:col_width]:<{col_width}}{ENDC}")

if __name__ == "__main__":
  parser = argparse.ArgumentParser(description='Compare two dmesg files')
  parser.add_argument('file1', help='first dmesg file')
  parser.add_argument('file2', help='second dmesg file')
  parser.add_argument('--only-diff', action='store_true', help='only show lines that differ')
  parser.add_argument('--disable-known-mismatches', action='store_true', help='disable known mismatches (such as timestamps in messages)')
  args = parser.parse_args()

  with open(args.file1) as f1, open(args.file2) as f2:
    lines1 = f1.readlines()
    lines2 = f2.readlines()

  while len(lines1) > 0 and len(lines2) > 0:
    ts1, line1 = split_line(lines1[0])
    ts2, line2 = split_line(lines2[0])

    if ts1 is None:
      print_columns(lines1[0].strip(), "")
      lines1.pop(0)
    elif ts2 is None:
      print_columns(lines2[0].strip(), "")
      lines2.pop(0)
    elif ts1 <= ts2:
      idx = find_matching_idx(lines2, line1, args.disable_known_mismatches)
      if idx is not None:
        if not args.only_diff:
          print_columns(lines1[0].strip(), lines2[idx].strip())
        lines1.pop(0)
        lines2.pop(idx)
      else:
        print_columns(lines1[0].strip(), "")
        lines1.pop(0)
    else:
      idx = find_matching_idx(lines1, line2, args.disable_known_mismatches)
      if idx is not None:
        if not args.only_diff:
          print_columns(lines1[idx].strip(), lines2[0].strip())
        lines1.pop(idx)
        lines2.pop(0)
      else:
        print_columns("", lines2[0].strip())
        lines2.pop(0)
