#!/bin/bash -e

# Enable DSP support services
systemctl enable adsp
systemctl enable cdsp
systemctl enable adsprpcd
systemctl enable cdsprpcd

# Enable our services
systemctl enable fs_setup.service
systemctl enable serial-hostname.service
systemctl enable comma.service
systemctl enable gpio.service
systemctl enable lte.service
systemctl enable sound.service
systemctl enable weston.service
systemctl enable weston-ready.service
systemctl enable init-qcom.service
systemctl enable varwatch.service
systemctl enable power_drop_monitor.service
systemctl enable brightnessd.service
systemctl enable ssh-param-watcher.path
systemctl enable ssh-param-watcher.service
systemctl enable adb-param-watcher.path
systemctl enable adb-param-watcher.service
systemctl enable logrotate-hourly.timer
systemctl enable avahi-daemon

# Disable some of our services
systemctl disable agnos-tests.service

# Disable third party services
systemctl disable darkstat.service
systemctl disable vnstat.service

# Disable SSH by default
systemctl disable ssh

# Disable all useless systemctl services
systemctl disable hostapd.service
systemctl disable apt-daily-upgrade.service
systemctl disable apt-daily.service
systemctl disable apt-daily-upgrade.timer
systemctl disable apt-daily.timer
systemctl disable serial-getty@ttyS0.service
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
systemctl disable dpkg-db-backup.timer
systemctl disable nvmefc-boot-connections.service
systemctl disable ua-reboot-cmds.service
systemctl disable ubuntu-advantage.service
systemctl disable update-notifier-download.timer
systemctl disable update-notifier-download.service
systemctl disable update-notifier-motd.timer
systemctl disable update-notifier-motd.service
systemctl disable man-db.timer

# Disable NFS stuff by default
systemctl disable rpcbind
systemctl disable dnsmasq.service
systemctl disable nfs-client.target
systemctl disable remote-fs-pre.target

# Disable nvmf service since no NVMe-oF in the old kernel
# this service fails in 24.04, while failing silently on 20.04
# no influence on C3 NVMe nor nvme smart-log, which work fine
systemctl disable nvmf-autoconnect.service

# Service is from ifupdown but ifupdown is managed by NetworkManager
# networking service fails with "ifup: failed to bring up lo"
# no influence on any interface, all interfaces work fine
systemctl disable networking.service

# TODO: this doesn't actually disable unless run twice...
# Service fails with Status: "No devices to monitor"
systemctl disable smartd.service
systemctl disable smartd.service

systemctl disable console-setup.service
systemctl disable sfsconfig.service
