#!/usr/bin/python3
"""Read the volatile syslog buffer as text or JSON.

Only the text boot dump and JSON follow interfaces used by openpilot are
supported. Syslog does not preserve journal fields such as originating PID.
"""
import argparse
import datetime
import json
import re
import signal
import subprocess
import sys


def main():
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument('-f', '--follow', action='store_true')
  parser.add_argument('-b', action='store_true')
  parser.add_argument('-n', type=int)
  parser.add_argument('-o', choices=['json', 'short'], default='short')
  parser.add_argument('--no-pager', action='store_true')
  args = parser.parse_args()
  command = ['busybox', 'logread'] + (['-f'] if args.follow else [])
  proc = subprocess.Popen(command, stdout=subprocess.PIPE, text=True)
  try:
    lines = proc.stdout
    if args.n is not None and not args.follow:
      lines = list(lines)[-max(0, args.n):] if args.n else []
    for line in lines:
      if args.o == 'json':
        # BusyBox: "Oct 20 12:34:56 host daemon.info tag: message".
        match = re.match(r'(.{15}) (\S+) (\w+)\.(\w+) ([^:]+): ?(.*)', line.rstrip())
        entry = {'MESSAGE': line.rstrip()}
        if match:
          date, host, facility, level, tag, message = match.groups()
          now = datetime.datetime.now()
          timestamp = datetime.datetime.strptime(f'{now.year} {date}', '%Y %b %d %H:%M:%S')
          if timestamp > now + datetime.timedelta(days=1):
            timestamp = timestamp.replace(year=now.year - 1)
          entry.update(MESSAGE=message, SYSLOG_IDENTIFIER=tag, _HOSTNAME=host,
                       __REALTIME_TIMESTAMP=str(int(timestamp.timestamp() * 1e6)))
          level = {'warn': 'warning', 'error': 'err', 'panic': 'emerg'}.get(level, level)
          levels = ['emerg', 'alert', 'crit', 'err', 'warning', 'notice', 'info', 'debug']
          if level in levels:
            entry['PRIORITY'] = str(levels.index(level))
        print(json.dumps(entry), flush=True)
      else:
        print(line, end='', flush=True)
    return proc.wait()
  finally:
    if proc.poll() is None:
      proc.terminate()
    proc.wait()


if __name__ == '__main__':
  signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
  sys.exit(main())
