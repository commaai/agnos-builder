#!/usr/bin/bash

# silences a ruby warning
# https://bugs.launchpad.net/ubuntu/+source/iptables-netflow/+bug/1907932
export RUBYOPT="-W0"

irqtop
