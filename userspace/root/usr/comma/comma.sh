#/usr/bin/env bash

source /etc/profile

SETUP="/usr/comma/setup"
RESET="/usr/comma/reset"
CONTINUE="/data/continue.sh"
INSTALLER="/tmp/installer"
RESET_TRIGGER="/data/__system_reset__"

# blip power to ~5W to see if the PSU is stable
if grep -q mici /sys/firmware/devicetree/base/model; then
  sudo timeout --kill-after=2 5 /home/comma/power_burn_max 0.3 2 &
fi

echo "waiting for magic"
for i in {1..2000}; do
  if [ -S /tmp/drmfd.sock ]; then
    break
  fi
  sleep 0.01
done

if [ -S /tmp/drmfd.sock ]; then
  echo "magic ready after ${SECONDS}s"
else
  echo "timed out waiting for magic, ${SECONDS}s"
fi

handle_setup_keys () {
  # install default SSH key while still in setup
  if [[ ! -s /data/params/d/GithubSshKeys && ! -e /data/continue.sh ]]; then
    if [ ! -e /data/params/d ]; then
      mkdir -p /data/params/d_tmp
      ln -s /data/params/d_tmp /data/params/d
    fi

    echo -n 1 > /data/params/d/AdbEnabled
    echo -n 1 > /data/params/d/SshEnabled
    # a power cut can leave these empty. GithubSshKeys goes last and is checked above, so that redoes them next boot
    sync /data/params/d/AdbEnabled /data/params/d/SshEnabled
    cp /usr/comma/setup_keys /data/params/d/GithubSshKeys
  elif [[ -e /data/params/d/GithubSshKeys && -e /data/continue.sh ]]; then
    if cmp -s /data/params/d/GithubSshKeys /usr/comma/setup_keys; then
      rm /data/params/d/AdbEnabled
      rm /data/params/d/SshEnabled
      rm /data/params/d/GithubSshKeys
    fi
  fi
}

launch_reset () {
  # A restarted app service can leave updater overlays mounted below /data.
  # Remove children before parents, without detaching /data or hiding a busy
  # filesystem behind a lazy unmount. findmnt raw output escapes whitespace.
  local -a reset_mounts
  local i target reset_tree
  if ! reset_tree=$(findmnt --submounts --raw --noheadings --output TARGET /data); then
    if mountpoint -q /data; then
      echo "Cannot reset: failed to inspect mounts under /data" >&2
      return 1
    fi
  fi
  mapfile -t reset_mounts <<< "$reset_tree"
  for ((i=${#reset_mounts[@]}-1; i>=0; i--)); do
    printf -v target '%b' "${reset_mounts[i]}"
    if [[ "$target" == /data/* ]]; then
      if ! sudo umount -- "$target"; then
        echo "Cannot reset: failed to unmount $target" >&2
        return 1
      fi
    fi
  done
  "$RESET" "$@"
}

# factory reset handling
if [ ! -f /run/comma-booted ]; then
  if [ -f "$RESET_TRIGGER" ]; then
    echo "launching system reset, reset trigger present"
    launch_reset || exit 1
    rm -f $RESET_TRIGGER
  elif (( "$(cat /sys/class/input/input2/device/touch_count)" > 4 )); then
    echo "launching system reset, got taps"
    launch_reset --tap-reset || exit 1
  elif ! mountpoint -q /data; then
    echo "userdata not mounted. loading system reset"
    launch_reset --recover || exit 1
  fi
  sudo touch /run/comma-booted
fi

# symlink vscode to userdata
mkdir -p /data/tmp/vscode-server
ln -s /data/tmp/vscode-server ~/.vscode-server
ln -s /data/tmp/vscode-server ~/.cursor-server
ln -s /data/tmp/vscode-server ~/.windsurf-server

while true; do
  handle_setup_keys

  if [ -f $CONTINUE ]; then
    exec "$CONTINUE"
  fi

  # cleanup installers from previous runs
  rm -f $INSTALLER

  # run setup first, it only needs the screen. the rest can happen while it starts
  "$SETUP" &
  pkill -f $INSTALLER
  sudo abctl --set_success

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
  pkill -f "$SETUP"
done
