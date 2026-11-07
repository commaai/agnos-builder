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

function start_venus {
  until [ -e /dev/video33 ]; do
    sleep 0.01
  done
  # just opening the node boots venus, openpilot's booted check waits for that
  : < /dev/video33
}

# don't restart whole SoC on subsystem crash. this has to happen before anything below boots
for i in {0..7}; do
  echo "related" > /sys/bus/msm_subsys/devices/subsys${i}/restart_level
done

run_init venus start_venus

RET=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || RET=1
done
exit $RET
