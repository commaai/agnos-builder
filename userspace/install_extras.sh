#!/bin/bash -e

# for all the non-essential nice to haves
# Apt cache was refreshed earlier in the final stage; no update needed.

apt-fast install -y --no-install-recommends \
  bash-completion \
  btop \
  hyperfine \
  iperf \
  iperf3 \
  dnsmasq \
  irqtop \
  ripgrep \
  ncdu \
  nfs-common \
  socat \
  stress-ng \
  tree \
  wavemon \
  avahi-daemon \
  adb \
  avahi-utils \
  traceroute \
  speedtest-cli

# color prompt
sed -i 's/#force_color_prompt=yes/force_color_prompt=yes/g' /home/comma/.bashrc
