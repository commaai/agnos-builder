#!/bin/sh -e
# Alpine equivalent of base_setup.sh + openpilot_dependencies.sh +
# install_extras.sh + the apt installs in Dockerfile.agnos.
# Package mapping (Ubuntu -> Alpine) is annotated inline; "GAP" = no equivalent.
# busybox covers coreutils/findutils/grep/sed/tar/procps/ntpd/syslogd/logger.

USERNAME=comma
PASSWD=comma

touch /TICI /AGNOS

apk upgrade --no-cache

PKGS="
  bash
  alsa-utils
  bc
  build-base           # build-essential, libc6-dev
  dnsmasq              # dnsmasq-base
  gdb
  git
  iptables             # iptables-persistent: rules loaded by our iptables service
  iputils-ping
  jq
  kmod
  less
  llvm20-libs          # llvm-20: tinymesa only needs libLLVM.so.20.1, not the tools
  lsof
  networkmanager       # network-manager
  networkmanager-wifi
  networkmanager-cli
  openssh-server       # openssh-server
  openssh-client-default
  openssh-sftp-server
  openssl
  ppp
  psmisc
  rsync
  strace
  runit                # systemd
                       # GAP systemd-resolved: NetworkManager dns=default
                       # systemd-timesyncd: busybox ntpd
                       # GAP libnss-myhostname: musl has no NSS
  tmux
  eudev                # udev
  usbutils
  vim
  wpa_supplicant       # wpasupplicant
  ca-certificates curl sudo wget
  # --- openpilot_dependencies.sh ---
  clang20              # clang-20
  dbus-dev             # libdbus-1-dev
  libdrm-dev           # libdrm-dev
                       # libgbm-dev, libegl-dev, libgles-dev: headers only, see below
  glib                 # libglib2.0-0t64
  portaudio            # libportaudio2
  pkgconf              # pkg-config
  # --- Dockerfile.agnos final stage ---
  python3              # 3.12, same as Ubuntu
  python3-dev
  glib-dev             # libglib2.0-dev
  libgudev             # libgudev-1.0-0
  libmm-glib           # libmm-glib0
  polkit               # polkitd libpolkit-gobject-1-0
                       # GAP libsystemd0
  # --- install_extras.sh ---
  bash-completion btop hyperfine iperf iperf3 ripgrep ncdu socat stress-ng tree wavemon
  avahi avahi-tools
  android-tools        # adb
  # --- things Ubuntu pulled in implicitly, used by AGNOS scripts ---
  linux-headers        # linux-libc-dev (build-essential); replaced by our kernel headers
  dbus findmnt setpriv agetty e2fsprogs e2fsprogs-extra tzdata
  uv
"
apk add --no-cache $(echo "$PKGS" | sed 's/#.*//')

# EGL/GLES/GBM headers (libegl-dev, libgles-dev, libgbm-dev). mesa-dev would pull
# in X11 and rusticl; the libraries themselves are Adreno's.
cd /tmp
apk fetch --no-cache mesa-dev
tar -xzf mesa-dev-*.apk -C / usr/include/EGL usr/include/GLES2 usr/include/GLES3 usr/include/KHR usr/include/gbm.h \
  usr/lib/pkgconfig/egl.pc usr/lib/pkgconfig/glesv2.pc usr/lib/pkgconfig/gbm.pc 2>/dev/null || \
  tar -xzf mesa-dev-*.apk -C / --wildcards 'usr/include/EGL/*' 'usr/include/GLES2/*' 'usr/include/GLES3/*' 'usr/include/KHR/*' 'usr/include/gbm.h' 'usr/lib/pkgconfig/*'
rm mesa-dev-*.apk
cd /

# Create the privileged user and hardware access groups.
for g in sudo gpio gpu netdev systemd-journal plugdev; do
  getent group "$g" >/dev/null || addgroup -S "$g"
done
adduser -D -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWD" | chpasswd
for g in sudo wheel root video gpio adm gpu audio disk dialout systemd-journal netdev input plugdev; do
  addgroup "$USERNAME" "$g"
done
echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Kernel and scheduling settings. No PAM limits on Alpine: rtprio/nice are set
# with ulimit in the comma service instead of /etc/security/limits.conf.
echo "net.ipv4.conf.all.rp_filter = 2" >> /etc/sysctl.conf
echo "vm.dirty_expire_centisecs = 200" >> /etc/sysctl.conf

echo "LANG=C.UTF-8" > /etc/locale.conf

install -d -o "$USERNAME" -g "$USERNAME" /data /persist
install -d /config
ln -sf /bin/bash /bin/sh

# The Qualcomm blobs use /lib64/ld-linux-aarch64.so.1 (the glibc island, see Dockerfile.alpine)
mkdir -p /usr/lib64
ln -s usr/lib64 /lib64

# Versioned LLVM packages don't provide the unversioned commands (same as Ubuntu).
for tool in /usr/lib/llvm20/bin/*; do
  ln -sf "$tool" "/usr/local/bin/$(basename "$tool")"
done
