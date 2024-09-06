#!/bin/bash -e

# Install capnproto
cd /tmp
VERSION=1.0.2
wget https://capnproto.org/capnproto-c++-${VERSION}.tar.gz
tar xvf capnproto-c++-${VERSION}.tar.gz
cd capnproto-c++-${VERSION}

export DEBFULLNAME=comma
export LOGNAME=comma

dh_make --createorig -s -p capnproto_${VERSION} -y

echo -e "override_dh_auto_configure:\n\tCXX_FLAGS=\"-fPIC -O2\" ./configure" >> debian/rules
echo -e "override_dh_usrlocal:" >> debian/rules

DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -us -uc -nc

mv ../capnproto*.deb /tmp/capnproto.deb
