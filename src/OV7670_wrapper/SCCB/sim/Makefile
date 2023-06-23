TOPLEVEL_LANG ?= vhdl
SIM ?= ghdl

PRJ_DIR = $(shell pwd)/../../../

#Python test file
MODULE := test_SCCB

#VHDL top level name
TOPLEVEL := sccb

VHDL_SOURCES = $(PRJ_DIR)/src/common/OV7670_util_pkg.vhd
VHDL_SOURCES += $(PRJ_DIR)/src/SCCB/SCCB.vhd

# Dump waves
SIM_ARGS +=--wave=waves.ghw
EXTRA_ARGS += --std=08
SIM_BUILD = sim_build

include $(shell cocotb-config --makefiles)/Makefile.sim
