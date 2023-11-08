#!/bin/bash
scp output/linux-headers*.deb comma:/tmp/
ssh comma "sudo apt install -yq /tmp/linux-headers*.deb"

