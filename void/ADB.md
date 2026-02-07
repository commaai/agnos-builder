# ADB + USB Networking Findings

## Architecture

The USB gadget is configured via configfs at `/sys/kernel/config/usb_gadget/g1`.
The Qualcomm 9024 composition script (`/usr/bin/usb/compositions/9024`) runs at boot
via the `init-qcom` runit service and sets up the initial gadget configuration.

`set_adb.sh` is called by openpilot when the AdbEnabled param is toggled. It creates
a fresh USB gadget with ADB (and optionally NCM for USB networking).

## Key Findings

### Qualcomm's libOpenCL-style ICD problem, but for USB
The 9024 script's `run_configfs()` function links `ffs.adb` into the gadget config,
but this **breaks UDC binding** if adbd hasn't started yet and opened
`/dev/usb-ffs/adb/ep0`. The solution is to only add ffs.adb AFTER adbd is running.

### NCM + ADB composite gadget works
Both USB NCM networking and ADB can coexist in the same USB gadget as composite
functions. Tested and confirmed working with:
- f1 = ncm.0 (USB networking at 192.168.7.1)
- f2 = ffs.adb (Android Debug Bridge)

### Timing requirements
1. Mount functionfs: `mount -t functionfs adb /dev/usb-ffs/adb`
2. Start adbd: it opens `/dev/usb-ffs/adb/ep0` (creates ep1, ep2)
3. Wait ~1 second for adbd to initialize
4. Link ffs.adb into gadget config
5. Bind UDC: `echo a600000.dwc3 > UDC`
6. Wait ~2 seconds for USB interface to appear
7. Configure IP on usb0 (if NCM is enabled)

### configfs symlink requirements
Symlinks in configfs must be **relative** (e.g., `ln -s functions/ffs.adb configs/c.1/f2`
from inside the gadget directory). Absolute paths create incorrect links.

### UDC rebinding tears down usb0
When adding/removing USB functions, UDC must be unbound and rebound. This destroys
the NCM network interface (usb0). After rebinding, usb0 must be reconfigured:
```bash
sleep 2  # wait for usb0 to appear
ip addr add 192.168.7.1/24 dev usb0
ip link set usb0 up
```

## Files

- `void/files/set_adb.sh` — ADB-only gadget setup (production)
- `void/files/set_adb_ncm.sh` — NCM+ADB gadget setup (for development/debugging)
- `void/blobs/base/usr/bin/usb/compositions/9024` — Qualcomm boot-time USB composition

## USB Networking Status

Disabled in production. WiFi (192.168.1.x) is the primary connectivity method.
USB networking can be re-enabled using `set_adb_ncm.sh` for development.
