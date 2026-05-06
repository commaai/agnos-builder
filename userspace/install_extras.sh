# Sourced by the final stage of Dockerfile.agnos — declares the non-essential
# nice-to-have packages so they're installed in the same apt-fast invocation
# as the runtime libraries. Plain string (not bash array) so it sources
# cleanly under /bin/sh during docker build.

EXTRAS_PACKAGES="\
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
    speedtest-cli"
