#!/bin/bash
scp output/linux-headers*.deb tici:/tmp/
ssh tici "sudo apt install -yq /tmp/linux-headers*.deb"

