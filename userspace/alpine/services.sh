#!/bin/bash -e
# Alpine/runit equivalent of services.sh (ported from the Void spike).
# Generates /etc/sv/<name> from our systemd units (by hand, see notes) and
# links them into the default runlevel. Alpine's runit ships no service
# directories, so the system daemons are defined here too.
#  - Type=oneshot      -> run once, then park in `pause` so runsv doesn't respawn
#  - .path units       -> poll loop
#  - .timer            -> sleep loop
#  - User=comma        -> setpriv (no PAM, so limits.conf is NOT applied)
#  - fs_setup, serial-hostname -> /etc/runit/1 (stage 1)
#  - logging: busybox syslogd ring buffer (logread), no journald
SV=/etc/sv
RUNSVDIR=/etc/runit/runsvdir/default

as_comma='setpriv --reuid=comma --regid=comma --init-groups env HOME=/home/comma USER=comma LOGNAME=comma'

mk() { # name: create dir, logger log service, supervise symlinks onto /run
  local n=$1
  mkdir -p "$SV/$n/log"
  cat > "$SV/$n/log/run" <<EOF
#!/bin/sh
exec logger -t $n -p daemon.info
EOF
  ln -sfn "/run/runit/supervise.$n" "$SV/$n/supervise"
  ln -sfn "/run/runit/supervise.$n-log" "$SV/$n/log/supervise"
}

oneshot() { # name, command...
  local n=$1; shift
  mk "$n"
  cat > "$SV/$n/run" <<EOF
#!/bin/sh
# oneshot (systemd Type=oneshot): run once per boot, then park so runit doesn't restart it
exec 2>&1
[ -e /run/agnos-oneshot.$n ] && exec pause
$*
echo "$n: exited \$?"
touch /run/agnos-oneshot.$n
exec pause
EOF
}

simple() { # name, command (exec'd)
  local n=$1; shift
  mk "$n"
  cat > "$SV/$n/run" <<EOF
#!/bin/sh
exec 2>&1
exec $*
EOF
}

oneshot init-qcom /usr/comma/init.qcom.sh
oneshot cdsp "sh -c 'echo 1 > /sys/kernel/boot_cdsp/boot'"
oneshot gpio /usr/comma/gpio.sh
oneshot sound /usr/comma/sound/sound_init.sh
oneshot screen_calibration /usr/comma/screen_calibration.py
oneshot agnos-debug "$as_comma /usr/comma/debug.py"

simple wifi /usr/comma/wifi.sh
simple varwatch /usr/local/venv/bin/python -u /usr/comma/varwatch.py
simple power_monitor /usr/local/venv/bin/python -u /usr/comma/power_monitor.py
simple brightnessd /usr/local/venv/bin/python -u /usr/comma/brightnessd.py
simple adbd /usr/comma/adbd

mk power_drop_monitor
cat > $SV/power_drop_monitor/run <<'EOF'
#!/bin/sh
exec 2>&1
# ExecCondition: only on tici/tizi; otherwise stay down
grep -q -E "tici|tizi" /sys/firmware/devicetree/base/model || { sv down power_drop_monitor; exec pause; }
exec /usr/local/venv/bin/python -u /usr/comma/power_drop_monitor.py
EOF

mk avahi-ssh-publish
cat > $SV/avahi-ssh-publish/run <<EOF
#!/bin/sh
exec 2>&1
sv check avahi-daemon >/dev/null || exit 1
sleep 5  # RestartSec=5
exec $as_comma /usr/comma/avahi-publish-service.sh
EOF

mk lte
cat > $SV/lte/run <<'EOF'
#!/bin/sh
# RemainAfterExit service with an ExecStop
exec 2>&1
sv check gpio >/dev/null || exit 1
[ -e /run/agnos-oneshot.lte ] || { /usr/comma/lte/lte.sh start; touch /run/agnos-oneshot.lte; }
exec pause
EOF
cat > $SV/lte/finish <<'EOF'
#!/bin/sh
# runs on "sv down lte" or shutdown (and on any pause exit): ExecStop
[ -e /run/agnos-oneshot.lte ] || exit 0
/usr/comma/lte/lte.sh stop
rm -f /run/agnos-oneshot.lte
EOF

mk modem
cat > $SV/modem/run <<EOF
#!/bin/sh
exec 2>&1
sv start lte >/dev/null || exit 1
sleep 5  # RestartSec=5
exec $as_comma /usr/bin/python3 -u /usr/comma/modem.py
EOF
cat > $SV/modem/finish <<'EOF'
#!/bin/sh
rm -f /dev/shm/modem
EOF

mk magic
cat > $SV/magic/run <<EOF
#!/bin/bash
exec 2>&1
chgrp gpu /dev/ion /dev/kgsl-3d0
chmod 660 /dev/ion /dev/kgsl-3d0
mkdir -p /data/misc/display || true
echo 0 > /data/misc/display/sdm_dbg_cfg.txt || true
echo 0 > /data/misc/display/gbm_dbg_cfg.txt || true
exec $as_comma /bin/bash -c "source /etc/profile && exec /usr/local/venv/bin/python -u /usr/comma/magic.py"
EOF

mk comma
cat > $SV/comma/run <<EOF
#!/bin/bash
# systemd: Type=oneshot RemainAfterExit, User=comma, LimitRTPRIO=100, LimitNICE=-10
exec 2>&1
[ -e /run/agnos-oneshot.comma ] && exec pause
ulimit -r 100
ulimit -e 30
$as_comma /usr/bin/tmux new-session -s comma -d /usr/comma/comma.sh
echo "comma: tmux started \$?"
touch /run/agnos-oneshot.comma
exec pause
EOF
cat > $SV/comma/finish <<EOF
#!/bin/sh
# ExecStop: only on an explicit "sv down comma"
[ "\$(cat supervise/stat 2>/dev/null)" = "down" ] || [ -e down ] || exit 0
$as_comma /usr/bin/tmux kill-session -t comma 2>/dev/null
rm -f /run/agnos-oneshot.comma
exit 0
EOF

# --- system daemons (Void ships these as runit services, Alpine doesn't) ---
simple udevd /sbin/udevd
mk dbus
cat > $SV/dbus/run <<'EOF'
#!/bin/sh
exec 2>&1
mkdir -p /run/dbus /var/lib/dbus
dbus-uuidgen --ensure
exec dbus-daemon --system --nofork --nopidfile
EOF
mk NetworkManager
cat > $SV/NetworkManager/run <<'EOF'
#!/bin/sh
exec 2>&1
sv check dbus >/dev/null || exit 1
exec NetworkManager -n
EOF
mk polkitd
cat > $SV/polkitd/run <<'EOF'
#!/bin/sh
exec 2>&1
sv check dbus >/dev/null || exit 1
exec chpst -u polkitd /usr/lib/polkit-1/polkitd --no-debug
EOF
mk avahi-daemon
cat > $SV/avahi-daemon/run <<'EOF'
#!/bin/sh
exec 2>&1
sv check dbus >/dev/null || exit 1
exec avahi-daemon -s
EOF
# journald replacement: in-memory ring buffer, read with logread
mkdir -p $SV/syslogd
ln -sfn /run/runit/supervise.syslogd $SV/syslogd/supervise
cat > $SV/syslogd/run <<'EOF'
#!/bin/sh
exec syslogd -n -C4096
EOF
# systemd-timesyncd replacement
simple ntpd busybox ntpd -n -p pool.ntp.org
oneshot iptables "iptables-restore < /etc/iptables/rules.v4"

mk sshd
# sshd with ssh.service.d/override.conf (host keys on /data)
cat > $SV/sshd/run <<'EOF'
#!/bin/sh
exec 2>&1
mkdir -p /data/etc/ssh/ /run/sshd
ssh-keygen -A -f /data
/usr/sbin/sshd -t || exit 1
exec /usr/sbin/sshd -D
EOF

watcher() { # name, param file, script
  mk "$1"
  cat > "$SV/$1/run" <<EOF
#!/bin/sh
# Replaces $1.path (PathModified=$2) + $1.service with a poll loop.
exec 2>&1
last=""
while :; do
  cur=\$(stat -c '%Y %s %i' "$2" 2>/dev/null)
  if [ "\$cur" != "\$last" ]; then
    $3
    last="\$cur"
  fi
  sleep 2
done
EOF
}
watcher ssh-param-watcher /data/params/d/SshEnabled /usr/comma/set_ssh.sh
watcher adb-param-watcher /data/params/d/AdbEnabled /usr/comma/set_adb.sh

# Serial console. The systemd drop-in forced a hangup with stty hupcl.
mk agetty-ttyMSM0
rm -rf $SV/agetty-ttyMSM0/log
cat > $SV/agetty-ttyMSM0/run <<'EOF'
#!/bin/sh
/bin/stty -F /dev/ttyMSM0 hupcl
exec chpst -P /sbin/agetty -L -8 ttyMSM0 115200 vt100
EOF

chmod 755 $SV/*/run $SV/*/log/run
chmod 755 $SV/*/finish 2>/dev/null || true

# --- runlevel ---
rm -f $RUNSVDIR/*
ENABLED=(
  syslogd udevd dbus polkitd NetworkManager ntpd iptables avahi-daemon
  sshd agetty-ttyMSM0
  init-qcom cdsp wifi gpio sound screen_calibration agnos-debug
  magic comma brightnessd power_monitor varwatch
)
# On demand / riskier: linked but start "down" (sv up X works at runtime;
# runsvchdir/sv enable can't write the read-only /etc).
DOWN=(
  adbd lte modem power_drop_monitor ssh-param-watcher adb-param-watcher
  avahi-ssh-publish
)
for s in "${ENABLED[@]}" "${DOWN[@]}"; do
  test -d "$SV/$s" || { echo "missing service $s"; exit 1; }
  ln -sfn "$SV/$s" "$RUNSVDIR/$s"
done
for s in "${DOWN[@]}"; do touch "$SV/$s/down"; done
