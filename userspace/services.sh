#!/bin/bash -e

# Enable DSP support services
systemctl enable adsp
systemctl enable cdsp
systemctl enable adsprpcd
systemctl enable cdsprpcd

# Enable our services
systemctl enable fs_setup.service
#systemctl enable serial-hostname.service
systemctl enable comma.service
systemctl enable gpio.service
systemctl enable lte.service
systemctl enable sound.service
systemctl enable pulse.service
systemctl enable weston.service
systemctl enable wifi.service
systemctl enable init-qcom.service
systemctl enable power_drop_monitor.service
systemctl enable brightnessd.service
systemctl enable ssh-param-watcher.path
systemctl enable ssh-param-watcher.service
systemctl enable home.mount
systemctl enable logrotate-hourly.timer

# Disable SSH by default
systemctl disable ssh

# Disable all useless systemctl services
systemctl disable hostapd.service
systemctl disable apt-daily-upgrade.service
systemctl disable apt-daily.service
systemctl disable apt-daily-upgrade.timer
systemctl disable apt-daily.timer
systemctl disable serial-getty@ttyS0.service
systemctl disable snapd.service
systemctl disable wlan_daemon.service
systemctl disable remote-fs.target
systemctl disable remote-fs-pre.target
systemctl disable e2scrub_all.timer
systemctl disable fstrim.timer
systemctl disable motd-news.service
systemctl disable motd-news.timer
systemctl disable multipathd.service
systemctl disable multipathd.socket
systemctl disable chgrp-diag.service
systemctl disable lvm2-monitor.service
systemctl mask systemd-backlight@.service
