###
# DO NOT CHANGE
###
BRAM_SIM?=0
ifeq (${BRAM_SIM}, 1)
TOP_MODULE=mkOmnixtendEndpointBRAM
MAIN_MODULE=OmnixtendEndpointBRAM
else
TOP_MODULE=mkOmnixtendEndpoint
MAIN_MODULE=OmnixtendEndpoint
endif
TESTBENCH_MODULE=mkTestbench
IGNORE_MODULES=mkTestbench mkTestsMainTest
TESTBENCH_FILE=src/Testbench.bsv

# Initialize
-include .bsv_tools
ifndef BSV_TOOLS
	$(error BSV_TOOLS is not set (Check .bsv_tools or specify it through the command line))
endif
VIVADO_ADD_PARAMS := ''
CONSTRAINT_FILES := ''
EXTRA_BSV_LIBS:=
EXTRA_LIBRARIES:=
RUN_FLAGS:=
BASE_DIR:=${BSV_TOOLS}

OX_11_MODE?=1
RESEND_SIZE?=15
RESEND_TIMEOUT_CYCLES_LOG2?=21
ACK_TIMEOUT_CYCLES_LOG2?=12
OMNIXTEND_CONNECTIONS?=8
MAXIMUM_PACKET_SIZE?=9000
MAXIMUM_TL_PER_FRAME?=64

RUN_TEST?=TestsMainTest

MAC_ADDR?=0

MAC_ADDR_INT=$(shell printf "%d" 0x$(MAC_ADDR))
$(info Using MAC ${MAC_ADDR_INT})

PROJECT_NAME=OmnixtendEndpoint_RES_$(RESEND_SIZE)_RESTO_$(RESEND_TIMEOUT_CYCLES_LOG2)_ACKTO_$(ACK_TIMEOUT_CYCLES_LOG2)_OX11_$(OX_11_MODE)_MAC_$(MAC_ADDR)_CON_${OMNIXTEND_CONNECTIONS}_MAXFRAME_${MAXIMUM_PACKET_SIZE}_MAXTLFRAME_${MAXIMUM_TL_PER_FRAME}_BRAMSIM_${BRAM_SIM}

# Default flags
EXTRA_FLAGS=-D "RUN_TEST=$(RUN_TEST)" -D "TESTNAME=mk$(RUN_TEST)"
EXTRA_FLAGS+=-show-schedule -D "BSV_TIMESCALE=1ns/1ps"
EXTRA_FLAGS+=-D "RESEND_SIZE=$(RESEND_SIZE)"
EXTRA_FLAGS+=-D "MAC_ADDR=$(MAC_ADDR_INT)"
EXTRA_FLAGS+=-D "OX_11_MODE=$(OX_11_MODE)"
EXTRA_FLAGS+=-D "RESEND_TIMEOUT_CYCLES_LOG2=$(RESEND_TIMEOUT_CYCLES_LOG2)" -D "ACK_TIMEOUT_CYCLES_LOG2=$(ACK_TIMEOUT_CYCLES_LOG2)"
EXTRA_FLAGS+=-D OMNIXTEND_CONNECTIONS=${OMNIXTEND_CONNECTIONS} -D MAXIMUM_PACKET_SIZE=${MAXIMUM_PACKET_SIZE} -D MAXIMUM_TL_PER_FRAME=${MAXIMUM_TL_PER_FRAME}
ifdef SYNTH_MODULES
EXTRA_FLAGS+=-D SYNTH_MODULES
endif

###
# User configuration
###

# Comment the following line if -O3 should be used during compilation
# Keep uncommented for short running simulations
CXX_NO_OPT := 1

# Any additional files added during compilation
# For instance for BDPI or Verilog/VHDL files for simulation
# CPP_FILES += $(current_dir)/src/mem_sim.cpp

# Custom defines added to compile steps
EXTRA_FLAGS+=-I "$(PWD)/rust_sim/omnixtend_endpoint_sim.h"
EXTRA_FLAGS+=-L $(PWD)/rust_sim/target/release
EXTRA_FLAGS+=-l omnixtend_endpoint_sim
EXTRA_FLAGS+=-aggressive-conditions

# Flags added to simulator execution
# RUN_FLAGS+=-V dump.vcd

# Add additional parameters for IP-XACT generation. Passed directly to Vivado.
# Any valid TCL during packaging is allowed
# Typically used to fix automatic inference for e.g. clock assignments
# VIVADO_ADD_PARAMS += 'ipx::associate_bus_interfaces -busif M_AXI -clock sconfig_axi_aclk [ipx::current_core]'

 VIVADO_ADD_PARAMS += 'set busif M_AXI'
 VIVADO_ADD_PARAMS += 'ipx::associate_bus_interfaces -busif $${busif} -clock sconfig_axi_aclk [ipx::current_core]'

 VIVADO_ADD_PARAMS += 'for {set i 0} {$$i < 1} {incr i} {'
 VIVADO_ADD_PARAMS += 'ipx::infer_bus_interface sfp_axis_tx_aclk_$${i} xilinx.com:signal:clock_rtl:1.0 [ipx::current_core]'
 VIVADO_ADD_PARAMS += 'ipx::infer_bus_interface sfp_axis_rx_aclk_$${i} xilinx.com:signal:clock_rtl:1.0 [ipx::current_core]'
 VIVADO_ADD_PARAMS += 'ipx::infer_bus_interface sfp_axis_tx_aresetn_$${i} xilinx.com:signal:reset_rtl:1.0 [ipx::current_core]'
 VIVADO_ADD_PARAMS += 'ipx::infer_bus_interface sfp_axis_rx_aresetn_$${i} xilinx.com:signal:reset_rtl:1.0 [ipx::current_core]'
 VIVADO_ADD_PARAMS += 'set_property VALUE "" [ipx::add_bus_parameter ASSOCIATED_RESET [ipx::get_bus_interfaces sfp_axis_tx_aclk_$${i} -of_objects [ipx::current_core]]]'
 VIVADO_ADD_PARAMS += 'ipx::associate_bus_interfaces -busif sfp_axis_tx_$${i} -clock sfp_axis_tx_aclk_$${i} -reset sfp_axis_tx_aresetn_$${i} [ipx::current_core]'
 VIVADO_ADD_PARAMS += 'ipx::associate_bus_interfaces -busif sfp_axis_rx_$${i} -clock sfp_axis_rx_aclk_$${i} -reset sfp_axis_rx_aresetn_$${i} [ipx::current_core]'
 VIVADO_ADD_PARAMS += '}'

# Add custom constraint files, Syntax: Filename,Load Order
CONSTRAINT_FILES += "$(PWD)/constraints/custom.xdc,LATE"

# Do not change: Load libraries such as BlueAXI or BlueLib
ifneq ("$(wildcard $(PWD)/libraries/*/*.mk)", "")
include $(PWD)/libraries/*/*.mk
endif

# Do not change: Include base makefile
include ${BSV_TOOLS}/scripts/rules.mk
