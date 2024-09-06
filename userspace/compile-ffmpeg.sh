#!/bin/bash -e

# Install ffmpeg (the one from the ubuntu repos doesn't work with our libOpenCL)
cd /tmp
wget https://ffmpeg.org/releases/ffmpeg-4.2.2.tar.bz2
tar xvf ffmpeg-4.2.2.tar.bz2
cd ffmpeg-4.2.2

export DEBFULLNAME=comma
export LOGNAME=comma

dh_make --createorig -s -p ffmpeg_4.2.2 -y

# avoid makeinfo: error parsing ./doc/t2h.pm: Undefined subroutine &Texinfo::Config::set_from_init_file called at ./doc/t2h.pm line 24.
# with --disable-htmlpages
# --disable-doc works too, disables building documentation completely
# https://gist.github.com/omegdadi/6904512c0a948225c81114b1c5acb875
# https://github.com/7Ji/archrepo/issues/10
echo -e "override_dh_auto_configure:\n\t./configure --enable-shared --disable-static --disable-htmlpages" >> debian/rules
echo -e "override_dh_usrlocal:" >> debian/rules

DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -us -uc -nc

mv ../ffmpeg*.deb /tmp/ffmpeg.deb
