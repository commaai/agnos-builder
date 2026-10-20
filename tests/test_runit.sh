#!/bin/bash
# Run only in a disposable Ubuntu container with userspace mounted at /src.
set -euo pipefail
[ -f /.dockerenv ] && [ -d /src/root/etc/runit ]
cp -a /src/root/etc/runit /etc/
cp -a /src/root/usr/local/bin/* /usr/local/bin/
mkdir -p /etc/udev/rules.d /usr/comma /run/runit
rm -f /run/test-attempt /run/test-success /run/test-child /run/agnos-oneshot.gpio
bash /src/services.sh
for script in /etc/sv/*/{run,start,finish,log/run,control/t}; do
  [ ! -f "$script" ] || bash -n "$script"
done
for service in /etc/service/*; do
  name=${service##*/}
  mkdir -p "/run/runit/supervise.$name" "/run/runit/supervise.$name-log"
done
[ -e /etc/service/sshd/down ] && [ -e /etc/service/adbd/down ]
[ ! -e /etc/service/modem/down ] && [ ! -e /etc/service/ssh-param-watcher/down ]

busybox syslogd -n -C4096 &
syslog=$!
trap 'sv -w 5 force-shutdown /etc/service/gpio /etc/service/wifi-hardware >/dev/null 2>&1 || true; kill "$syslog" 2>/dev/null || true' EXIT
for i in {1..100}; do [ ! -S /dev/log ] || break; sleep .05; done
logger -t runit-test -p daemon.warning 'logging smoke test'
for i in {1..100}; do busybox logread | grep -q 'logging smoke test' && break; sleep .05; done
python3 /usr/comma/logread.py -o json -b | python3 -c '
import json, sys
entries = [json.loads(line) for line in sys.stdin]
entry = next(e for e in entries if e.get("SYSLOG_IDENTIFIER") == "runit-test")
assert entry["MESSAGE"] == "logging smoke test", entry
assert entry["PRIORITY"] == "4", entry
assert int(entry["__REALTIME_TIMESTAMP"]) > 0, entry
'

# Stopping the compatibility reader must also reap its logread child.
/usr/comma/logread.py -f -o json > /tmp/follow.json &
follower=$!
children=""
for i in {1..100}; do
  children=$(cat "/proc/$follower/task/$follower/children")
  [ -z "$children" ] || break
  sleep .05
done
[ -n "$children" ]
kill "$follower"
wait "$follower"
for child in $children; do ! kill -0 "$child" 2>/dev/null; done

# Failed one-shots must retry, without advertising readiness before success.
cat > /usr/comma/gpio.sh <<'EOF'
#!/bin/sh
if [ ! -e /run/test-attempt ]; then touch /run/test-attempt; exit 1; fi
sleep 1
touch /run/test-success
EOF
chmod +x /usr/comma/gpio.sh
runsv /etc/service/gpio &
gpio=$!
sleep .2
[ ! -e /run/agnos-oneshot.gpio ]
for i in {1..100}; do [ ! -e /run/agnos-oneshot.gpio ] || break; sleep .05; done
[ -e /run/test-success ] && [ -e /run/agnos-oneshot.gpio ]
sv -w 5 force-stop /etc/service/gpio
sv exit /etc/service/gpio
wait "$gpio"

# Stops must reach children, not only the shell supervising Wi-Fi daemons.
cat > /usr/comma/wifi.sh <<'EOF'
#!/bin/bash
sleep infinity &
echo $! > /run/test-child
wait
EOF
chmod +x /usr/comma/wifi.sh
runsv /etc/service/wifi-hardware &
wifi=$!
for i in {1..100}; do [ ! -e /run/test-child ] || break; sleep .05; done
child=$(cat /run/test-child)
kill -0 "$child"
sv check /etc/service/wifi-hardware
sv stop /etc/service/wifi-hardware
! sv status /etc/service/wifi-hardware | grep -q "^run:"
# A dead child can briefly remain a zombie until PID 1 reaps it.
[ ! -e "/proc/$child/stat" ] || [ "$(awk '{print $3}' /proc/$child/stat)" = Z ]
sv exit /etc/service/wifi-hardware
wait "$wifi"
echo 'runit supervision and logging smoke tests passed'
