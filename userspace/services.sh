#!/bin/bash -e
# Service definitions for the read-only Ubuntu image.
SV=/etc/sv
RUNSVDIR=/etc/service
mkdir -p "$RUNSVDIR"

as_comma='setpriv --reuid=comma --regid=comma --init-groups env HOME=/home/comma USER=comma LOGNAME=comma'

mk() { # name: create dir, logger log service, supervise symlinks onto /run
  local n=$1
  mkdir -p "$SV/$n/log"
  cat > "$SV/$n/log/run" <<EOF
#!/bin/sh
exec logger --socket-errors=on -t $n -p daemon.info
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
rm -f /run/agnos-oneshot.$n
$* || exit \$?
touch /run/agnos-oneshot.$n
exec sleep infinity
EOF
  cat > "$SV/$n/finish" <<EOF
#!/bin/sh
rm -f /run/agnos-oneshot.$n
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

oneshot gpio /usr/comma/gpio.sh
oneshot cdsp "sh -c 'echo 1 > /sys/kernel/boot_cdsp/boot'"
oneshot sound /usr/comma/sound/sound_init.sh
oneshot screen_calibration /usr/comma/screen_calibration.py
oneshot agnos-debug "$as_comma /usr/comma/debug.py"

simple wifi-hardware /usr/comma/wifi.sh
simple varwatch /usr/local/venv/bin/python -u /usr/comma/varwatch.py
simple power_monitor /usr/local/venv/bin/python -u /usr/comma/power_monitor.py
simple brightnessd /usr/local/venv/bin/python -u /usr/comma/brightnessd.py
simple adbd /usr/comma/adbd

mk power_drop_monitor
cat > $SV/power_drop_monitor/run <<'EOF'
#!/bin/sh
exec 2>&1
# ExecCondition: only on tici/tizi; otherwise stay down
grep -q -E "tici|tizi" /sys/firmware/devicetree/base/model || { sv down power_drop_monitor; exec sleep infinity; }
exec /usr/local/venv/bin/python -u /usr/comma/power_drop_monitor.py
EOF

mk lte
cat > $SV/lte/run <<'EOF'
#!/bin/sh
# RemainAfterExit service with an ExecStop
exec 2>&1
[ -e /run/agnos-oneshot.gpio ] || exit 1
[ -e /run/agnos-oneshot.lte ] || { /usr/comma/lte/lte.sh start || exit 1; touch /run/agnos-oneshot.lte; }
exec sleep infinity
EOF
cat > $SV/lte/finish <<'EOF'
#!/bin/sh
# runs on "sv down lte" or shutdown (and on any pause exit): ExecStop
[ -e /run/agnos-oneshot.lte ] || exit 0
rm -f /run/agnos-oneshot.lte
/usr/comma/lte/lte.sh stop
EOF

mk modem
cat > $SV/modem/run <<EOF
#!/bin/sh
exec 2>&1
[ -e /run/agnos-oneshot.lte ] || exit 1
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
exec 2>&1
ulimit -r 100
ulimit -e 30
$as_comma /usr/bin/tmux new-session -s comma -d /usr/comma/comma.sh || exit 1
while $as_comma /usr/bin/tmux has-session -t comma 2>/dev/null; do sleep 1; done
EOF
cat > $SV/comma/finish <<EOF
#!/bin/sh
$as_comma /usr/bin/tmux kill-session -t comma 2>/dev/null
exit 0
EOF

# mdev rescans after binding netlink, recovering events during the handover.
mk mdev
cat > $SV/mdev/run <<'EOF'
#!/bin/sh
exec 2>&1
echo '' > /proc/sys/kernel/hotplug
/usr/comma/hotplug.py --coldplug
exec busybox mdev -df
EOF
simple wpa_supplicant /sbin/wpa_supplicant -i wlan0 -D nl80211 -c /etc/wpa_supplicant/comma.conf
simple wifi /usr/bin/python3 -u /usr/comma/wifi.py
simple ethernet /usr/bin/python3 -u /usr/comma/ethernet.py
simple mdns /usr/bin/python3 -u /usr/comma/mdns.py

# journald replacement: in-memory ring buffer, read with logread
mkdir -p $SV/syslogd
ln -sfn /run/runit/supervise.syslogd $SV/syslogd/supervise
cat > $SV/syslogd/run <<'EOF'
#!/bin/sh
exec busybox syslogd -n -C4096
EOF
# systemd-timesyncd replacement
simple ntpd /usr/sbin/chronyd -d -f /etc/chrony/agnos.conf
simple klogd busybox klogd -n

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
last=unknown
while :; do
  cur=\$(cat "$2" 2>/dev/null)
  if [ "\$cur" != "\$last" ]; then
    $3 && last="\$cur"
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

# Signal the entire service process group on stop (wifi.sh has child daemons).
for service in "$SV"/*; do
  [ -f "$service/run" ] || continue
  mv "$service/run" "$service/start"
  chmod 755 "$service/start"
  cat > "$service/run" <<'EOF'
#!/bin/sh
exec chpst -P ./start
EOF
  mkdir -p "$service/control"
  cat > "$service/control/t" <<'EOF'
#!/bin/sh
pid=$(cat supervise/pid)
[ "$pid" -gt 1 ] || exit 1
/bin/kill -TERM -- "-$pid"
EOF
  chmod 755 "$service/control/t"
done

chmod 755 $SV/*/run $SV/*/log/run
chmod 755 $SV/*/finish 2>/dev/null || true

# --- runlevel ---
rm -f $RUNSVDIR/*
ENABLED=(
  syslogd klogd mdev wpa_supplicant wifi ethernet mdns ntpd
  agetty-ttyMSM0
  gpio cdsp wifi-hardware sound screen_calibration agnos-debug
  magic comma brightnessd power_monitor varwatch
  lte modem power_drop_monitor ssh-param-watcher adb-param-watcher
)
# Parameter watchers opt in to remote access.
DOWN=(adbd sshd)
for s in "${ENABLED[@]}" "${DOWN[@]}"; do
  test -d "$SV/$s" || { echo "missing service $s"; exit 1; }
  ln -sfn "$SV/$s" "$RUNSVDIR/$s"
done
for s in "${DOWN[@]}"; do touch "$SV/$s/down"; done

# The kernel starts runit directly; keep its mutable flags in tmpfs.
ln -sfn /sbin/runit /sbin/init
for flag in stopit reboot; do ln -sfn /run/runit/$flag /etc/runit/$flag; done
ln -sfn /bin/busybox /sbin/mdev
chmod 755 /etc/runit/[123] /usr/local/bin/*
# No systemd service manager, udev or D-Bus daemons.
test ! -x /lib/systemd/systemd
test ! -x /lib/systemd/systemd-udevd
test ! -x /usr/bin/dbus-daemon
test ! -e /lib/systemd/system/ModemManager.service
for command in reboot poweroff; do ln -sfn /usr/local/bin/$command /sbin/$command; done
ln -sfn /usr/local/bin/poweroff /sbin/halt
