#!/bin/bash
# Moves out of the background (see /usr/comma/init) into the app's group, which has every core.
# The app's units start through this: systemd forks them in the background, and an ExecStartPre is
# a different process, so the unit's own process has to move before it starts anything.
case "$PAM_TYPE" in
  "") pid=$$ ;;
  # pam_exec in sshd: the daemon stays in the background, the session it forks is the app
  open_session) pid=$PPID ;;
  *) exit 0 ;;
esac

echo $pid > /dev/cpusets/cgroup.procs
ionice -c best-effort -n 4 -p $pid

# the command runs even if that failed
[ -n "$PAM_TYPE" ] || exec "$@"
