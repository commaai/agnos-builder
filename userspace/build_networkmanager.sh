#!/bin/bash -e
# Use Ubuntu's maintained source, without its netplan/systemd integration.
sed -i 's/Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
apt-get update
apt-get install -yq --no-install-recommends dpkg-dev meson ninja-build pkg-config \
  libglib2.0-dev libudev-dev libgnutls28-dev libcurl4-gnutls-dev libpsl-dev \
  libdbus-1-dev libreadline-dev libndp-dev libjansson-dev xsltproc
cd /tmp
apt-get source network-manager
cd network-manager-*/
meson setup build --prefix=/usr --libdir=lib/aarch64-linux-gnu --sysconfdir=/etc --localstatedir=/var \
  -Dnetplan=false -Dsession_tracking=no -Dsession_tracking_consolekit=false \
  -Dsuspend_resume=consolekit -Dsystemd_journal=false -Dsystemdsystemunitdir=no \
  -Dpolkit=false -Dselinux=false -Dlibaudit=no -Dcrypto=gnutls \
  -Dmodem_manager=false -Dppp=false -Dovs=false -Dteamdctl=false \
  -Dintrospection=false -Dvapi=false -Ddocs=false -Dtests=no -Dqt=false \
  -Dnmtui=false -Dnm_cloud_setup=false -Dfirewalld_zone=false \
  -Dresolvconf=/usr/local/bin/resolvconf -Dconfig_dns_rc_manager_default=resolvconf \
  -Dconfig_logging_backend_default=syslog
ninja -C build
DESTDIR=/tmp/agnos/networkmanager ninja -C build install
install -Dm644 debian/copyright /tmp/agnos/networkmanager/usr/share/doc/network-manager/copyright
