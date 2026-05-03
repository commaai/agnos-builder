#/usr/bin/env bash

source /etc/profile

SETUP="/usr/comma/setup"
RESET="/usr/comma/reset"
CONTINUE="/data/continue.sh"
INSTALLER="/tmp/installer"
RESET_TRIGGER="/data/__system_reset__"

# blip power to ~10W to see if the PSU is stable
sudo timeout --kill-after=2 5 /home/comma/power_burn_max

# use max freq to boot up quickly, then limit
limit_cpu_policy() {
  local policy="$1"
  local freq="$2"

  if [ -e "$policy/scaling_min_freq" ]; then
    echo "$freq" | sudo tee "$policy/scaling_min_freq" >/dev/null 2>&1 || true
  fi
  if [ -e "$policy/scaling_max_freq" ]; then
    echo "$freq" | sudo tee "$policy/scaling_max_freq" >/dev/null 2>&1 || true
  fi
}

limit_cpu_policy /sys/devices/system/cpu/cpufreq/policy0 1689600
limit_cpu_policy /sys/devices/system/cpu/cpufreq/policy4 1689600

echo "waiting for magic"
for i in {1..200}; do
  if systemctl is-active --quiet magic && [ -S /tmp/drmfd.sock ]; then
    break
  fi
  sleep 0.1
done

if systemctl is-active --quiet magic && [ -S /tmp/drmfd.sock ]; then
  echo "magic ready after ${SECONDS}s"
else
  echo "timed out waiting for magic, ${SECONDS}s"
fi

sudo chown comma: /data
sudo chown comma: /data/media

handle_setup_keys () {
  # install default SSH key while still in setup
  if [[ ! -e /data/params/d/GithubSshKeys && ! -e /data/continue.sh ]]; then
    if [ ! -e /data/params/d ]; then
      mkdir -p /data/params/d_tmp
      ln -s /data/params/d_tmp /data/params/d
    fi

    echo -n 1 > /data/params/d/AdbEnabled
    echo -n 1 > /data/params/d/SshEnabled
    cp /usr/comma/setup_keys /data/params/d/GithubSshKeys
  elif [[ -e /data/params/d/GithubSshKeys && -e /data/continue.sh ]]; then
    if cmp -s /data/params/d/GithubSshKeys /usr/comma/setup_keys; then
      rm /data/params/d/AdbEnabled
      rm /data/params/d/SshEnabled
      rm /data/params/d/GithubSshKeys
    fi
  fi
}

mark_boot_success() {
  local i out

  for i in {1..20}; do
    if out="$(sudo abctl --set_success 2>&1)"; then
      return 0
    fi

    echo "abctl --set_success failed ($i/20): $out"
    sleep 0.25
  done

  return 1
}

# factory reset handling
if [ ! -f /tmp/booted ]; then
  touch /tmp/booted
  if [ -f "$RESET_TRIGGER" ]; then
    echo "launching system reset, reset trigger present"
    rm -f $RESET_TRIGGER
    $RESET
  elif (( "$(cat /sys/class/input/input2/device/touch_count)" > 4 )); then
    echo "launching system reset, got taps"
    $RESET --tap-reset
  elif ! mountpoint -q /data; then
    echo "userdata not mounted. loading system reset"
    $RESET --recover
  fi
fi

# setup /data/tmp
rm -rf /data/tmp
mkdir -p /data/tmp

# symlink vscode to userdata
mkdir -p /data/tmp/vscode-server
ln -s /data/tmp/vscode-server ~/.vscode-server
ln -s /data/tmp/vscode-server ~/.cursor-server
ln -s /data/tmp/vscode-server ~/.windsurf-server

while true; do
  pkill -f "$SETUP"
  handle_setup_keys

  if [ -f $CONTINUE ]; then
    exec "$CONTINUE"
  fi

  mark_boot_success

  # cleanup installers from previous runs
  rm -f $INSTALLER
  pkill -f $INSTALLER

  # run setup and wait for installer
  $SETUP &
  echo "waiting for installer"
  while [ ! -f $INSTALLER ]; do
    sleep 0.1
  done

  # run installer and wait for continue.sh
  chmod +x $INSTALLER
  $INSTALLER &
  echo "running installer"
  while [ ! -f $CONTINUE ] && ps -p $! > /dev/null; do
    sleep 0.1
  done
done
