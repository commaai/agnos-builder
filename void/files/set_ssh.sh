#!/bin/bash
# Void Linux version - uses sv instead of systemctl

# During development: always enable SSH
# TODO: Re-enable param check for production
echo "Enabling SSH"
sv up sshd

# SSH_PARAM="/data/params/d/SshEnabled"
# if [ -f "$SSH_PARAM" ] && [ "$(< $SSH_PARAM)" == "1" ]; then
#   echo "Enabling SSH"
#   sv up sshd
# else
#   echo "Disabling SSH"
#   sv down sshd
# fi
