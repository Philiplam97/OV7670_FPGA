TOPLEVEL_LANG ?= vhdl
SIM ?= ghdl

PRJ_DIR = $(shell pwd)/../../../../

#Python test file
MODULE := test_capture

#VHDL top level name
TOPLEVEL := capture

VHDL_SOURCES = $(PRJ_DIR)/src/common/OV7670_util_pkg.vhd
VHDL_SOURCES += $(PRJ_DIR)/src/OV7670_wrapper/capture/capture.vhd

# Dump waves
SIM_ARGS +=--wave=waves.ghw
EXTRA_ARGS += --std=08
SIM_BUILD = sim_build

include $(shell cocotb-config --makefiles)/Makefile.sim
