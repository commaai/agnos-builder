#!/bin/bash
# each init starts immediately in the background and waits for whatever it needs itself

# init-qcom.service's timeout has to stay above this
INIT_TIMEOUT=120

PIDS=()

# run_init <function>
# runs the function in the background, reporting how it went. a stuck open can't be killed
# and timeout would wait on it, so this races it against a timer
function run_init {
  local name=$1
  (
    "$name" & pid=$!
    sleep "$INIT_TIMEOUT" & timer=$!
    wait -n -p first "$pid" "$timer"
    ret=$?
    if [ "$first" = "$timer" ]; then
      echo "$name timed out"
      exit 1
    fi
    kill "$timer"
    if [ "$ret" != 0 ]; then
      echo "$name failed"
      exit 1
    fi
    echo "$name done"
  ) & PIDS+=($!)
}

function set_restart_levels {
  # don't restart whole SoC on subsystem crash
  echo related | tee /sys/bus/msm_subsys/devices/subsys*/restart_level > /dev/null
}

function start_venus {
  until [ -e /dev/video33 ]; do
    sleep 0.01
  done
  # opening the node boots the venus encoder
  : < /dev/video33
}

run_init set_restart_levels
run_init start_venus

RET=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || RET=1
done
exit $RET
