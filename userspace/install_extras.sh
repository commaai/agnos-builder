#!/bin/bash -e

# for all the non-essential nice to haves

apt-get update && apt-get install -y --no-install-recommends \
  bash-completion \
  btop \
  hyperfine \
  iperf \
  iperf3 \
  ripgrep \
  ncdu \
  ncurses-bin \
  socat \
  stress-ng \
  tree \
  wavemon \
  avahi-daemon \
  adb \
  avahi-utils

# Install the full upstream terminfo database, including modern terminals.
# Pin the snapshot so image builds remain reproducible.
terminfo_revision=dc909d77781ef5c2a0684e9ad9eb9f0c0baf5ecc
curl -fsSL "https://raw.githubusercontent.com/ThomasDickey/ncurses-snapshots/$terminfo_revision/misc/terminfo.src" -o /tmp/terminfo.src
tic -x -o /usr/share/terminfo /tmp/terminfo.src
rm /tmp/terminfo.src

# Use the vendor definitions for their full advertised capabilities.
kitty_revision=debcde56c0e0f59aab25f6c3887aa655282a876a
curl -fsSL "https://raw.githubusercontent.com/kovidgoyal/kitty/$kitty_revision/terminfo/kitty.terminfo" -o /tmp/kitty.terminfo
tic -x -o /usr/share/terminfo /tmp/kitty.terminfo
rm /tmp/kitty.terminfo

# color prompt
sed -i 's/#force_color_prompt=yes/force_color_prompt=yes/g' /home/comma/.bashrc
