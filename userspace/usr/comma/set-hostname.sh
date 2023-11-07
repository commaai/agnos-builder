#!/bin/bash
set -e

SERIAL="$(cat /proc/cmdline | sed -e 's/^.*androidboot.serialno=//' -e 's/ .*$//')"
echo "serial: '$SERIAL'"
sysctl kernel.hostname="tici-$SERIAL"
