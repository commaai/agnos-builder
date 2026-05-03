#!/bin/bash

SSH_PARAM="/data/params/d/SshEnabled"
if [ -f "$SSH_PARAM" ] && [ "$(< $SSH_PARAM)" == "1" ]; then
  echo "Enabling SSH"
  /usr/comma/shims/systemctl start ssh
else
  echo "Disabling SSH"
  /usr/comma/shims/systemctl stop ssh
fi
