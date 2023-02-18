#/usr/bin/env bash

source /etc/profile

SETUP="/usr/comma/setup"
RESET="/usr/comma/reset"
CONTINUE="/data/continue.sh"
INSTALLER="/tmp/installer"
RESET_TRIGGER="/data/__system_reset__"


echo "Waiting for wayland"
while [ ! -e "$XDG_RUNTIME_DIR/wayland-0" ]; do sleep 0.1; done
sleep 0.5  # weston's still starting after the socket's created
echo "wayland ready"
sudo chmod -R 770 $XDG_RUNTIME_DIR

sudo chown comma: /data
sudo chown comma: /data/media

sudo su -c "echo 500 > /sys/devices/platform/soc/ae00000.qcom,mdss_mdp/backlight/panel0-backlight/brightness"

handle_setup_keys () {
  # install default SSH key while still in setup
  if [[ ! -e /data/params/d/GithubSshKeys && ! -e /data/continue.sh ]]; then
    if [ ! -e /data/params/d ]; then
      mkdir -p /data/params/d_tmp
      ln -s /data/params/d_tmp /data/params/d
    fi

    echo -n 1 > /data/params/d/SshEnabled
    cp /usr/comma/setup_keys /data/params/d/GithubSshKeys
  elif [[ -e /data/params/d/GithubSshKeys && -e /data/continue.sh ]]; then
    if cmp -s /data/params/d/GithubSshKeys /usr/comma/setup_keys; then
      rm /data/params/d/SshEnabled
      rm /data/params/d/GithubSshKeys
    fi
  fi
}

if [ -f "$RESET_TRIGGER" ]; then
  echo "launching system reset"
  rm -f $RESET_TRIGGER
  $RESET
fi

# load system reset if userdata is not mounted
if ! mountpoint -q /data; then
  echo "userdata not mounted. loading system reset"
  $RESET --recover
fi

# symlink vscode to userdata
mkdir -p /data/tmp/vscode-server
ln -s /data/tmp/vscode-server ~/.vscode-server

# set time from panda
# sudo because udev isn't ready yet
sudo $(which python3) /usr/comma/set_time.py


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
    sleep 1
  done

  # run installer and wait for continue.sh
  chmod +x $INSTALLER
  $INSTALLER &
  echo "running installer"
  while [ ! -f $CONTINUE ] && ps -p $! > /dev/null; do
    sleep 1
  done
done
