#!/bin/bash -e

USERNAME=comma
PASSWD=comma
HOST=comma

# Create identification file
touch /TICI
touch /AGNOS

# Set up usr-merged lib64 since it's not done by default in 24.04-base.
mkdir -p /usr/lib64
ln -sTfn usr/lib64 /lib64

# Install apt-fast
apt-get update
apt-get install -yq curl sudo wget
bash -c "$(curl -sL https://git.io/vokNn)"

# Install packages
export DEBIAN_FRONTEND=noninteractive
apt-fast upgrade -yq
apt-fast install --no-install-recommends -yq \
    adduser \
    alsa-utils \
    apport-retrace \
    bc \
    build-essential \
    curl \
    cpuset \
    dnsmasq-base \
    evtest \
    git \
    git-core \
    git-lfs \
    gdb \
    hostapd \
    htop \
    i2c-tools \
    ifmetric \
    ifupdown \
    iputils-ping \
    iptables-persistent \
    isc-dhcp-client \
    jq \
    kmod \
    landscape-common \
    libc6-dev \
    libegl1 \
    libegl-dev \
    libffi-dev \
    libgdbm-dev \
    libgles1 \
    libgles2 \
    libgles-dev \
    libgtk2.0-dev \
    libi2c-dev \
    libncursesw5-dev \
    libnss-myhostname \
    libqmi-utils \
    libssl-dev \
    locales \
    llvm \
    nano \
    net-tools \
    nload \
    network-manager \
    openssl \
    openssh-server \
    ppp \
    rsyslog \
    ssh \
    sudo \
    systemd \
    systemd-resolved \
    systemd-timesyncd \
    ubuntu-minimal \
    ubuntu-server \
    ubuntu-standard \
    udev \
    udhcpc \
    wget \
    wireless-tools \
    wpasupplicant \
    zlib1g-dev

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

# Disable pstore service that moves files out of /sys/fs/pstore
systemctl disable systemd-pstore.service

# Nopasswd sudo
echo "comma ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# setup /bin/sh symlink
ln -sf /bin/bash /bin/sh

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
adduser $USERNAME netdev
adduser $USERNAME dialout
adduser $USERNAME systemd-journal

# Create dirs
mkdir /data && chown $USERNAME:$USERNAME /data
mkdir /persist && chown $USERNAME:$USERNAME /persist
mkdir /config && chown root:root /config
