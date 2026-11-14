#!/bin/bash -e

# Enable our services
systemctl enable boot.service
systemctl enable uevent-helper.service
systemctl enable comma.service
systemctl enable agnos-debug.service
systemctl enable ultimate_provisioning.service
systemctl enable lte.service
systemctl enable modem.service
systemctl enable magic.service
systemctl enable rmtfs.service
systemctl enable power_monitor.service
systemctl enable power_drop_monitor.service
systemctl enable brightnessd.service
systemctl enable ssh-param-watcher.path
systemctl enable ssh-param-watcher.service
systemctl enable adb-param-watcher.path
systemctl enable adb-param-watcher.service
systemctl enable avahi-daemon
systemctl enable avahi-ssh-publish.service

# Disable SSH by default, ssh-param-watcher starts it
systemctl disable ssh ssh.socket

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

# boot.sh mounts a fresh /tmp, and this would delete what's already using it
ln -s /dev/null /etc/tmpfiles.d/tmp.conf
systemctl disable dpkg-db-backup.timer

# unused, and mounting them all at once can trip systemd's mount rate limit, holding up everything else for up to 1s
systemctl mask sys-fs-fuse-connections.mount sys-kernel-tracing.mount sys-kernel-config.mount
# NetworkManager waits on this at startup and nothing uses it
systemctl mask systemd-hostnamed.service

# Promote SSH sessions, leaving the listening daemon in the background.
echo "session optional pam_exec.so /usr/comma/run_in_app_group.sh" >> /etc/pam.d/sshd
