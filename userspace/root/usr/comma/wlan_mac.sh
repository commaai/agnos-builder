#!/bin/bash -e
# The WCN3990 firmware reports 0e:00:00:00:00:00. Give the interface the address
# the downstream driver did: the 00:0a:f5 OUI and the low 3 bytes of the SoC serial number.
serial=$(cat /sys/devices/soc0/serial_number)
[ "$serial" -gt 0 ]
ip link set dev "$1" address $(printf 00:0a:f5:%02x:%02x:%02x $((serial >> 16 & 255)) $((serial >> 8 & 255)) $((serial & 255)))
