#!/bin/bash -e

# Ubuntu's dhcpcd-base, roaming between access points like NetworkManager: upstream's "allow roaming without
# IFF_DORMANT" from dhcpcd 10.0.9 keeps the lease. Built from the version apt would install now (base_setup.sh fails
# if a cached build of this stage falls behind it), and a patch that no longer applies fails it
sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
apt-get update
mkdir -p /tmp/dhcpcd-build
cd /tmp/dhcpcd-build
apt-get source "dhcpcd=$(apt-cache policy dhcpcd-base | sed -n 's/ *Candidate: //p')"
cd dhcpcd-*/
apt-get build-dep -yq --no-install-recommends ./
patch -p1 --fuzz=0 < /tmp/agnos/dhcpcd-roaming.patch
sed -i '1s/)/+agnos1)/' debian/changelog
DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -b -uc -us
cp ../dhcpcd-base_*+agnos1_*.deb /tmp/agnos/dhcpcd-base.deb
