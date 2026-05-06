#!/bin/bash -e

# Enable our services
systemctl enable comma-init.service
systemctl enable comma.service
systemctl enable lte.service
systemctl enable magic.service
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
systemctl enable tftp_server.service

# Disable SSH by default
systemctl disable ssh

# disable_q / mask_q: tolerate missing units. Some of the units we want to
# keep dormant are shipped by packages we don't always install (e.g.
# multipath-tools, ubuntu-advantage-tools, update-notifier). The intent is
# "make sure this isn't enabled" — if the unit isn't installed, that's
# already true.
disable_q() { systemctl disable "$@" 2>/dev/null || true; }
mask_q()    { systemctl mask    "$@" 2>/dev/null || true; }

# Disable all useless systemctl services
disable_q hostapd.service
disable_q apt-daily-upgrade.service
disable_q apt-daily.service
disable_q apt-daily-upgrade.timer
disable_q apt-daily.timer
disable_q serial-getty@ttyS0.service
disable_q remote-fs.target
disable_q remote-fs-pre.target
disable_q e2scrub_all.timer
disable_q fstrim.timer
disable_q motd-news.service
disable_q motd-news.timer
disable_q multipathd.service
disable_q multipathd.socket
disable_q lvm2-monitor.service
mask_q    systemd-backlight@.service
mask_q    systemd-udevd.service
mask_q    systemd-udevd-control.socket
mask_q    systemd-udevd-kernel.socket
mask_q    systemd-udev-trigger.service
mask_q    systemd-udev-settle.service
disable_q dpkg-db-backup.timer
disable_q ua-reboot-cmds.service
disable_q ubuntu-advantage.service
disable_q update-notifier-download.timer
disable_q update-notifier-download.service
disable_q update-notifier-motd.timer
disable_q update-notifier-motd.service
disable_q man-db.timer

# Disable NFS stuff by default
disable_q rpcbind
disable_q dnsmasq.service
disable_q nfs-client.target
disable_q remote-fs-pre.target

# Service is from ifupdown but ifupdown is managed by NetworkManager
# networking service fails with "ifup: failed to bring up lo"
# no influence on any interface, all interfaces work fine
disable_q networking.service

disable_q console-setup.service
