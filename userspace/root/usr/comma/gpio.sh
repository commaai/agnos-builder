#!/bin/bash -e
# The board's DT names its GPIO lines (gpio-line-names), gpiofind looks them up

# openpilot's common/gpio.py still drives these through the legacy sysfs ABI.
# The per-chip export (/sys/class/gpio/chipN/export, v6.17+) takes the line
# offset, and GPIO_SYSFS_LEGACY also creates the global gpioNNN that openpilot
# opens. Lines that are already exported are skipped, so this can run again.
for name in SOM_ST_IO STM_BOOT0 STM_PWR_EN_N STM_RST_N GNSS_PWR_EN UBLOX_SAFEBOOT_N UBLOX_RST_N; do
  line=$(gpiofind $name)  # "gpiochipN offset"
  chip=${line% *}
  offset=${line#* }
  export_dir=/sys/class/gpio/${chip#gpio}
  [ -e $export_dir/gpio$offset ] || echo $offset > $export_dir/export
done

gpioset $(gpiofind HUB_RST_N)=1
