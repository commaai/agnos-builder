#!/bin/bash
# Void Linux version - uses sv instead of systemctl

SSH_PARAM="/data/params/d/SshEnabled"
if [ -f "$SSH_PARAM" ] && [ "$(< $SSH_PARAM)" == "1" ]; then
  echo "Enabling SSH"
  sv up sshd
else
  echo "Disabling SSH"
  sv down sshd
fi
