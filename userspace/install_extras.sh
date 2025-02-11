#!/bin/bash -e

# for all the non-essential nice to haves

apt-fast update && apt-fast install -y --no-install-recommends \
  bash-completion \
  iperf \
  dnsmasq \
  irqtop \
  ripgrep \
  ncdu \
  nfs-common \
  socat \
  avahi-daemon

# color prompt
sed -i 's/#force_color_prompt=yes/force_color_prompt=yes/g' /home/comma/.bashrc
