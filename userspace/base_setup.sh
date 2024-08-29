#!/bin/bash -e

USERNAME=comma
PASSWD=comma
HOST=comma

# Create identification file
touch /TICI
touch /AGNOS

# Install apt-fast
apt-get update
apt-get install --no-install-recommends -yq ca-certificates wget
bash -c "$(wget -qO- https://git.io/vokNn)"

apt-get upgrade -yq

apt-fast install -yq --no-install-recommends ubuntu-minimal

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

apt-fast install --no-install-recommends -yq \
    alsa-utils \
    apport-retrace \
    bc \
    build-essential \
    bzip2 \
    curl \
    chrony \
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
    libqmi-utils \
    libtool \
    llvm \
    nano \
    net-tools \
    nload \
    network-manager \
    nvme-cli \
    openssl \
    ppp \
    smartmontools \
    speedtest-cli \
    ssh \
    sshfs \
    sudo \
    systemd-resolved \
    traceroute \
    tk-dev \
    ubuntu-server \
    ubuntu-standard \
    udev \
    udhcpc \
    wget \
    wireless-tools

rm -rf /var/lib/apt/lists/*

# Allow chrony to make a big adjustment to system time on boot
echo "makestep 0.1 3" >> /etc/chrony/chrony.conf

# Create dirs
mkdir /data && chown $USERNAME:$USERNAME /data
mkdir /persist && chown $USERNAME:$USERNAME /persist

# Disable pstore service that moves files out of /sys/fs/pstore
systemctl disable systemd-pstore.service

# Nopasswd sudo
echo "comma ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# setup /bin/sh symlink
ln -sf /bin/bash /bin/sh

# Install necessary libs
apt-fast update -yq
apt-fast install --no-install-recommends -yq \
    openssh-server \
    dnsmasq-base \
    isc-dhcp-client \
    iputils-ping \
    rsyslog \
    kmod \
    wpasupplicant \
    hostapd
