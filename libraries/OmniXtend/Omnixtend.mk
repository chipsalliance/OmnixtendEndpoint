#
# SPDX-License-Identifier: Apache License 2.0
# SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.
# Author: Jaco Hofmann (jaco.hofmann@wdc.com)
#

MAKEPATH := $(dir $(lastword $(MAKEFILE_LIST)))
MODULENAME := OmniXtend
MODULEPATH := $(MAKEPATH)src
EXTRA_BSV_LIBS += $(MODULEPATH)

$(info Adding $(MODULENAME) from $(MODULEPATH))
