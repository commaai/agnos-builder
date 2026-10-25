#!/bin/bash -e

# for all the non-essential nice to haves

apt-fast update && apt-fast install -y --no-install-recommends \
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
# ncurses uses unprefixed names for these terminals; accept their default TERM too.
cat >> /tmp/terminfo.src <<'EOF'
xterm-ghostty|Ghostty terminal emulator alias,
    use=ghostty,
xterm-kitty|Kitty terminal emulator alias,
    use=kitty,
EOF
tic -x -o /usr/share/terminfo /tmp/terminfo.src
rm /tmp/terminfo.src

# color prompt
sed -i 's/#force_color_prompt=yes/force_color_prompt=yes/g' /home/comma/.bashrc
