# mici USB-C

The mici board connects its external USB-C port to the primary DWC3/QMP
controller and the Quectel modem to the secondary controller. The primary
controller uses USB role switching; the secondary remains a fixed host.
The connector graph connects the PMI8998 Type-C controller to DWC3 for data
roles and to the QMP combo PHY for SuperSpeed orientation.

TCPM, the Qualcomm PMIC backend and the VBUS regulator are built in so the
port does not depend on loading modules before ADB/NCM becomes available.
Userspace reads the standard Type-C partner/orientation and UDC interfaces.
There is no fabricated connection state or orientation attribute.

## Provenance

Patch 0027 is an unmodified aggregate of patches 01, 03, 04, 05, 06, 08 from David
Heidelberg's September 26, 2026 RFC,
[Qualcomm Type-C support for 1st generation](https://lore.kernel.org/all/20260926-typec-v1-0-31adc19f32c6@ixit.cz/).
The [series archive](https://patchew.org/linux/20260926-typec-v1-0-31adc19f32c6@ixit.cz/)
records review discussion and the original mails. Its downloaded mbox SHA256
is `e35d6beaff5089f72ab7c1829a9d295af2f7e35b224120c1aeb46e3581b1969b`.
The selected changes add the shared TCPM backend, bindings and a disabled
PMI8998 node. Phone board changes are omitted. The original RFC supports
externally powered docks; it does not provide VBUS sourcing.

Patch 0028 adds mici's source and fault handling. Its register definitions
and source/input sequence follow the stock kernel at
`c368754c26c7b9659de187addc6cccedc6cfb0a0`:

- [SMB2 register definitions](https://github.com/commaai/agnos-kernel-sdm845/blob/c368754c26c7b9659de187addc6cccedc6cfb0a0/drivers/power/supply/qcom/smb-reg.h).
- [SMB2 source/input handling and protected writes](https://github.com/commaai/agnos-kernel-sdm845/blob/c368754c26c7b9659de187addc6cccedc6cfb0a0/drivers/power/supply/qcom/smb-lib.c).
- [PMI8998 current-limit encoding](https://github.com/commaai/agnos-kernel-sdm845/blob/c368754c26c7b9659de187addc6cccedc6cfb0a0/drivers/power/supply/qcom/qpnp-smb2.c).
- [Board PD/VBUS wiring](https://github.com/commaai/agnos-kernel-sdm845/blob/c368754c26c7b9659de187addc6cccedc6cfb0a0/arch/arm64/boot/dts/qcom/comma_common.dtsi).

PMI8998 uses 250 mA current-limit steps through 2 A, rather than PM8150B's
500 mA steps. The board advertises 5 V / 1.5 A source and 5 V / 3 A sink operation.
Its conservative 7.5 W sink operating-power policy permits a normal contract
with a 5 V / 1.5 A supply. TCPM can still request 3 A from a capable source.
Source enable suspends USBIN, exits the buck/boost 1-in-8 mode, enables OTG,
and waits up to 250 ms for actual boost softstart and enabled status. The
engineering register and PBS workaround use the required SEC_ACCESS unlock.

OTG failure/overcurrent IRQs emit standard regulator notifications. The
Type-C consumer and aggregate VBUS/VCONN fault IRQs request standard TCPM
error recovery. Source readiness uses actual regulator status/error flags.
Shutdown stops callbacks and TCPM before disabling VBUS/VCONN and selecting
the sink role.

The primary VBUS output is dedicated to the connector, with one intended
consumer. The charger remains disabled. Recovery uses regulator force-disable
for an unowned failed or inherited output, including when CMD_OTG is already
off but engineering state still needs cleanup. It never enables an output
to acquire a cleanup reference. USBIN restoration stays pending across failed
cleanup and retries. Adding another consumer or enabling the charger requires
coordinating ownership; independent debugfs/raw regulator control is unsuitable.

## Fault tests

After generating the patched source with `build_kernel.sh`, run:

```sh
python3 -m unittest discover -s kernel/tests -v
```

`AGNOS_USB_KERNEL_SOURCE` can select another prepared kernel source directory.
The tests compile the actual proposed C helpers with injected regmap,
regulator and TCPM interfaces. They use a host C compiler and Python's standard
library, without target hardware.

There are 42 scenarios across three test runners:

- 27 gen1 source/input, boot reconciliation, notifier lifetime and retry cases.
- 11 provider readiness, protected-register, rollback and fault-event cases.
- 4 shutdown ordering and error-continuation cases.

Coverage includes regulator enable failure followed by failed USBIN restore;
preserving the original input snapshot during retries; a provider clearing
CMD_OTG before HALT restoration fails; an on request after partial owned
disable; query-to-cleanup races without re-sourcing; pending teardown; startup
timeouts; VCONN-off with an unreadable orientation register; and callbacks
after the TCPM pointer has been cleared.

The complete stack has passed strict patch application, targeted ARM64
compilation with the built-in configuration, these fault tests and independent
static review. These checks do not establish physical USB acceptance.

## Physical acceptance

Validate source voltage/readiness, source-off discharge, current limiting,
overcurrent/VCONN recovery, bootloader handoff, cold/warm reboot, PD/data roles,
USB3 attach/replug and both cable orientations. Confirm modem independence
throughout. A powered UP gadget can exercise a host link once its temporary
gadget configuration and recovery path are explicitly prepared.

Actual chestnut enumeration, firmware activation/recovery, sustained GPU
inference, hotplug and 12 V loss/recovery still require a physical fixture.
Chestnut's external GPU power does not establish that its USB bridge remains
powered without VBUS. Firmware power cycling should use tested standard
Type-C control, with a measured VBUS drop; switching only the USB data role
does not guarantee that VBUS is off.
