#!/usr/bin/env python3
# Void Linux version - uses sv instead of systemctl
# Monitor for power drops and kill services if needed

import subprocess
import time
import os

VOLTAGE_FILE = "/sys/class/power_supply/bms/voltage_now"
CURRENT_FILE = "/sys/class/power_supply/bms/current_now"
VOLTAGE_THRESHOLD = 3400000  # 3.4V in microvolts
DEBOUNCE_TIME = 0.5


def read_value(path):
    try:
        with open(path, "r") as f:
            return int(f.read().strip())
    except:
        return None


def kill_services():
    """Kill comma service on power drop - Void version using sv"""
    # Use sv force-stop to immediately terminate services
    # Note: weston is not used in Void, only comma
    subprocess.call(["sv", "force-stop", "comma"])


def main():
    last_drop = 0

    while True:
        voltage = read_value(VOLTAGE_FILE)

        if voltage is not None and voltage < VOLTAGE_THRESHOLD:
            now = time.monotonic()
            if now - last_drop > DEBOUNCE_TIME:
                print(f"Power drop detected: {voltage / 1000000:.2f}V")
                kill_services()
                last_drop = now

        time.sleep(0.1)


if __name__ == "__main__":
    main()
