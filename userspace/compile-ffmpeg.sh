#!/bin/bash -e

# Install ffmpeg (the one from the ubuntu repos doesn't work with our libOpenCL)
cd /tmp
wget https://ffmpeg.org/releases/ffmpeg-4.2.2.tar.bz2
tar xvf ffmpeg-4.2.2.tar.bz2
cd ffmpeg-4.2.2

# avoid makeinfo: error parsing ./doc/t2h.pm: Undefined subroutine &Texinfo::Config::set_from_init_file called at ./doc/t2h.pm line 24.
# with --disable-htmlpages
# --disable-doc works too, disables building documentation completely
# https://gist.github.com/omegdadi/6904512c0a948225c81114b1c5acb875
# https://github.com/7Ji/archrepo/issues/10
./configure --enable-shared --disable-static --disable-htmlpages
make -j$(nproc)

# remove "--fstrans=no" when checkinstall is fixed (still not fixed in 24.04)
checkinstall -yD --install=no --fstrans=no --pkgname=ffmpeg
mv ffmpeg*.deb /tmp/ffmpeg.deb
