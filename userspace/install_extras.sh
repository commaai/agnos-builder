# Sourced by the final stage of Dockerfile.agnos — declares the non-essential
# nice-to-have packages so they're installed in the same apt-fast invocation
# as the runtime libraries. Plain string (not bash array) so it sources
# cleanly under /bin/sh during docker build.
#
# Diagnostic-only conveniences (btop, hyperfine, ncdu, tree, wavemon,
# speedtest-cli, irqtop, iperf) were removed to keep the build under the
# 5-minute mark; install on demand if needed.

EXTRAS_PACKAGES="\
    adb \
    avahi-daemon \
    avahi-utils \
    bash-completion \
    dnsmasq \
    iperf3 \
    nfs-common \
    ripgrep \
    socat \
    stress-ng \
    traceroute"
