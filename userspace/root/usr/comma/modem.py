#!/usr/bin/env python3
# Source: commaai/openpilot@6b592ae2ccf68d1b3b89a8c544b12ecb074f3a8f
# openpilot/common/hardware/comma/modem.py; Webbing ICCID prefix inlined.
# Copyright (c) 2018, Comma.ai, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
import fcntl
import glob
import json
import logging
import os
import random
import select
import signal
import socket
import string
import struct
import subprocess
import tempfile
import termios
import time

from contextlib import contextmanager
from ipaddress import IPv4Address, IPv4Network, AddressValueError

from enum import Enum

WEBBING_ICCID_PREFIX = "8985235"

logging.basicConfig(
  level=logging.INFO,
  format="%(asctime)s.%(msecs)03d %(levelname)-7s modem: %(message)s",
  datefmt="%H:%M:%S",
)

# links to whichever ports answer AT, see _sync_ports
AT_PORT = "/dev/modem_at0"
PPP_PORT = "/dev/modem_at1"
STATE_PATH = "/dev/shm/modem"
AT_LOCK = "/dev/shm/modem.lock"  # shared with LPA
AT_INIT = [
  "ATE0",       # disable command echo
  "ATV1",       # verbose result codes (CONNECT/BUSY/NO CARRIER, not numeric)
  "AT+CMEE=1",  # numeric +CME ERROR codes on failures (per 3GPP 27.007)
  "ATX4",       # extended result codes: busy + dial tone detection, line speed in CONNECT
  "AT&C1",      # DCD pin follows carrier state (V.250 default)
  "AT+CREG=2",  # registration URCs include location info
  "AT+CGREG=2", # GPRS registration URCs include location info
]
CREG = {0: "not_registered", 1: "home", 2: "searching", 3: "denied", 4: "unknown", 5: "roaming"}
# 3GPP TS 27.007 +COPS <AcT> -> network type
NETWORK_TYPE = {0: "gsm", 1: "gsm", 3: "gsm", 8: "gsm",
                2: "utran", 4: "utran", 5: "utran", 6: "utran",
                7: "lte", 9: "lte", 10: "lte",
                11: "nr", 12: "nr", 13: "nr"}

DIAL_CID = 1

# comma four's EG916Q also has a USB Ethernet (ECM) interface. Its data call survives the modem's USB link suspending,
# PPP's doesn't, so with ECM the link, the SoC's USB and the modem (AT+QSCLK=1) can sleep while LTE stays up, see UsbPower
ECM_IFACE = "wwan0"
# every AT exchange wakes the link: once connected, poll the modem only this often, and while it sleeps, only when
# something else woke it, unless that's been ECM_POLL_MAX_DELAY
ECM_POLL_INTERVAL = 30.0
ECM_POLL_MAX_DELAY = 120.0
ECM_SEARCH_POLL_INTERVAL = 5.0

PPPD_CMD = [
  "sudo", "pppd", PPP_PORT, "460800", "noauth", "nodetach", "noipdefault", "usepeerdns",
  "nodefaultroute", "connect",
  "/usr/sbin/chat -v ABORT 'NO CARRIER' ABORT 'NO DIALTONE' ABORT 'BUSY' " +
  f"ABORT 'NO ANSWER' ABORT 'ERROR' TIMEOUT 5 '' AT OK ATD*99***{DIAL_CID}# CONNECT ''",
  "lcp-echo-interval", "30", "lcp-echo-failure", "4", "mtu", "1500", "mru", "1500",
  "novj", "novjccomp", "ipcp-accept-local", "ipcp-accept-remote", "nomagic",
  "user", '""', "password", '""',
]
INITIAL_STATE: dict[str, object] = {
  "seconds_since_boot": 0,
  "state": "INITIALIZING",
  "connected": False, "ip_address": "",
  "iccid": "", "mcc_mnc": "", "imei": "", "modem_version": "",
  "signal_strength": 0, "signal_quality": 0,
  "network_type": "unknown", "operator": "", "band": "", "channel": 0,
  "registration": "unknown", "temperatures": [], "extra": "",
  "tx_bytes": 0, "rx_bytes": 0,
  "sleep_capable": False,  # whether ModemSleep can sleep the modem, see UsbPower
  "sleep_allowed": False,  # whether the modem can sleep now: athenad waits for False to tell athena it's awake
}


@contextmanager
def _serial_port(port: str, baudrate: int, flags: int = 0):
  fd = os.open(port, os.O_RDWR | os.O_NOCTTY | flags)
  try:
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CLOCAL | termios.CREAD | termios.CS8
    attrs[3] = 0
    attrs[4] = attrs[5] = getattr(termios, f"B{baudrate}")
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    yield fd
  finally:
    os.close(fd)


def _read_line(fd: int, timeout: float) -> bytes:
  data = bytearray()
  deadline = time.monotonic() + timeout
  while True:
    readable, _, _ = select.select([fd], [], [], max(0.0, deadline - time.monotonic()))
    if not readable:
      return bytes(data)
    byte = os.read(fd, 1)
    if not byte:
      return bytes(data)
    data.extend(byte)
    if byte == b"\n":
      return bytes(data)


def _answers_at(port: str, timeout: float = 0.3) -> bool:
  deadline = time.monotonic() + timeout
  try:
    with _serial_port(port, 9600, os.O_NONBLOCK) as fd:
      termios.tcflush(fd, termios.TCIFLUSH)
      os.write(fd, b"AT\r")
      while (remaining := deadline - time.monotonic()) > 0:
        if _read_line(fd, remaining).strip() == b"OK":
          return True
  except OSError:
    pass
  return False


class State(Enum):
  INITIALIZING = "INITIALIZING"
  SEARCHING = "SEARCHING"
  CONNECTING = "CONNECTING"
  CONNECTED = "CONNECTED"
  DISCONNECTING = "DISCONNECTING"


STATE_WAIT = 1.0  # seconds to wait after each state handler returns


class DataSession:
  """Fail tracking, routing and DNS for the cellular data interface, IFACE."""
  IFACE = ""
  MAX_FAILS = 3

  def __init__(self):
    self._fails = 0
    self._peer = ""

  def reset_fail_counter(self):
    self._fails = 0

  def record_fail(self) -> bool:
    """Bump fail counter; return True if at the give-up limit."""
    self._fails += 1
    return self._fails >= self.MAX_FAILS

  @property
  def fails(self) -> int:
    return self._fails

  def maybe_install_routes(self, ip: str, peer: str) -> bool:
    """Install routes if peer changed; kill the session on failure so the state machine reconnects."""
    if not peer or peer == self._peer:
      return False
    try:
      IPv4Address(ip)
      IPv4Address(peer)
    except AddressValueError:
      logging.warning(f"refusing route install with non-IPv4 ip={ip!r} peer={peer!r}")
      self.kill()
      return False
    self.cleanup_routes()
    cmds = [
      ["sudo", "ip", "route", "add", "default", "via", peer, "dev", self.IFACE, "metric", "1000"],
      ["sudo", "ip", "route", "add", "default", "via", peer, "dev", self.IFACE, "table", "1000"],
      ["sudo", "ip", "rule", "add", "from", ip, "table", "1000"],
    ]
    for cmd in cmds:
      r = subprocess.run(cmd, capture_output=True, text=True)
      if r.returncode != 0:
        logging.warning(f"route install failed ({' '.join(cmd[1:])}): {r.stderr.strip()}")
        self.cleanup_routes()
        self.kill()
        return False
    logging.info(f"route set up for {ip} via {peer}")
    self._peer = peer
    return True

  def maybe_install_dns(self, dns_servers: list[str]) -> bool:
    """Register DNS servers with systemd-resolved; kill the session on failure to force a retry."""
    if not dns_servers:
      return False
    for cmd in (["sudo", "resolvectl", "dns", self.IFACE, *dns_servers],
                ["sudo", "resolvectl", "default-route", self.IFACE, "yes"]):
      r = subprocess.run(cmd, capture_output=True, text=True)
      if r.returncode != 0:
        logging.warning(f"resolvectl failed ({' '.join(cmd[1:])}): {r.stderr.strip()}")
        self.kill()
        return False
    logging.info(f"resolvectl: {self.IFACE} DNS = {dns_servers}")
    return True

  def cleanup_routes(self):
    subprocess.run(["sudo", "ip", "route", "del", "default", "dev", self.IFACE], capture_output=True)
    subprocess.run(["sudo", "ip", "route", "flush", "table", "1000"], capture_output=True)
    # rules don't have a flush; delete until none remain
    while subprocess.run(["sudo", "ip", "rule", "del", "table", "1000"], capture_output=True).returncode == 0:
      pass
    subprocess.run(["sudo", "resolvectl", "revert", self.IFACE], capture_output=True)

  def address(self) -> tuple[str, str]:
    """(local IPv4, gateway), or empty strings while there's none."""
    raise NotImplementedError

  def byte_counters(self) -> tuple[int, int]:
    with open(f"/sys/class/net/{self.IFACE}/statistics/tx_bytes") as f:
      tx = int(f.read().strip())
    with open(f"/sys/class/net/{self.IFACE}/statistics/rx_bytes") as f:
      rx = int(f.read().strip())
    return tx, rx


class PPPSession(DataSession):
  """Owns pppd lifecycle over the modem's second AT port."""
  IFACE = "ppp0"

  def __init__(self):
    super().__init__()
    self._proc: subprocess.Popen | None = None

  def start(self):
    self._proc = subprocess.Popen(PPPD_CMD, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    self._peer = ""
    logging.info(f"PPP dialing CID {DIAL_CID}")

  def kill(self):
    subprocess.run(["sudo", "killall", "-9", "pppd"], capture_output=True)
    self._peer = ""

  def reset_data_port(self):
    """Drop DTR on PPP_PORT so the modem terminates any stuck PPP session."""
    try:
      with _serial_port(PPP_PORT, 460800) as fd:
        dtr = struct.pack("I", termios.TIOCM_DTR)
        fcntl.ioctl(fd, termios.TIOCMBIC, dtr)
        time.sleep(0.2)
        fcntl.ioctl(fd, termios.TIOCMBIS, dtr)
    except Exception as e:
      logging.warning(f"data port reset failed: {e}")

  def has_exited(self) -> bool:
    return self._proc is not None and self._proc.poll() is not None

  def address(self) -> tuple[str, str]:
    r = subprocess.run(["ip", "-4", "addr", "show", self.IFACE], capture_output=True, text=True, timeout=2)
    for line in r.stdout.splitlines():
      # `inet 10.x.x.x peer 10.64.64.64/32 ...`
      parts = line.strip().split()
      if "inet" in parts:
        ip = parts[parts.index("inet") + 1].split("/")[0]
        peer = parts[parts.index("peer") + 1].split("/")[0] if "peer" in parts else ""
        return ip, peer
    return "", ""


def ecm_netdev() -> str:
  """The modem's USB Ethernet (cdc_ether) interface, or "" if it has none (comma 3X's EG25 uses PPP)."""
  for dev in glob.glob("/sys/class/net/*/device"):
    try:
      drv = os.path.basename(os.readlink(f"{dev}/driver"))
      with open(f"{dev}/../idVendor") as f:
        vendor = f.read().strip()
    except OSError:
      continue
    if drv == "cdc_ether" and vendor == "2c7c":  # Quectel
      return dev.split("/")[4]
  return ""


def dhcp_lease(iface: str, timeout: float = 10.0) -> dict | None:
  """DISCOVER/REQUEST on iface. The EG916Q's ECM side runs a DHCP server and NATs the PDN behind it. Replies come in
  through a packet socket: the interface has no IPv4 address yet, and iptables drops everything in on the cellular
  interface (rules.v4). modem.service grants the raw socket and port 68."""
  with open(f"/sys/class/net/{iface}/address") as f:
    mac = bytes.fromhex(f.read().strip().replace(":", ""))
  xid = random.getrandbits(32)

  def packet(msg_type: int, options: bytes = b"") -> bytes:
    bootp = struct.pack("!BBBBIHH4s4s4s4s16s64s128s", 1, 1, 6, 0, xid, 0, 0x8000, bytes(4), bytes(4), bytes(4),
                        bytes(4), mac, b"", b"")
    # magic cookie, message type, options, parameter request list (subnet mask, router, DNS)
    return bootp + b"\x63\x82\x53\x63" + bytes([53, 1, msg_type]) + options + bytes([55, 3, 1, 3, 6, 255])

  def parse(dhcp: bytes) -> dict[int, bytes]:
    opts, i = {}, 240
    while i + 1 < len(dhcp) and dhcp[i] != 255:
      if dhcp[i] == 0:
        i += 1
        continue
      opts[dhcp[i]] = dhcp[i + 2:i + 2 + dhcp[i + 1]]
      i += 2 + dhcp[i + 1]
    return opts

  tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
  rx = socket.socket(socket.AF_PACKET, socket.SOCK_DGRAM, socket.htons(0x0800))
  try:
    tx.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    tx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    tx.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, iface.encode())
    tx.bind(("0.0.0.0", 68))
    rx.bind((iface, 0))

    def exchange(msg_type: int, options: bytes, want: int) -> tuple[bytes, dict[int, bytes]] | None:
      deadline = time.monotonic() + timeout
      while time.monotonic() < deadline:
        tx.sendto(packet(msg_type, options), ("255.255.255.255", 67))
        resend = time.monotonic() + 2
        while (remaining := min(resend, deadline) - time.monotonic()) > 0:
          if not select.select([rx], [], [], remaining)[0]:
            break
          ip = rx.recv(1500)
          if len(ip) < 28 or ip[9] != 17 or struct.unpack("!H", ip[22:24])[0] != 68:  # UDP to port 68
            continue
          dhcp = ip[(ip[0] & 0xf) * 4 + 8:]
          if len(dhcp) < 240 or dhcp[4:8] != struct.pack("!I", xid):
            continue
          opts = parse(dhcp)
          if opts.get(53) == bytes([want]):
            return dhcp, opts
          if opts.get(53) == b"\x06":  # NAK
            return None
      return None

    offer = exchange(1, b"", 2)  # DISCOVER -> OFFER
    if offer is None or 54 not in offer[1]:
      return None
    yiaddr = offer[0][16:20]
    ack = exchange(3, bytes([50, 4]) + yiaddr + bytes([54, 4]) + offer[1][54], 5)  # REQUEST -> ACK
    if ack is None:
      return None
    opts = ack[1]
    ip = socket.inet_ntoa(ack[0][16:20])
    mask = socket.inet_ntoa(opts.get(1, b"\xff\xff\xff\x00")[:4])
    return {
      "ip": ip,
      "prefix": IPv4Network(f"0.0.0.0/{mask}").prefixlen,
      "gateway": socket.inet_ntoa(opts[3][:4]) if 3 in opts else "",
      "lease": struct.unpack("!I", opts[51][:4])[0] if 51 in opts else 3600,
    }
  except OSError as e:
    logging.warning(f"DHCP on {iface} failed: {e}")
    return None
  finally:
    tx.close()
    rx.close()


class EcmSession(DataSession):
  """The EG916Q's data call over its USB Ethernet interface, renamed to ECM_IFACE."""
  IFACE = ECM_IFACE
  MAX_AT_MISSES = 3  # checks in a row without an answer, then the AT channel is dead

  def __init__(self, at, at_busy):
    super().__init__()
    self._at = at
    self._at_busy = at_busy  # did the last command find the port taken (LPA, qcomgpsd)
    self._lease: dict | None = None
    self._renew_at = 0.0
    self._exited = False
    self._at_misses = 0

  def start(self):
    self._peer = ""
    self._lease = None
    self._exited = True
    netdev = ecm_netdev()
    if not netdev:
      logging.warning("no ECM interface")
      return
    if netdev != self.IFACE:
      # an unmanaged name for NetworkManager, and the one the cellular firewall rules (rules.v4) name
      subprocess.run(["sudo", "ip", "link", "set", netdev, "down"], capture_output=True)
      subprocess.run(["sudo", "ip", "link", "set", netdev, "name", self.IFACE], capture_output=True)
    subprocess.run(["sudo", "ip", "link", "set", self.IFACE, "up"], capture_output=True)
    # no +QNETDEVSTATUS URCs: the modem drops and restores the call's status as the link suspends and resumes, and
    # each URC wakes the link, so with them it never stays asleep
    self._at(f"AT+QNETDEVCTL=1,{DIAL_CID},0")
    logging.info(f"ECM data call on CID {DIAL_CID}")
    if self._renew():
      self._exited = False

  def _renew(self) -> bool:
    lease = dhcp_lease(self.IFACE)
    if lease is None or not lease["gateway"]:
      logging.warning(f"no DHCP lease on {self.IFACE}: {lease}")
      return False
    if lease != self._lease:
      subprocess.run(["sudo", "ip", "-4", "addr", "flush", "dev", self.IFACE], capture_output=True)
      subprocess.run(["sudo", "ip", "addr", "add", f"{lease['ip']}/{lease['prefix']}", "dev", self.IFACE],
                     capture_output=True)
      self._peer = ""  # routes go in again
      logging.info(f"{self.IFACE} lease {lease}")
    self._lease = lease
    self._renew_at = time.monotonic() + lease["lease"] / 2
    return True

  def kill(self):
    self._peer = ""
    self._lease = None
    self._exited = True
    if os.path.exists(f"/sys/class/net/{self.IFACE}"):
      self._at(f"AT+QNETDEVCTL=0,{DIAL_CID},0")
      subprocess.run(["sudo", "ip", "-4", "addr", "flush", "dev", self.IFACE], capture_output=True)
      subprocess.run(["sudo", "ip", "link", "set", self.IFACE, "down"], capture_output=True)

  def reset_data_port(self):
    pass

  def has_exited(self) -> bool:
    return self._exited or not os.path.exists(f"/sys/class/net/{self.IFACE}")

  def check(self) -> bool:
    """Every poll: is the call still up, does the lease need renewing. Returns False once the AT channel is dead: the
    data can keep flowing without it, so nothing else would notice."""
    v = None
    for line in self._at("AT+QNETDEVCTL?"):
      if line.startswith("+QNETDEVCTL:"):
        v = line.split(":", 1)[1].split(",")
    if v is not None:
      self._at_misses = 0
    elif not self._at_busy():
      self._at_misses += 1
    if self._at_misses >= self.MAX_AT_MISSES:
      logging.warning(f"AT channel not answering for {self._at_misses} checks")
      return False
    if v is not None and len(v) >= 4 and v[3].strip() != "1":
      logging.warning(f"ECM data call down: {v}")
      self._exited = True
    elif time.monotonic() > self._renew_at and not self._renew():
      self._exited = True
    return True

  def address(self) -> tuple[str, str]:
    if self._exited or self._lease is None:
      return "", ""
    return self._lease["ip"], self._lease["gateway"]


class UsbPower:
  """Lets the modem's USB link autosuspend while the data link is quiet, and the modem sleep with it (AT+QSCLK=1).

  Only while openpilot allows it with ModemSleep: the EG916Q resets a TCP connection that gets downlink data while
  its link is asleep, so everything on it has to be the device's request and its prompt answer. athenad arranges that
  with athena while offroad. The link stays up AUTOSUSPEND_DELAY_MS after the last packet, for answers to come back,
  and while traffic is flowing, a burst big enough to be more than keepalives, it's held awake until it's been quiet
  for HOLD seconds."""
  AUTOSUSPEND_DELAY_MS = 4000
  BUSY_BYTES = 1500  # rx + tx bytes in one STATE_WAIT
  HOLD = 20.0

  def __init__(self, iface: str):
    self._iface = iface
    self._control = ""
    self._bytes = -1
    self._busy_until = 0.0
    self._dev = ""
    try:
      # /sys/class/net/<iface>/device is the ECM interface, its parent is the modem's USB device
      self._dev = os.path.realpath(f"/sys/class/net/{iface}/device/..")
    except OSError:
      pass
    if self._dev:
      self._write("autosuspend_delay_ms", str(self.AUTOSUSPEND_DELAY_MS))

  def _write(self, attr: str, value: str) -> bool:
    r = subprocess.run(["sudo", "tee", f"{self._dev}/power/{attr}"], input=value, text=True, capture_output=True)
    return r.returncode == 0

  def _set(self, control: str):
    if control == self._control or not self._dev:
      return
    if self._write("control", control):
      self._control = control

  def may_sleep(self) -> bool:
    try:
      with open(f"{self._dev}/power/control") as f:
        return f.read().strip() == "auto"
    except OSError:
      return False

  def suspended(self) -> bool:
    try:
      with open(f"{self._dev}/power/runtime_status") as f:
        return f.read().strip() == "suspended"
    except OSError:
      return False

  def update(self, allowed: bool):
    if not allowed:
      self._busy_until = 0.0
      self._set("on")
      return
    try:
      with open(f"/sys/class/net/{self._iface}/statistics/rx_bytes") as f:
        total = int(f.read())
      with open(f"/sys/class/net/{self._iface}/statistics/tx_bytes") as f:
        total += int(f.read())
    except (OSError, ValueError):
      return
    now = time.monotonic()
    if self._bytes >= 0 and total - self._bytes >= self.BUSY_BYTES:
      self._busy_until = now + self.HOLD
    self._bytes = total
    self._set("on" if now < self._busy_until else "auto")

  def release(self):
    """Back to the kernel default, always on."""
    self._set("on")


class Modem:
  def __init__(self):
    self._data: PPPSession | EcmSession = PPPSession()
    self._usb_power: UsbPower | None = None  # ECM only
    self._next_at_poll = 0.0
    self._sim_change = False
    self._apn = ""  # blank = network-provided via PCO
    self._roaming_allowed = True
    self._initializing = False  # see _at
    self._at_busy = False
    self.running = True
    self.S = INITIAL_STATE.copy()

  @staticmethod
  def _read_param(key):
    try:
      with open(f"/data/params/d/{key}") as f:
        return f.read().strip()
    except FileNotFoundError:
      return ""

  @staticmethod
  def _parse_reg(v: str) -> str:
    try:
      return CREG.get(int(v.split(",")[1].strip('"')), "unknown")
    except (ValueError, IndexError):
      return "unknown"

  @staticmethod
  def _has_modem_manager() -> bool:
    return os.path.isfile("/lib/systemd/system/ModemManager.service")

  def _is_roaming_allowed(self) -> bool:
    if self.S["iccid"].startswith(WEBBING_ICCID_PREFIX):
      return True
    return self._read_param("GsmRoaming") == "1"

  def _publish_state(self, **kwargs):
    self.S.update(kwargs)
    self.S["seconds_since_boot"] = time.monotonic()
    with tempfile.NamedTemporaryFile(mode="w", dir="/dev/shm", delete=False) as f:
      json.dump(self.S, f, indent=2)
    os.chmod(f.name, 0o644)
    os.replace(f.name, STATE_PATH)

  def _at(self, cmd):
    """Send AT command, return response lines. [] on error, or if another process (LPA, qcomgpsd) holds the port
    outside of initializing: there every command has to take effect, so it waits for the port."""
    fd = os.open(AT_LOCK, os.O_CREAT | os.O_RDWR, 0o666)
    try:
      fcntl.flock(fd, fcntl.LOCK_EX if self._initializing else fcntl.LOCK_EX | fcntl.LOCK_NB)
      self._at_busy = False
    except OSError:
      os.close(fd)
      self._at_busy = True
      return []
    try:
      with _serial_port(AT_PORT, 9600) as serial_fd:
        termios.tcflush(serial_fd, termios.TCIFLUSH)
        command = (cmd + "\r").encode()
        while command:
          command = command[os.write(serial_fd, command):]
        lines = []
        while True:
          raw = _read_line(serial_fd, 5)
          if not raw:
            raise TimeoutError("AT timeout")
          line = raw.decode(errors="ignore").strip()
          if not line:
            continue
          if line == "OK":
            break
          if line == "ERROR" or line.startswith("+CME ERROR"):
            raise RuntimeError(line)
          lines.append(line)
        return lines
    except (RuntimeError, TimeoutError, OSError) as e:
      logging.info(f"AT {cmd} failed: {e}")
      return []
    finally:
      fcntl.flock(fd, fcntl.LOCK_UN)
      os.close(fd)

  def _atv(self, cmd, pfx):
    for line in self._at(cmd):
      if pfx in line and ":" in line:
        return line.split(":", 1)[1].strip()
    return None

  @property
  def _ecm(self) -> bool:
    return isinstance(self._data, EcmSession)

  def _at_poll_due(self, interval: float) -> bool:
    """With PPP, the modem is polled every STATE_WAIT. With ECM, at most every interval, see ECM_POLL_INTERVAL."""
    if not self._ecm:
      return True
    now = time.monotonic()
    if now < self._next_at_poll:
      return False
    if (self._usb_power is not None and self._usb_power.suspended() and
        now < self._next_at_poll + ECM_POLL_MAX_DELAY - interval):
      return False
    self._next_at_poll = now + interval
    return True

  def _init_at_channel(self) -> bool:
    """Run AT_INIT and confirm ATE0 took effect. Returns False if echo is still on."""
    for c in AT_INIT:
      self._at(c)
    r = self._at("AT+CGMI")
    return bool(r) and not r[0].startswith("AT")

  def _configure_modem(self, modem_version: str):
    if not modem_version.startswith("EG25"):
      return
    cmds = [
      # clear initial EPS bearer APN (some carriers reject the default)
      'AT+CGDCONT=0,"IP",""',

      # SIM hot swap
      'AT+QSIMDET=1,0',
      'AT+QSIMSTAT=1',

      # configure modem as data-centric
      'AT+QNVW=5280,0,"0102000000000000"',
      'AT+QNVFW="/nv/item_files/ims/IMS_enable",00',
      'AT+QNVFW="/nv/item_files/modem/mmode/ue_usage_setting",01',
    ]
    for c in cmds:
      self._at(c)

  def _sync_ports(self) -> bool:
    """The modem's nodes come up root only every time it enumerates, and their numbers
    move if something is holding the old ones. Ask them which are AT ports and link those."""
    ttys = sorted(glob.glob("/dev/ttyUSB*"), key=lambda p: int(p.removeprefix("/dev/ttyUSB")), reverse=True)
    subprocess.run(["sudo", "chgrp", "dialout", *ttys], capture_output=True)
    subprocess.run(["sudo", "chmod", "660", *ttys], capture_output=True)

    fd = os.open(AT_LOCK, os.O_CREAT | os.O_RDWR, 0o666)
    try:
      fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
      os.close(fd)
      return False
    try:
      # the AT ports are the highest two, stop there to stay off the GPS and debug ports
      ports = []
      for tty in ttys:
        if _answers_at(tty):
          ports.append(tty)
        if len(ports) == 2:
          break
    finally:
      fcntl.flock(fd, fcntl.LOCK_UN)
      os.close(fd)
    if len(ports) != 2:
      logging.warning(f"found AT ports {ports} in {ttys}, retrying")
      return False

    for link, tty in zip((AT_PORT, PPP_PORT), reversed(ports)):
      subprocess.run(["sudo", "ln", "-sfn", os.path.basename(tty), link], capture_output=True)
    logging.info(f"AT port {ports[1]}, PPP port {ports[0]}")
    return True

  def _do_initializing(self):
    if not glob.glob("/dev/ttyUSB*"):
      return State.INITIALIZING
    self._initializing = True
    try:
      return self._initialize()
    finally:
      self._initializing = False

  def _initialize(self):
    logging.info("port found, initializing")
    self._stop_data()

    if not self._sync_ports():
      return State.INITIALIZING

    if not self._init_at_channel():
      logging.warning("AT echo still on, retrying")
      return State.INITIALIZING

    identity = self._read_identity()
    if not identity["iccid"] or not identity["imei"]:
      logging.warning(f"identity read incomplete: {identity}, retrying")
      return State.INITIALIZING

    self._configure_modem(identity["modem_version"])
    self._select_data_session()

    self.S.update(identity)
    self._apn = self._read_param("GsmApn")
    self._roaming_allowed = self._is_roaming_allowed()
    # blank APN lets the carrier supply one via PCO
    self._at(f'AT+CGDCONT={DIAL_CID},"IP","{self._apn}"')
    logging.info(f"APN '{self._apn or '(network-provided)'}' written to CID {DIAL_CID}, roaming={'on' if self._roaming_allowed else 'off'}")

    self._sim_change = False  # clear since we just re-read identity with the new SIM
    self._publish_state(**identity)
    return State.SEARCHING

  def _select_data_session(self):
    if ecm_netdev():
      if not self._ecm:
        self._data = EcmSession(self._at, lambda: self._at_busy)
      # registration URCs carry the cell, which changes as the car moves: each one would wake the link
      for c in ("AT+CREG=0", "AT+CGREG=0", "AT+QSCLK=1"):
        self._at(c)
    elif self._ecm:
      self._data = PPPSession()
    self._next_at_poll = 0.0
    self.S["sleep_capable"] = self._ecm
    logging.info(f"data over {self._data.IFACE}")

  def _stop_data(self):
    """Tear down whichever kind of session is up, also one a previous run left behind."""
    sessions: list[DataSession] = [self._data]
    if not isinstance(self._data, PPPSession):
      sessions.append(PPPSession())
    if not isinstance(self._data, EcmSession) and ecm_netdev():
      sessions.append(EcmSession(self._at, lambda: self._at_busy))
    for session in sessions:
      session.kill()
      session.cleanup_routes()
    self._release_usb_power()

  def _release_usb_power(self):
    if self._usb_power is not None:
      self._usb_power.release()
      self._usb_power = None
    self._publish_sleep_allowed()

  def _publish_sleep_allowed(self):
    allowed = self._usb_power is not None and self._usb_power.may_sleep()
    if allowed != self.S["sleep_allowed"]:
      self._publish_state(sleep_allowed=allowed)

  def _read_identity(self):
    def first_line(cmd):
      r = self._at(cmd)
      return r[0].strip() if r else ""

    imei = first_line("AT+CGSN")
    if not (imei.isdigit() and 14 <= len(imei) <= 17):  # 3GPP TS 23.003
      imei = ""

    iccid = (self._atv("AT+QCCID", "+QCCID:") or "").rstrip("F")
    if not all(c in string.hexdigits for c in iccid):
      iccid = ""

    imsi = first_line("AT+CIMI")
    mcc_mnc = imsi[:6] if imsi.isdigit() and len(imsi) >= 6 else ""

    modem_version = first_line("AT+GMR")

    logging.info(f"imei={imei} iccid={iccid} mcc_mnc={mcc_mnc} ver={modem_version}")
    return {"imei": imei, "iccid": iccid, "mcc_mnc": mcc_mnc, "modem_version": modem_version}

  def _do_searching(self):
    if not self._at_poll_due(ECM_SEARCH_POLL_INTERVAL):
      return self._searching_idle()
    if self._ecm:
      self._check_iccid(State.SEARCHING)
    new_roaming = self._is_roaming_allowed()
    if new_roaming != self._roaming_allowed:
      logging.info(f"roaming changed: {self._roaming_allowed} -> {new_roaming}")
      self._roaming_allowed = new_roaming

    v = self._atv("AT+CREG?", "+CREG:")
    if not v:
      return self._searching_idle()

    reg = self._parse_reg(v)
    greg = self._parse_reg(self._atv("AT+CGREG?", "+CGREG:") or "")
    logging.debug(f"creg={reg} cgreg={greg} roaming_allowed={self._roaming_allowed}")

    if reg == "roaming" and not self._roaming_allowed:
      self._publish_state(registration=reg)
      return State.SEARCHING

    if reg in ("home", "roaming") and greg in ("home", "roaming"):
      self._publish_state(registration=reg)
      return State.CONNECTING

    if reg != self.S.get("registration"):
      self._publish_state(registration=reg)
    return self._searching_idle()

  def _searching_idle(self):
    if self._sim_change or not os.path.exists(AT_PORT):
      logging.info(f"-> reconnecting (sim_change={self._sim_change} port={os.path.exists(AT_PORT)})")
      return State.DISCONNECTING
    return State.SEARCHING

  def _do_connecting(self):
    logging.info(f"starting data on {self._data.IFACE}")
    self._data.reset_fail_counter()
    self._sim_change = False
    self._data.start()
    self._next_at_poll = 0.0
    return State.CONNECTED

  def _handle_data_exit(self):
    if self._sim_change or not os.path.exists(AT_PORT):
      return State.DISCONNECTING
    give_up = self._data.record_fail()
    if give_up:
      logging.warning(f"{self._data.IFACE} fail {self._data.fails}/{self._data.MAX_FAILS}, reconnecting")
      return State.DISCONNECTING
    logging.warning(f"{self._data.IFACE} fail {self._data.fails}/{self._data.MAX_FAILS}, retrying")
    self._data.reset_data_port()
    if not os.path.exists(AT_PORT):
      return State.DISCONNECTING
    self._release_usb_power()
    self._data.start()
    self._next_at_poll = 0.0
    return State.CONNECTED

  def _params_changed(self) -> bool:
    new_apn = self._read_param("GsmApn")
    if new_apn != self._apn:
      logging.info(f"GsmApn changed: '{self._apn}' -> '{new_apn}'")
      return True
    new_roaming = self._is_roaming_allowed()
    if new_roaming != self._roaming_allowed:
      logging.info(f"roaming changed: {self._roaming_allowed} -> {new_roaming}")
      return True
    return False

  def _check_iccid(self, state):
    if state in (State.INITIALIZING, State.DISCONNECTING) or not self.S["iccid"]:
      return
    iccid = (self._atv("AT+QCCID", "+QCCID:") or "").rstrip("F")
    if iccid and iccid != self.S["iccid"]:
      logging.warning(f"iccid changed: {self.S['iccid']} -> {iccid}")
      self._sim_change = True

  def _do_connected(self):
    if self._data.has_exited():
      return self._handle_data_exit()

    if self._sim_change or not os.path.exists(AT_PORT) or self._params_changed():
      return State.DISCONNECTING

    if self._usb_power is not None:
      self._usb_power.update(self._read_param("ModemSleep") == "1")
    self._publish_sleep_allowed()
    if self._at_poll_due(ECM_POLL_INTERVAL):
      if isinstance(self._data, EcmSession):
        self._check_iccid(State.CONNECTED)
        if not self._data.check():
          return State.DISCONNECTING
        if self._data.has_exited():
          return self._handle_data_exit()
      self._poll()
    return State.CONNECTED

  def _do_disconnecting(self):
    logging.warning("reconnecting")
    self._publish_state(**INITIAL_STATE)
    self._stop_data()
    self._data.reset_data_port()
    self._sim_change = False
    return State.INITIALIZING

  def _poll_signal(self) -> dict:
    v = self._atv("AT+CSQ", "+CSQ:")
    if not v:
      return {}
    try:
      rssi = int(v.split(",")[0])
      if rssi == 99:
        return {}
      return {"signal_strength": rssi, "signal_quality": min(100, int(rssi / 31 * 100))}
    except (ValueError, IndexError):
      return {}

  def _poll_operator(self) -> dict:
    v = self._atv("AT+COPS?", "+COPS:")
    if not v:
      return {}
    p = v.split(",")
    out: dict = {}
    try:
      if len(p) >= 3:
        out["operator"] = p[2].strip('"')
      if len(p) >= 4:
        out["network_type"] = NETWORK_TYPE.get(int(p[3]), "unknown")
    except (ValueError, IndexError):
      pass
    return out

  def _poll_band(self) -> dict:
    v = self._atv("AT+QNWINFO", "+QNWINFO:")
    if not v:
      return {}
    info = v.replace('"', '').split(",")
    try:
      if len(info) >= 4:
        return {"band": info[2], "channel": int(info[3])}
    except ValueError:
      pass
    return {}

  def _poll_extra(self) -> dict:
    v = self._atv('AT+QENG="servingcell"', "+QENG:")
    return {"extra": v.replace('"', '')} if v else {}

  def _poll_temps(self) -> dict:
    v = self._atv("AT+QTEMP", "+QTEMP:")
    if not v:
      return {}
    try:
      return {"temperatures": [t for t in (int(x) for x in v.split(",") if x.strip()) if t != 255]}
    except (ValueError, IndexError):
      return {}

  def _poll_iface(self) -> dict:
    try:
      ip, peer = self._data.address()
      if ip:
        if self._data.maybe_install_routes(ip, peer):
          self._data.maybe_install_dns(self._read_cellular_dns())
          if self._ecm and self._usb_power is None:
            self._usb_power = UsbPower(self._data.IFACE)
        if self._ecm:
          # the ECM address is the modem's NAT, show the one the network gave
          ip = (self._atv(f"AT+CGPADDR={DIAL_CID}", "+CGPADDR:") or "").split(",")[-1].strip('" ') or ip
        return {"ip_address": ip, "connected": True}
      if self.S["connected"]:
        return {"connected": False, "ip_address": ""}
    except Exception:
      pass
    return {}

  def _read_cellular_dns(self) -> list[str]:
    v = self._atv(f"AT+CGCONTRDP={DIAL_CID}", "+CGCONTRDP:")
    if not v:
      return []
    # +CGCONTRDP: <cid>,<bearer_id>,<apn>,<local_addr>,<gw_addr>,<dns_prim>,<dns_sec>,...
    fields = [f.strip().strip('"') for f in v.split(",")]
    dns_servers = []
    for d in fields[5:7]:
      try:
        dns_servers.append(str(IPv4Address(d)))
      except (AddressValueError, ValueError):
        pass
    if not dns_servers:
      dns_servers = [
        "8.8.8.8",  # Google
        "1.1.1.1",  # Cloudflare
      ]
      logging.warning(f"no cellular DNS servers reported by modem: {v!r}; using fallback {dns_servers}")
    return dns_servers

  def _poll_byte_counters(self) -> dict:
    try:
      tx, rx = self._data.byte_counters()
    except Exception:
      return {}
    return {"tx_bytes": tx, "rx_bytes": rx}

  def _poll(self):
    s: dict = {}
    for fn in (self._poll_signal, self._poll_operator, self._poll_band,
               self._poll_extra, self._poll_temps, self._poll_iface,
               self._poll_byte_counters):
      s.update(fn())
    if s:
      self._publish_state(**s)

  def run(self):
    logging.info("starting")
    self._publish_state(state=State.INITIALIZING.value)
    if self._has_modem_manager():
      subprocess.run(["sudo", "systemctl", "mask", "--runtime", "ModemManager"], capture_output=True)
      subprocess.run(["sudo", "systemctl", "stop", "ModemManager"], capture_output=True)
    self._stop_data()

    state = State.INITIALIZING

    handlers = {
      State.INITIALIZING: self._do_initializing,
      State.SEARCHING: self._do_searching,
      State.CONNECTING: self._do_connecting,
      State.CONNECTED: self._do_connected,
      State.DISCONNECTING: self._do_disconnecting,
    }

    while self.running:
      try:
        if not self._ecm:
          self._check_iccid(state)
        prev = state
        state = handlers[state]()
        if state != prev:
          self._publish_state(state=state.value)
          logging.info(f"{prev.value} -> {state.value}")
      except Exception:
        logging.exception(f"error in {state.value}")
        state = State.DISCONNECTING
      time.sleep(STATE_WAIT)

  def stop(self):
    self.running = False
    self._stop_data()
    try:
      os.remove(STATE_PATH)
    except FileNotFoundError:
      pass
    if self._has_modem_manager():
      subprocess.run(["sudo", "systemctl", "unmask", "--runtime", "ModemManager"], capture_output=True)
      subprocess.run(["sudo", "systemctl", "start", "ModemManager"], capture_output=True)


def main():
  m = Modem()

  def _sig(*_):
    m.running = False

  signal.signal(signal.SIGINT, _sig)
  signal.signal(signal.SIGTERM, _sig)
  m.run()
  m.stop()


if __name__ == "__main__":
  main()
