#!/bin/bash
scp output/linux-headers*.deb comma@comma:/tmp/
scp output/linux-image*.deb comma@comma:/tmp/
ssh comma@comma "sudo apt install -yq /tmp/linux-*.deb"
