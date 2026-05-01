#!/bin/bash

SSH_PARAM="/data/params/d/SshEnabled"
if [ -f "$SSH_PARAM" ] && [ "$(< $SSH_PARAM)" == "1" ]; then
  echo "Enabling SSH"
  systemctl start ssh
else
  echo "Disabling SSH"
  systemctl stop ssh
fi
