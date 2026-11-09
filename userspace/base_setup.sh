#!/bin/bash -e

USERNAME=comma
PASSWD=comma
export DEBIAN_FRONTEND=noninteractive

# Identify this image to openpilot.
touch /TICI /AGNOS

# Install package management prerequisites.
apt-get update
apt-get install --no-install-recommends -yq ca-certificates curl sudo wget

# Base packages, development tools, and networking.
apt-get upgrade -yq
apt-get install --no-install-recommends -yq \
    adduser \
    alsa-utils \
    apport \
    apport-retrace \
    bc \
    dnsmasq-base \
    gdb \
    git \
    iproute2 \
    iptables-persistent \
    iputils-ping \
    jq \
    kmod \
    less \
    libc6-dev \
    libegl-dev \
    libegl1 \
    libgles-dev \
    libgles1 \
    libgles2 \
    libnss-myhostname \
    libpam-systemd \
    llvm-20 \
    locales \
    lsof \
    make \
    openssh-client \
    openssh-server \
    openssl \
    ppp \
    psmisc \
    python3-yaml \
    rsync \
    strace \
    systemd \
    systemd-resolved \
    systemd-sysv \
    systemd-timesyncd \
    tmux \
    usbutils \
    vim

# Our builds of dhcpcd-base and wpasupplicant (build_dhcpcd.sh, build_wpasupplicant.sh), held so apt never swaps
# Ubuntu's back in. Installing wpasupplicant creates the netdev group, used below
apt-get install --no-install-recommends -yq /tmp/agnos/dhcpcd-base.deb /tmp/agnos/wpasupplicant.deb
apt-mark hold dhcpcd-base wpasupplicant
rm /tmp/agnos/dhcpcd-base.deb /tmp/agnos/wpasupplicant.deb

# Create the privileged user and hardware access groups.
useradd -G sudo -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWD" | chpasswd
groupadd gpio
groupadd gpu
# udev's group for /dev/input, which boot.sh and uevent_helper.sh hand out; there's no udev to create it
groupadd --system input
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

# Versioned LLVM packages don't provide the unversioned commands.
for tool in /usr/lib/llvm-20/bin/*; do
  ln -sf "$tool" "/usr/local/bin/$(basename "$tool")"
done

# Default C/C++ compilers.
update-alternatives --install /usr/bin/cc cc /usr/bin/clang-20 100
update-alternatives --install /usr/bin/c++ c++ /usr/bin/clang++-20 100

rm -rf /var/lib/apt/lists/*
