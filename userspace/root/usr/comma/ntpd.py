#!/usr/bin/env python3
"""Set time once per boot using SNTP; retry offline failures with bounded backoff."""
import argparse
import json
import math
import socket
import struct
import time

EPOCH = 2208988800
ERA = 2 ** 32


def stamp(value):
  whole = math.floor(value)
  return struct.pack('!II', whole % ERA, int((value - whole) * ERA))


def decode(raw, pivot):
  sec, frac = struct.unpack('!II', raw)
  value = sec + frac / ERA
  return value + round((pivot - value) / ERA) * ERA


def query(address, timeout, pivot):
  family, kind, proto, _, peer = address
  with socket.socket(family, kind, proto) as sock:
    sock.settimeout(timeout)
    sock.connect(peer)
    # Random opaque origin cookie avoids dependence on the local wall clock.
    import os
    cookie = os.urandom(8)
    packet = bytearray(48)
    packet[0] = 0x23
    packet[40:48] = cookie
    start = time.monotonic()
    sock.send(packet)
    reply = sock.recv(512)
    end = time.monotonic()
    if len(reply) < 48:
      raise ValueError('short response')
    flags, stratum = reply[:2]
    if flags >> 6 == 3 or (flags >> 3) & 7 not in (3, 4) or flags & 7 != 4:
      raise ValueError('invalid leap/version/mode')
    if not 1 <= stratum <= 15 or reply[24:32] != cookie:
      raise ValueError('invalid stratum/origin')
    if reply[32:40] == bytes(8) or reply[40:48] == bytes(8):
      raise ValueError('zero receive/transmit')
    transmit = decode(reply[40:48], pivot + EPOCH) - EPOCH
    receive = decode(reply[32:40], transmit + EPOCH) - EPOCH
    processing = transmit - receive
    elapsed = end - start
    if processing < 0 or processing > elapsed + 0.01:
      raise ValueError('invalid server processing interval')
    return transmit + max(0, elapsed - processing) / 2, end, elapsed


def resolve(host, port):
  return socket.getaddrinfo(host, port, type=socket.SOCK_DGRAM)


def run(args, setter=time.clock_settime):
  # Daemon DNS threads bound caller latency even if libc resolution stalls.
  import queue
  import threading
  results = queue.Queue()
  def worker(host):
    try:
      addresses = resolve(host, args.port)
      for address in addresses[:2]:
        try:
          results.put(query(address, args.timeout, args.era_pivot))
          return
        except (OSError, ValueError):
          pass
    except OSError:
      pass
  workers = {}
  backoff = args.retry
  while True:
    for host in args.servers:
      if host not in workers or not workers[host].is_alive():
        workers[host] = threading.Thread(target=worker, args=(host,), daemon=True)
        workers[host].start()
    deadline = time.monotonic() + args.timeout * 2
    while time.monotonic() < deadline:
      try:
        value, received, rtt = results.get(timeout=max(.001, deadline-time.monotonic()))
      except queue.Empty:
        break
      target = value + time.monotonic() - received
      try:
        if not args.dry_run:
          setter(time.CLOCK_REALTIME, target)
        print(json.dumps({'unix_time': target, 'rtt': rtt, 'dry_run': args.dry_run}), flush=True)
        return
      except OSError as error:
        print(str(error), flush=True)
    if args.once:
      raise SystemExit(1)
    time.sleep(backoff)
    backoff = min(args.max_retry, backoff * 2)


if __name__ == '__main__':
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument('servers', nargs='*', default=['time.cloudflare.com', 'time.google.com'])
  parser.add_argument('--port', type=int, default=123)
  parser.add_argument('--timeout', type=float, default=1)
  parser.add_argument('--retry', type=float, default=2)
  parser.add_argument('--max-retry', type=float, default=10)
  parser.add_argument('--era-pivot', type=float, default=1794355200, help='trusted approximate Unix date, within 68 years')
  parser.add_argument('--dry-run', action='store_true')
  parser.add_argument('--once', action='store_true', help='diagnostic: fail after one attempt')
  args = parser.parse_args()
  if not 0 < args.timeout <= 10 or not 0 < args.retry <= args.max_retry <= 60 or not 1 <= args.port <= 65535:
    parser.error('invalid timeout, retry interval, or port')
  run(args)
