#!/bin/bash
set -e

USERNAME=comma
PASSWD=comma
HOST=comma

# Create identification file
touch /TICI
touch /AGNOS

xbps-install -Syu xbps -y
xbps-install -Syu -y

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
  ca-certificates \
  alsa-utils \
  avahi \
  avahi-utils \
  base-devel \
  bash-completion \
  bc \
  bluez \
  btop \
  busybox \
  bzip2-devel \
  clang \
  cmake \
  cronie \
  czmq-devel \
  dbus-devel \
  dfu-util \
  dhcpcd \
  dnsmasq \
  eudev \
  evtest \
  ffmpeg6 \
  ffmpeg-devel \
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
  hyperfine \
  i2c-tools \
  inotify-tools \
  iperf \
  iperf3 \
  iproute2 \
  iptables \
  iputils \
  iw \
  jq \
  kmod \
  libarchive-devel \
  libcap-progs \
  libcurl-devel \
  libffi-devel \
  libgpiod \
  libjpeg-turbo-devel \
  liblzma-devel \
  libomp-devel \
  libqmi \
  libqmi-devel \
  libtool \
  libusb-devel \
  libuv-devel \
  libzstd-devel \
  llvm \
  logrotate \
  lz4 \
  mesa-dri \
  ModemManager \
  ModemManager-devel \
  nano \
  ncdu \
  ncurses-devel \
  ncurses-term \
  net-tools \
  NetworkManager \
  nfs-utils \
  nload \
  ocl-icd \
  ocl-icd-devel \
  opencl-headers \
  openssh \
  openssl-devel \
  polkit \
  portaudio-devel \
  ppp \
  procps-ng \
  pv \
  python3 \
  python3-devel \
  python3-pip \
  ripgrep \
  rsync \
  rsyslog \
  SDL2-devel \
  smartmontools \
  socat \
  sqlite-devel \
  squashfs-tools \
  stress-ng \
  tmux \
  traceroute \
  tree \
  usbutils \
  util-linux \
  vim \
  wavemon \
  wireless_tools \
  wpa_supplicant \
  zeromq-devel \
  zlib-devel \
  zstd

# set kernel params
echo "net.ipv4.conf.all.rp_filter = 2" >> /etc/sysctl.conf
echo "vm.dirty_expire_centisecs = 200" >> /etc/sysctl.conf

# raise comma user's process priority limits
echo "comma - rtprio 100" >> /etc/security/limits.conf
echo "comma - nice -10" >> /etc/security/limits.conf

# Locale setup
echo "en_US.UTF-8 UTF-8" >> /etc/default/libc-locales
xbps-reconfigure -f glibc-locales

# Nopasswd sudo
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel
echo "comma ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/comma
chmod 440 /etc/sudoers.d/wheel /etc/sudoers.d/comma

# setup /bin/sh symlink
ln -sf /usr/bin/bash /bin/sh

# Create privileged user
useradd -m -s /usr/bin/bash $USERNAME
echo "$USERNAME:$PASSWD" | chpasswd
groupadd -f gpio
groupadd -f gpu
usermod -aG wheel,root,video,gpio,gpu,audio,disk,dialout "$USERNAME"
if getent group bluetooth >/dev/null; then
  usermod -aG bluetooth "$USERNAME"
fi

# Create dirs
mkdir -p /data /persist /config /system
chown $USERNAME:$USERNAME /data /persist
chown root:root /config

rm -f /etc/runit/runsvdir/default/agetty-tty{1,2,3,4,5,6}
ln -sf /etc/sv/agetty-ttyMSM0 /etc/runit/runsvdir/default/ 2>/dev/null || true
ln -sf /etc/sv/agetty-ttyAMA0 /etc/runit/runsvdir/default/ 2>/dev/null || true

export XDG_DATA_HOME="/usr/local"
export UV_INSTALL_DIR="/usr/local/bin"
curl -LsSf https://astral.sh/uv/install.sh | sh
ln -sf /usr/local/bin/uv /usr/bin/uv

/usr/local/bin/uv python install 3.12
/usr/local/bin/uv venv "$XDG_DATA_HOME/venv" --seed --python 3.12
