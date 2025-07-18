#!/bin/bash

# Read the raw device model
RAW_MODEL=$(tr -d '\0' < /sys/firmware/devicetree/base/model)

# Extract the device model (e.g., tici, tizi, mici)
MODEL=$(echo "$RAW_MODEL" | sed 's/comma //g' | awk '{print $1}')

[ -z "$MODEL" ] && MODEL="unknown"

HOSTNAME=$(hostname)
SERVICE_NAME="comma SSH - $MODEL - [$HOSTNAME]"

ALIAS_FILE="/data/params/d_tmp/ApiCache_Device"
ALIAS=$(jq -e -r '.alias // empty' "$ALIAS_FILE" 2>/dev/null | grep -E '\S' || echo "$RAW_MODEL")

# Publish avahi service
exec avahi-publish -s "$SERVICE_NAME" _ssh._tcp 22 "vendor=comma" "device=comma" "model=$MODEL" "alias=$ALIAS"
