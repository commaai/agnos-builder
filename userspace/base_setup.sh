#!/bin/bash -e

USERNAME=comma
PASSWD=comma
HOST=comma

# Create identification file
touch /TICI
touch /AGNOS

# Install apt-fast
apt-get update
apt-get install -yq curl sudo wget
bash -c "$(curl -sL https://git.io/vokNn)"

# Install packages
export DEBIAN_FRONTEND=noninteractive
apt-fast install --no-install-recommends -yq locales systemd adduser

# Create privileged user
useradd -G sudo -m -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWD" | chpasswd
groupadd gpio
groupadd gpu
adduser $USERNAME root
adduser $USERNAME video
adduser $USERNAME gpio
adduser $USERNAME adm
adduser $USERNAME gpu
adduser $USERNAME audio
adduser $USERNAME disk
adduser $USERNAME dialout
adduser $USERNAME systemd-journal

# Enable serial console on UART
systemctl enable serial-getty@ttyS0.service

# set kernel params
echo "net.ipv4.conf.all.rp_filter = 2" >> /etc/sysctl.conf
echo "vm.dirty_expire_centisecs = 200" >> /etc/sysctl.conf

# raise comma user's process priority limits
echo "comma - rtprio 100" >> /etc/security/limits.conf
echo "comma - nice -10" >> /etc/security/limits.conf

# Locale setup
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

apt-fast upgrade -yq
apt-fast install --no-install-recommends -yq \
    alsa-utils \
    apport-retrace \
    bc \
    build-essential \
    bzip2 \
    curl \
    cpuset \
    dfu-util \
    evtest \
    git \
    git-core \
    git-lfs \
    gdb \
    htop \
    i2c-tools \
    ifmetric \
    ifupdown \
    iptables-persistent \
    jq \
    landscape-common \
    libi2c-dev \
    libqmi-utils \
    libtool \
    libncursesw5-dev \
    libnss-myhostname \
    libgdbm-dev \
    libc6-dev \
    libsqlite3-dev \
    libssl-dev \
    libffi-dev \
    llvm \
    nano \
    net-tools \
    nload \
    network-manager \
    openssl \
    ppp \
    smartmontools \
    speedtest-cli \
    squashfs-tools \
    ssh \
    sshfs \
    sudo \
    systemd-resolved \
    systemd-timesyncd \
    traceroute \
    tk-dev \
    ubuntu-minimal \
    ubuntu-server \
    ubuntu-standard \
    udev \
    udhcpc \
    wget \
    wireless-tools \
    zlib1g-dev

rm -rf /var/lib/apt/lists/*

# Create dirs
mkdir /data && chown $USERNAME:$USERNAME /data
mkdir /persist && chown $USERNAME:$USERNAME /persist
mkdir /config && chown root:root /config

# Disable pstore service that moves files out of /sys/fs/pstore
systemctl disable systemd-pstore.service

# Nopasswd sudo
echo "comma ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# setup /bin/sh symlink
ln -sf /bin/bash /bin/sh

# Install necessary libs
apt-fast update -yq
apt-fast install --no-install-recommends -yq \
    libegl1 \
    libegl-dev \
    libgles1 \
    libgles2 \
    libgles-dev \
    libx264-dev \
    openssh-server \
    dnsmasq-base \
    dhcpcd-base \
    isc-dhcp-client \
    iputils-ping \
    rsyslog \
    kmod \
    wpasupplicant \
    hostapd \
    libgtk2.0-dev

# Install driver deb files (we're fine with overwriting stuff too)
cd /tmp/agnos/debs

# Setting up usr merged lib64 since it's not done by default (in 24.04-base)
# https://wiki.debian.org/UsrMerge
# https://www.freedesktop.org/wiki/Software/systemd/TheCaseForTheUsrMerge/
mkdir /usr/lib64
ln -s usr/lib64 /lib64

apt-get -o Dpkg::Options::="--force-overwrite" install -yq \
  ./agnos-base_0.0.4.deb \
  ./agnos-display_0.0.4.deb \
  ./agnos-wlan_0.0.4.deb

# Install 16.04 version of libjson-c2
cd /tmp
wget http://ports.ubuntu.com/pool/main/j/json-c/libjson-c2_0.11-4ubuntu2.6_arm64.deb -O /tmp/libjson-c2_0.11-4ubuntu2.6_arm64.deb
apt install -yq /tmp/libjson-c2_0.11-4ubuntu2.6_arm64.deb

# Remove apt cache
rm -rf /var/lib/apt/lists/*

adduser $USERNAME netdev
