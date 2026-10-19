#!/bin/bash -e

USERNAME=comma
PASSWD=comma
export DEBIAN_FRONTEND=noninteractive

# Identify this image to openpilot.
touch /TICI /AGNOS

# Install apt-fast.
apt-get update
apt-get install --no-install-recommends -yq ca-certificates curl sudo wget
bash -c "$(curl -fsSL https://git.io/vokNn)"

# Base packages, development tools, and networking.
apt-fast upgrade -yq
apt-fast install --no-install-recommends -yq \
    adduser \
    alsa-utils \
    apport-retrace \
    bc \
    build-essential \
    byobu \
    bzip2 \
    cpuset \
    dfu-util \
    dhcpcd-base \
    dirmngr \
    dnsmasq-base \
    evtest \
    fdisk \
    fontconfig \
    fonts-ubuntu-console \
    gdb \
    git \
    gnupg \
    htop \
    i2c-tools \
    ifmetric \
    iptables-persistent \
    iputils-ping \
    isc-dhcp-client \
    jq \
    kmod \
    libc6-dev \
    libegl-dev \
    libegl1 \
    libffi-dev \
    libgdbm-dev \
    libgles-dev \
    libgles1 \
    libgles2 \
    libi2c-dev \
    libncursesw5-dev \
    libnss-myhostname \
    libsqlite3-dev \
    libssl-dev \
    libtool \
    libx264-dev \
    llvm \
    locales \
    nano \
    net-tools \
    network-manager \
    nload \
    openssh-client \
    openssh-server \
    openssl \
    patch \
    pollinate \
    ppp \
    rsyslog \
    screen \
    smartmontools \
    software-properties-common \
    speedtest-cli \
    sshfs \
    systemd \
    systemd-resolved \
    systemd-timesyncd \
    tk-dev \
    tmux \
    traceroute \
    ubuntu-minimal \
    ubuntu-standard \
    udev \
    udhcpc \
    vim \
    wireless-tools \
    wpasupplicant \
    zlib1g-dev

# Create the privileged user and hardware access groups.
useradd -G sudo -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWD" | chpasswd
groupadd gpio
groupadd gpu
usermod -aG root,video,gpio,adm,gpu,audio,disk,dialout,systemd-journal,netdev "$USERNAME"
echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Kernel and scheduling settings.
echo "net.ipv4.conf.all.rp_filter = 2" >> /etc/sysctl.conf
echo "vm.dirty_expire_centisecs = 200" >> /etc/sysctl.conf
echo "$USERNAME - rtprio 100" >> /etc/security/limits.conf
echo "$USERNAME - nice -10" >> /etc/security/limits.conf

locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

install -d -o "$USERNAME" -g "$USERNAME" /data /persist
install -d /config
ln -sf /bin/bash /bin/sh

# Ubuntu Base doesn't provide the merged /lib64 directory.
mkdir /usr/lib64
ln -s usr/lib64 /lib64

# Install Ubuntu's graphics development files before replacing their libraries.
/tmp/agnos/openpilot_dependencies.sh

# Qualcomm driver packages.
cd /tmp/agnos/debs
apt-get --no-install-recommends -o Dpkg::Options::="--force-overwrite" install -yq \
  ./agnos-base_0.0.4.deb \
  ./agnos-display_0.0.4.deb \
  ./agnos-wlan_0.0.4.deb

# pdmappersvc requires the Ubuntu 16.04 version of libjson-c2.
cd /tmp
wget http://ports.ubuntu.com/pool/main/j/json-c/libjson-c2_0.11-4ubuntu2.6_arm64.deb -O /tmp/libjson-c2_0.11-4ubuntu2.6_arm64.deb
apt-get install --no-install-recommends -yq /tmp/libjson-c2_0.11-4ubuntu2.6_arm64.deb

rm -rf /var/lib/apt/lists/*
