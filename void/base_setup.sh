#!/bin/bash
set -e

USERNAME=comma
PASSWD=comma

# Create identification files
touch /TICI
touch /AGNOS

# Update xbps first, then package database
xbps-install -Syu xbps -y
xbps-install -Syu

# Install all packages in one command to avoid "already installed" errors
# xbps handles duplicates gracefully when in a single invocation
xbps-install -y \
  base-minimal \
  runit-void \
  bash \
  coreutils \
  glibc-locales \
  sudo \
  shadow \
  curl \
  wget \
  alsa-utils \
  avahi \
  base-devel \
  bc \
  busybox \
  bzip2-devel \
  clang \
  cmake \
  czmq-devel \
  dbus-devel \
  dfu-util \
  dhcpcd \
  dnsmasq \
  eigen \
  evtest \
  freetype-devel \
  fuse-sshfs \
  gdb \
  gdbm-devel \
  git \
  git-lfs \
  glfw-devel \
  glib-devel \
  hostapd \
  htop \
  i2c-tools \
  inotify-tools \
  iproute2 \
  iputils \
  jq \
  kmod \
  libarchive-devel \
  libcurl-devel \
  libffi-devel \
  libgpiod \
  libjpeg-turbo-devel \
  liblzma-devel \
  libomp-devel \
  libtool \
  libusb-devel \
  libuv-devel \
  libzstd-devel \
  llvm \
  logrotate \
  lz4 \
  nano \
  ncurses-devel \
  net-tools \
  NetworkManager \
  nload \
  opencl-headers \
  openssl-devel \
  portaudio-devel \
  ppp \
  pv \
  python3 \
  python3-devel \
  python3-pip \
  rsync \
  rsyslog \
  SDL2-devel \
  smartmontools \
  sqlite-devel \
  squashfs-tools \
  tmux \
  traceroute \
  wireless_tools \
  wpa_supplicant \
  zeromq-devel \
  zlib-devel \
  zstd \
  capnproto \
  capnproto-devel \
  x264-devel \
  nasm \
  libqmi \
  libqmi-devel \
  ModemManager \
  ModemManager-devel \
  cronie

# Create privileged user (use /usr/bin/bash - Void Linux path)
useradd -m -s /usr/bin/bash $USERNAME
echo "$USERNAME:$PASSWD" | chpasswd
groupadd -f gpio
groupadd -f gpu
usermod -aG wheel,video,audio,disk,dialout,gpio,gpu $USERNAME

# Set kernel params
echo "net.ipv4.conf.all.rp_filter = 2" >> /etc/sysctl.conf
echo "vm.dirty_expire_centisecs = 200" >> /etc/sysctl.conf

# Raise comma user's process priority limits
echo "comma - rtprio 100" >> /etc/security/limits.conf
echo "comma - nice -10" >> /etc/security/limits.conf

# Locale setup
echo "en_US.UTF-8 UTF-8" >> /etc/default/libc-locales
xbps-reconfigure -f glibc-locales

# Create dirs
mkdir -p /data /persist /config /system
chown $USERNAME:$USERNAME /data
chown $USERNAME:$USERNAME /persist
chown root:root /config

# Nopasswd sudo for wheel group (Void uses wheel, not sudo group)
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel

# Nopasswd sudo for comma specifically
echo "comma ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/comma

# Setup /bin/sh symlink to bash
ln -sf /usr/bin/bash /bin/sh

# Enable essential services
ln -sf /etc/sv/dbus /etc/runit/runsvdir/default/
ln -sf /etc/sv/NetworkManager /etc/runit/runsvdir/default/
ln -sf /etc/sv/sshd /etc/runit/runsvdir/default/
ln -sf /etc/sv/avahi-daemon /etc/runit/runsvdir/default/
ln -sf /etc/sv/cronie /etc/runit/runsvdir/default/

# Disable all virtual ttys (only serial console needed)
rm -f /etc/runit/runsvdir/default/agetty-tty1
rm -f /etc/runit/runsvdir/default/agetty-tty2
rm -f /etc/runit/runsvdir/default/agetty-tty3
rm -f /etc/runit/runsvdir/default/agetty-tty4
rm -f /etc/runit/runsvdir/default/agetty-tty5
rm -f /etc/runit/runsvdir/default/agetty-tty6

# Enable serial console (ttyMSM0 for hardware, ttyAMA0 for QEMU)
ln -sf /etc/sv/agetty-ttyMSM0 /etc/runit/runsvdir/default/ 2>/dev/null
ln -sf /etc/sv/agetty-ttyAMA0 /etc/runit/runsvdir/default/ 2>/dev/null

# Install uv (Python package manager)
export XDG_DATA_HOME="/usr/local"
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

# Install Python 3.12 via uv (Void has 3.14 which is too new)
uv python install 3.12

# Create venv with Python 3.12
uv venv $XDG_DATA_HOME/venv --seed --python 3.12

echo "base_setup.sh complete"
