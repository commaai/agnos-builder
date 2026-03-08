#!/bin/bash
# Initialize WCN3990 Bluetooth adapter on comma four

set -e

# Kill any stale hciattach
killall hciattach 2>/dev/null || true
sleep 1

# Power cycle BT chip via btpower ioctl (off then on)
python3 -c "import fcntl,os; fd=os.open('/dev/btpower',os.O_RDWR); fcntl.ioctl(fd,0xbfad,0); os.close(fd)" 2>/dev/null || true
sleep 2
python3 -c "import fcntl,os; fd=os.open('/dev/btpower',os.O_RDWR); fcntl.ioctl(fd,0xbfad,1); os.close(fd)"
sleep 3

# Unblock bluetooth
rfkill unblock bluetooth
sleep 1

# Attach UART — forks a daemon child that maintains hci0
hciattach -s 115200 /dev/ttyHS1 qualcomm 115200 flow

# Wait for hci0 to appear (hciattach daemon initializes async)
for i in $(seq 1 10); do
  hciconfig hci0 up 2>/dev/null && break
  sleep 1
done
