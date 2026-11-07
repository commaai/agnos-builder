#!/bin/bash
# each init starts immediately in the background and waits for whatever it needs itself

INIT_TIMEOUT=10

PIDS=()

# run_init <name> <command> [args]
# runs the command in the background, reporting how it went. a stuck open can't be killed
# and timeout would wait on it, so this races it against a timer
function run_init {
  local name=$1
  shift
  (
    "$@" & pid=$!
    sleep "$INIT_TIMEOUT" & timer=$!
    wait -n -p first "$pid" "$timer"
    ret=$?
    if [ "$first" = "$timer" ]; then
      echo "timed out starting $name"
      exit 1
    fi
    kill "$timer"
    if [ "$ret" != 0 ]; then
      echo "failed to start $name"
      exit 1
    fi
    echo "started $name"
  ) & PIDS+=($!)
}

# the video core boots on first open, openpilot's booted check waits for it
function start_video {
  until [ -e /dev/video33 ]; do
    sleep 0.01
  done
  : < /dev/video33
}

# don't restart whole SoC on subsystem crash. this has to happen before anything below boots
for i in {0..7}; do
  echo "related" > /sys/bus/msm_subsys/devices/subsys${i}/restart_level
done

# the services ordered after this only need the restart levels, they don't wait for what's below
systemd-notify --ready

run_init video start_video

RET=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || RET=1
done
exit $RET
