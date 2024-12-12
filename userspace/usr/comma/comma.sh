#/usr/bin/env bash

source /etc/profile

SETUP="/usr/comma/setup"
RESET="/usr/comma/reset"
CONTINUE="/data/continue.sh"
INSTALLER="/tmp/installer"
RESET_TRIGGER="/data/__system_reset__"

echo "waiting for weston"
for i in {1..200}; do
  if systemctl is-active --quiet weston-ready; then
    break
  fi
  sleep 0.1
done

if systemctl is-active --quiet weston-ready; then
  echo "weston ready after ${SECONDS}s"
else
  echo "timed out waiting for weston, ${SECONDS}s"
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

    echo -n 1 > /data/params/d/SshEnabled
    cp /usr/comma/setup_keys /data/params/d/GithubSshKeys
  elif [[ -e /data/params/d/GithubSshKeys && -e /data/continue.sh ]]; then
    if cmp -s /data/params/d/GithubSshKeys /usr/comma/setup_keys; then
      rm /data/params/d/SshEnabled
      rm /data/params/d/GithubSshKeys
    fi
  fi
}

handle_adb () {
  # Try to configure USB controller through configfs
  sudo mkdir -p /sys/kernel/config/usb_gadget/g1 2>/dev/null || true
  
  cd /sys/kernel/config/usb_gadget/g1
  
  # Basic USB configuration
  sudo sh -c 'echo "0x18d1" > idVendor'  # Google vendor ID
  sudo sh -c 'echo "0x2d01" > idProduct'  # Generic ADB product ID
  
  # Create strings directory and add basic info
  sudo mkdir -p strings/0x409
  sudo sh -c 'echo "Comma.ai" > strings/0x409/manufacturer'
  sudo sh -c 'echo "Comma Device" > strings/0x409/product'
  
  # Create configuration
  sudo mkdir -p configs/c.1/strings/0x409
  sudo sh -c 'echo "ADB Configuration" > configs/c.1/strings/0x409/configuration'
  
  # Create function
  sudo mkdir -p functions/ffs.adb
  sudo ln -s functions/ffs.adb configs/c.1

  sudo mount -o remount,rw /
  sudo cp /usr/comma/99-android.rules /etc/udev/rules.d/99-android.rules
  sudo chmod 777 /etc/udev/rules.d/99-android.rules
  sudo chmod a+r /etc/udev/rules.d/99-android.rules
  
  # Create plugdev group if it doesn't exist
  sudo groupadd -f plugdev
  sudo usermod -aG plugdev comma
  
  # Restart udev and ADB with debug logging
  sudo service udev restart
  sudo udevadm control --reload-rules
  sudo udevadm trigger
  
  sudo systemctl restart adbd
  
  # Print ADB status for debugging
  systemctl status adbd
  
  sudo mount -o remount,ro /
}

# factory reset handling
if [ -f "$RESET_TRIGGER" ]; then
  echo "launching system reset, reset trigger present"
  rm -f $RESET_TRIGGER
  $RESET
elif (( "$(cat /sys/devices/platform/soc/894000.i2c/i2c-2/2-0017/touch_count)" > 4 )); then
  echo "launching system reset, got taps"
  $RESET
elif ! mountpoint -q /data; then
  echo "userdata not mounted. loading system reset"
  if [ "$(head -c 15 /dev/disk/by-partlabel/userdata)" == "COMMA_RESET" ]; then
    $RESET --format
  else
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

while true; do
  pkill -f "$SETUP"
  handle_setup_keys

  echo "adb setup"
  handle_adb

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
