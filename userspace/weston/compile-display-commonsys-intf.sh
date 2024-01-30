#!/bin/bash -e

cd /tmp/weston
mkdir -p vendor/qcom/opensource/commonsys-intf
git clone -b display-sysintf.lnx.1.2.r36-rel --depth 1 --single-branch https://git.codelinaro.org/clo/le/platform/vendor/qcom-opensource/display-commonsys-intf.git vendor/qcom/opensource/commonsys-intf/display
cd vendor/qcom/opensource/commonsys-intf/display

# autoreconf --install
# ./configure
# make
