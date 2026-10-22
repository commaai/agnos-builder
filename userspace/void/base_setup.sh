#!/bin/bash -e
# Void Linux equivalent of base_setup.sh + openpilot_dependencies.sh +
# install_extras.sh + the apt installs in Dockerfile.agnos.
# Package mapping (Ubuntu -> Void) is annotated inline; "GAP" = no equivalent.

USERNAME=comma
PASSWD=comma

touch /TICI /AGNOS

xbps-install -Syu xbps
xbps-install -yu

PKGS=(
  # --- base_setup.sh ---
  shadow             # adduser
  alsa-utils
                     # GAP apport-retrace: no apport on Void
  bc
  base-devel         # build-essential
  dnsmasq            # dnsmasq-base
  gdb
  git
  iptables           # iptables-persistent: GAP, Void's iptables ships a runit service (/etc/sv/iptables) that loads /etc/iptables/iptables.rules
  iputils
  jq
  kmod
  less
  glibc-devel        # libc6-dev
  libglvnd-devel     # libegl-dev libgles-dev
  libglvnd           # libegl1 libgles1 libgles2
                     # GAP libnss-myhostname: no nss-myhostname on Void (needs systemd)
  llvm21             # llvm-20: GAP, Void has 18/19/21; tinymesa wants LLVM 20
  glibc-locales      # locales
  logrotate
  lsof
  NetworkManager     # network-manager
  openssh            # openssh-client openssh-server
  openssl
  ppp
  psmisc
  rsync
  rsyslog
  strace
  runit-void         # systemd
                     # GAP systemd-resolved: NetworkManager dns=default + openresolv
  chrony             # systemd-timesyncd
  tmux
  eudev              # udev
  usbutils
  vim
  wpa_supplicant     # wpasupplicant
  ca-certificates curl sudo wget
  # --- openpilot_dependencies.sh ---
  clang21            # clang-20 (see llvm21)
  dbus-devel         # libdbus-1-dev
  libdrm-devel       # libdrm-dev
  libgbm-devel       # libgbm-dev
  glib               # libglib2.0-0t64
  portaudio          # libportaudio2
  pkg-config
  # --- Dockerfile.agnos final stage ---
  python3            # python3 (3.14 on Void; 3.12 comes from uv, see python_setup.sh)
  python3-devel      # python3-dev
  glib-devel         # libglib2.0-dev
  libgudev           # libgudev-1.0-0
  libmm-glib         # libmm-glib0
  polkit             # polkitd libpolkit-gobject-1-0
                     # GAP libsystemd0: adbd gets a bundled Ubuntu copy
  # --- install_extras.sh ---
  bash-completion btop hyperfine iperf iperf3 ripgrep ncdu socat stress-ng tree wavemon
  avahi avahi-utils
  android-tools      # adb
  # --- Void-only: things Ubuntu pulled in implicitly ---
  bash dbus util-linux iproute2 procps-ng tzdata e2fsprogs xz file
  uv                 # Ubuntu used astral's installer; Void packages uv
  patchelf           # adbd RPATH fixup
  libcap-progs       # setcap for ping
)
xbps-install -y "${PKGS[@]}"

# Create the privileged user and hardware access groups.
# Void has no "sudo" group (it uses wheel); create it so comma-polkit.rules keeps working.
for g in sudo gpio gpu netdev systemd-journal syslog; do
  getent group "$g" >/dev/null || groupadd -r "$g"
done
useradd -G sudo,wheel -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWD" | chpasswd
usermod -aG root,video,gpio,adm,gpu,audio,disk,dialout,systemd-journal,netdev,input,plugdev "$USERNAME"
echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Kernel and scheduling settings.
echo "net.ipv4.conf.all.rp_filter = 2" >> /etc/sysctl.conf
echo "vm.dirty_expire_centisecs = 200" >> /etc/sysctl.conf
echo "$USERNAME - rtprio 100" >> /etc/security/limits.conf
echo "$USERNAME - nice -10" >> /etc/security/limits.conf

# locales: Void uses /etc/default/libc-locales + xbps-reconfigure
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/default/libc-locales
xbps-reconfigure -f glibc-locales
echo "LANG=en_US.UTF-8" > /etc/locale.conf

install -d -o "$USERNAME" -g "$USERNAME" /data /persist
install -d /config
ln -sf /bin/bash /bin/sh

# Versioned LLVM packages don't provide the unversioned commands (same as Ubuntu).
for tool in /usr/lib/llvm/21/bin/*; do
  ln -sf "$tool" "/usr/local/bin/$(basename "$tool")"
done

# The Qualcomm blobs live in the Debian multiarch dir.
echo /usr/lib/aarch64-linux-gnu > /etc/ld.so.conf.d/00-aarch64-linux-gnu.conf

xbps-remove -Oy || true
rm -rf /var/cache/xbps/*
