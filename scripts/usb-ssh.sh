#!/bin/bash
# USB SSH helper - loops forever, reconnects after reflash
set -e

DEVICE_IP="192.168.7.1"
HOST_IP="192.168.7.2"
NETMASK="24"

find_usb_iface() {
    # Look for USB CDC NCM/ECM interfaces from Qualcomm (vendor 05c6)
    for iface in /sys/class/net/enx* /sys/class/net/enp* /sys/class/net/usb* /sys/class/net/eth*; do
        [ -e "$iface" ] || continue
        name=$(basename "$iface")
        [[ "$name" == "lo" ]] && continue
        [[ "$name" == "eth0" ]] && continue

        # Get the USB device path
        dev_path=$(readlink -f "$iface/device" 2>/dev/null) || continue
        [[ "$dev_path" == *usb* ]] || continue

        # Extract the USB device directory (e.g., /sys/devices/.../usb4/4-4)
        usb_dev_path=$(echo "$dev_path" | sed 's|\(.*usb[0-9]*/[0-9]*-[0-9.]*\).*|\1|')
        if [ -f "$usb_dev_path/idVendor" ]; then
            vendor=$(cat "$usb_dev_path/idVendor" 2>/dev/null)
            if [ "$vendor" = "05c6" ]; then
                echo "$name"
                return 0
            fi
        fi
    done
    return 1
}

remove_conflicting_ips() {
    local correct_iface="$1"
    # Remove 192.168.7.x from ALL other interfaces to prevent routing conflicts
    for iface in $(ip -o addr show | grep "192\.168\.7\." | awk '{print $2}'); do
        if [ "$iface" != "$correct_iface" ]; then
            echo "Removing conflicting IP from $iface..."
            sudo ip addr del "$HOST_IP/$NETMASK" dev "$iface" 2>/dev/null || true
        fi
    done
}

configure_iface() {
    local iface="$1"
    # First remove conflicting IPs from other interfaces
    #remove_conflicting_ips "$iface"
    # Add IP if not already present
    if ! ip addr show dev "$iface" 2>/dev/null | grep -q "$HOST_IP"; then
        sudo ip addr add "$HOST_IP/$NETMASK" dev "$iface" 2>/dev/null || true
    fi
    sudo ip link set "$iface" up 2>/dev/null || true
}

while true; do
    echo "Waiting for USB network interface..."

    IFACE=""
    while [ -z "$IFACE" ]; do
        IFACE=$(find_usb_iface) || true
        [ -z "$IFACE" ] && sleep 0.5
    done

    echo "Found USB interface: $IFACE"

    # Configure the interface
    echo "Configuring $IFACE with $HOST_IP/$NETMASK..."
    configure_iface "$IFACE"

    # Wait for device to be reachable
    echo "Waiting for device at $DEVICE_IP..."
    while ! ping -c 1 -W 1 "$DEVICE_IP" &>/dev/null; do
        # Check if interface still exists
        if [ ! -e "/sys/class/net/$IFACE" ]; then
            echo "Interface disappeared, device probably rebooting..."
            break
        fi
        # Re-apply IP config in case NetworkManager stripped it
        configure_iface "$IFACE"
        sleep 0.5
    done

    # Only SSH if we got a ping response
    if ping -c 1 -W 1 "$DEVICE_IP" &>/dev/null; then
        echo "Connecting to comma@$DEVICE_IP..."
        ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 comma@"$DEVICE_IP" || true
        echo "SSH session ended."
    fi

    echo "---"
    sleep 1
done
