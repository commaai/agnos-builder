#!/bin/bash -e

# Ubuntu's wpasupplicant, with a config writer that only replaces the config with one it wrote completely and can
# read back: upstream's fixes from after 2.10, plus checking the final flush (on a full /data, SAVE_CONFIG replied
# OK and left an empty config) and writing a value with a # in hex. Built from the version apt would install now,
# and a patch that no longer applies fails it
profiles=pkg.wpa.nogui,nodoc,noudeb  # no GUI, docs or installer udeb
sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
apt-get update
mkdir -p /tmp/wpa-build
cd /tmp/wpa-build
apt-get source "wpa=$(apt-cache policy wpasupplicant | sed -n 's/ *Candidate: //p')"
cd wpa-*/
apt-get build-dep -yq --no-install-recommends -P "$profiles" ./
cat /tmp/agnos/wpa-config-write.patch /tmp/agnos/wpa-config-write-checks.patch | patch -p1 --fuzz=0
sed -i '1s/)/+agnos1)/' debian/changelog
# without docs there are no examples for debian/rules to edit
sed -i '/^execute_after_dh_installexamples:/,+1d' debian/rules
DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -b -uc -us -P"$profiles"
cp ../wpasupplicant_*+agnos1_*.deb /tmp/agnos/wpasupplicant.deb

