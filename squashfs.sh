#!/bin/bash

rm -rf output/system.squash*

#mksquashfs build/agnos-rootfs output/system.squashfs.lzo -comp lzo -b 1M -no-xattrs
#sudo mksquashfs build/agnos-rootfs output/system.squashfs.gzip -comp gzip -Xcompression-level 1 -b 1M -no-xattrs
sudo mksquashfs build/agnos-rootfs output/system.squashfs.lz4 -comp lz4 -b 4k -no-fragments -no-xattrs # -no-acls

du -hs output/sys*
