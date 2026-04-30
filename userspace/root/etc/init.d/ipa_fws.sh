#!/bin/sh
#==============================================================================
# FILE: ipa_fws.sh
#
# DESCRIPTION:
# Indicate to IPA driver that FWs are available from user space for fetching
# and loading
#
# Copyright (c) 2017 Qualcomm Technologies, Inc.
# All Rights Reserved.
# Confidential and Proprietary - Qualcomm Technologies, Inc.
#==============================================================================
# Look for ipa_config.txt file and cat it's content to /dev/ipa before ipa is ready.
# A write of 1 or MHI to /dev/ipa will indicate that user space is available and the
# FWs can be fetched.
FILE=/data/misc/ipa/ipa_config.txt
if [ -f $FILE ]; then
  echo $(cat $FILE) > /dev/ipa
fi
# replace 1 with mhi if mhi usecases is execersized.
echo 1 > /dev/ipa
