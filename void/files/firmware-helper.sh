#!/bin/sh
# Firmware loading helper for eudev
# Responds to kernel firmware requests immediately (load or fail)

FIRMWARE_DIRS="/lib/firmware/updates /lib/firmware /firmware/image"

for dir in $FIRMWARE_DIRS; do
    if [ -f "$dir/$FIRMWARE" ]; then
        echo 1 > "/sys/$DEVPATH/loading"
        cat "$dir/$FIRMWARE" > "/sys/$DEVPATH/data"
        echo 0 > "/sys/$DEVPATH/loading"
        exit 0
    fi
done

# Not found - fail immediately instead of waiting for timeout
echo -1 > "/sys/$DEVPATH/loading"
