MAKEPATH := $(dir $(lastword $(MAKEFILE_LIST)))
MODULENAME := OmnixtendEndpoint
MODULEPATH := $(MAKEPATH)src
EXTRA_BSV_LIBS += $(MODULEPATH)

$(info Adding $(MODULENAME) from $(MODULEPATH))