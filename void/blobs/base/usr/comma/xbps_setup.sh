#!/bin/bash -e

mount -o rw,remount /
resize2fs $(findmnt -n -o SOURCE /) 2>/dev/null || true
mount -o remount,size=1500M /var
