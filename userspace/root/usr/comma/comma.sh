#/usr/bin/env bash

source /etc/profile

SETUP="/usr/comma/setup"
# PYTHONPATH from /etc/profile points into /data. The reset UI must not import from
# there, or it keeps /data busy and can't unmount it to reformat it.
RESET="env -u PYTHONPATH /usr/comma/reset"
CONTINUE="/data/continue.sh"
INSTALLER="/tmp/installer"
RESET_TRIGGER="/data/__system_reset__"

# blip power to ~5W to see if the PSU is stable
if grep -q mici /sys/firmware/devicetree/base/model; then
  sudo timeout --kill-after=2 5 /home/comma/power_burn_max 0.3 2
fi

# use max freq to boot up quickly, then limit
echo 1689600 | sudo tee /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
echo 1689600 | sudo tee /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq

# magic creates its socket on tmpfs after it has drawn the boot background.
# Don't ask systemd: systemctl blocks while PID 1 reloads, and NetworkManager
# triggers a ~1 s daemon-reload (netplan generate) right at this point in boot.
echo "waiting for magic"
for i in {1..200}; do
  if [ -S /tmp/drmfd.sock ]; then
    break
  fi
  sleep 0.1
done

if [ -S /tmp/drmfd.sock ]; then
  echo "magic ready after ${SECONDS}s"
else
  echo "timed out waiting for magic, ${SECONDS}s"
fi

sudo chown comma: /data
sudo chown comma: /data/media

handle_setup_keys () {
  # install default SSH key while still in setup
  if [[ ! -e /data/params/d/GithubSshKeys && ! -e /data/continue.sh ]]; then
    local params=/data/params/d
    if [ ! -e $params ]; then
      # fill a fresh params dir before linking it, so the watchers never see it half-populated
      params=/data/params/d_tmp
      mkdir -p $params
    fi

    echo -n 1 > $params/AdbEnabled
    echo -n 1 > $params/SshEnabled
    cp /usr/comma/setup_keys $params/GithubSshKeys
    [ -e /data/params/d ] || ln -s /data/params/d_tmp /data/params/d

    # The watchers' boot-time run can still be active here, and systemd drops
    # path triggers for an active unit, so apply the params explicitly.
    sudo systemctl restart adb-param-watcher.service ssh-param-watcher.service
  elif [[ -e /data/params/d/GithubSshKeys && -e /data/continue.sh ]]; then
    if cmp -s /data/params/d/GithubSshKeys /usr/comma/setup_keys; then
      rm /data/params/d/AdbEnabled
      rm /data/params/d/SshEnabled
      rm /data/params/d/GithubSshKeys
    fi
  fi
}

# factory reset handling
if [ ! -f /run/comma-booted ]; then
  sudo touch /run/comma-booted
  touch_count=0
  for touch_counter in /sys/class/input/input*/device/touch_count; do
    if [ -r "$touch_counter" ]; then
      read -r touch_count < "$touch_counter"
      break
    fi
  done
  if [ -f "$RESET_TRIGGER" ]; then
    echo "launching system reset, reset trigger present"
    rm -f $RESET_TRIGGER
    $RESET
  elif [[ "$touch_count" =~ ^[0-9]+$ ]] && (( 10#$touch_count > 4 )); then
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

  sudo abctl --set_success

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
