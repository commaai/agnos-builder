#!/bin/bash

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
cd $DIR

dpkg-deb --build src/agnos-display agnos-display_0.0.1.deb