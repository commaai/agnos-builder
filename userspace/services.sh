#!/bin/bash -e

# Enable our services
systemctl enable comma-init.service
systemctl enable modem-ports.service
systemctl enable serial-getty@ttyMSM0.service
systemctl enable comma.service
systemctl enable lte.service
systemctl enable modem.service
systemctl enable magic.service
systemctl enable wifi.service
systemctl enable varwatch.service
systemctl enable power_monitor.service
systemctl enable power_drop_monitor.service
systemctl enable brightnessd.service
systemctl enable ssh-param-watcher.path
systemctl enable ssh-param-watcher.service
systemctl enable adb-param-watcher.path
systemctl enable adb-param-watcher.service
systemctl enable logrotate-hourly.timer
systemctl enable avahi-daemon
systemctl enable avahi-ssh-publish.service

# Disable SSH by default
systemctl disable ssh

# Disable all useless systemctl services
systemctl disable apt-daily-upgrade.service
systemctl disable apt-daily.service
systemctl disable apt-daily-upgrade.timer
systemctl disable apt-daily.timer
systemctl disable serial-getty@ttyS0.service
systemctl disable remote-fs.target
systemctl disable remote-fs-pre.target
systemctl disable e2scrub_all.timer
systemctl disable fstrim.timer
systemctl disable motd-news.service
systemctl disable motd-news.timer
systemctl disable systemd-pstore.service
systemctl mask systemd-backlight@.service
systemctl mask alsa-restore.service
systemctl disable dpkg-db-backup.timer

# Hardware setup is handled directly by comma-init instead of udev.
systemctl mask systemd-udevd.service
systemctl mask systemd-udevd-control.socket
systemctl mask systemd-udevd-kernel.socket
systemctl mask systemd-udev-trigger.service
systemctl mask systemd-udev-settle.service
