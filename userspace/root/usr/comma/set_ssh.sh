#!/bin/bash
set -e

SSH_PARAM="/data/params/d/SshEnabled"
if [ -f "$SSH_PARAM" ] && [ "$(< $SSH_PARAM)" == "1" ]; then
  echo "Enabling SSH"
  sv up /etc/service/sshd
else
  echo "Disabling SSH"
  sv down /etc/service/sshd
fi
