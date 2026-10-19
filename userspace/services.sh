#!/bin/bash -e

# Enable DSP services
systemctl enable cdsp

# Enable our services
systemctl enable fs_setup.service
systemctl enable serial-hostname.service
systemctl enable comma.service
systemctl enable agnos-debug.service
systemctl enable gpio.service
systemctl enable lte.service
systemctl enable modem.service
systemctl enable sound.service
systemctl enable magic.service
systemctl enable init-qcom.service
systemctl enable wifi.service
systemctl enable varwatch.service
systemctl enable power_monitor.service
systemctl enable power_drop_monitor.service
systemctl enable brightnessd.service
systemctl enable ssh-param-watcher.path
systemctl enable ssh-param-watcher.service
systemctl enable adb-param-watcher.path
systemctl enable adb-param-watcher.service
systemctl enable avahi-daemon
systemctl enable avahi-ssh-publish.service
systemctl enable screen_calibration.service

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
ln -s /dev/null /etc/udev/rules.d/90-alsa-restore.rules
systemctl disable dpkg-db-backup.timer
