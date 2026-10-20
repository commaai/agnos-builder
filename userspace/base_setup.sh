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
    apport \
    apport-retrace \
    bc \
    build-essential \
    busybox-static \
    chrony \
    dnsmasq-base \
    gdb \
    git \
    iptables-persistent \
    iputils-ping \
    jq \
    kmod \
    less \
    libc6-dev \
    libcurl3t64-gnutls \
    libegl-dev \
    libegl1 \
    libgles-dev \
    libgles1 \
    libgles2 \
    libglib2.0-dev \
    libjansson4 \
    libndp0 \
    libnss-mdns \
    libnss-myhostname \
    libpsl5t64 \
    llvm-20 \
    locales \
    lsof \
    openssh-client \
    openssh-server \
    openssl \
    ppp \
    psmisc \
    python3-dev \
    rsync \
    runit \
    strace \
    systemd-standalone-sysusers \
    tmux \
    udev \
    usbutils \
    vim \
    wpasupplicant

# Create the privileged user and hardware access groups.
useradd -G sudo -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWD" | chpasswd
groupadd gpio
groupadd gpu
usermod -aG root,video,gpio,adm,gpu,audio,disk,dialout,netdev "$USERNAME"
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

# Versioned LLVM packages don't provide the unversioned commands.
for tool in /usr/lib/llvm-20/bin/*; do
  ln -sf "$tool" "/usr/local/bin/$(basename "$tool")"
done

rm -rf /var/lib/apt/lists/*
