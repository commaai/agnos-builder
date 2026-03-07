#! /bin/sh

destdir=/mnt/sdcard/

umount_partition()
{
        if grep -qs "^/dev/$1 " /proc/mounts ; then
                umount -lf "${destdir}";
        fi
}

mount_partition()
{
        if [ ! -d "${destdir}" ]; then
            mkdir "${destdir}"
        fi
        if ! mount -t auto "/dev/$1" "${destdir}" -o nodev,noexec,nosuid; then
                # failed to mount
                exit 1
        fi
}

check_if_boot_dev()
{
                ret_val=`cat /proc/cmdline | grep "androidboot.bootdevice" |wc -l`
                if  [ $ret_val -ne 0 ]; then
                    boot_dev_list=`cat /proc/cmdline | awk '{ for ( n=1; n<=NF; n++ ) if($n ~ "androidboot.bootdevice") print $n }' | awk '{split($0,a, "=");print a[2]}'`
                    boot_dev=`echo $boot_dev_list | awk '{print $NF}'`
                    real_sysfs_path=`realpath /sys/class/block/$1`
                    ret_val=`echo $real_sysfs_path | grep /sys/devices/ | grep $boot_dev | wc -l`
                fi
                echo $ret_val
}


create_symlink()
{
                real_sysfs_path=`realpath /sys/class/block/$1`
                partition_name=`cat $real_sysfs_path/uevent | awk '{ for ( n=1; n<=NF; n++ ) if($n ~ "PARTNAME") print $n }' | awk '{split($0,a, "=");print a[2]}'`
                mkdir -p /dev/block/bootdevice/by-name/
                partition_name=/dev/block/bootdevice/by-name/$partition_name
                target_dev=/dev/$1
                ln -s $target_dev $partition_name
}

case "${ACTION}" in
add|"")
        result=`check_if_boot_dev $1`
        if [ $result -eq 1 ]; then
                 create_symlink $1 &
        else
                 umount_partition ${1}
                 mount_partition ${1}
        fi
        ;;
remove)
        umount_partition ${1}
        ;;
esac

