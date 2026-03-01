#!/bin/sh
# Generate /run/motd from update-motd.d scripts
run-parts /etc/update-motd.d >/run/motd 2>/dev/null
