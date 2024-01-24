#! /bin/bash

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
EDL_DIR=$DIR/edl

git clone https://github.com/bkerler/edl edl
cd $EDL_DIR
#git fetch --all if we want certain commit
git submodule update --depth=1 --init --recursive
python -m pip3 install -r $EDL_DIR/requirements.txt
