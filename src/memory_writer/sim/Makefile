TOPLEVEL_LANG ?= vhdl
SIM ?= ghdl

PRJ_DIR = $(shell pwd)/../../../

#Python test file
MODULE := test_memory_writer

#VHDL top level name
TOPLEVEL := memory_writer
SRC_DIR = $(PRJ_DIR)/src/memory_writer

VHDL_SOURCES = $(PRJ_DIR)/src/common/OV7670_util_pkg.vhd
VHDL_SOURCES += $(PRJ_DIR)/src/common/ram_sdp.vhd
VHDL_SOURCES += $(PRJ_DIR)/src/common/fifo_sync.vhd
VHDL_SOURCES += $(SRC_DIR)/axi_writer/axi_writer.vhd
VHDL_SOURCES += $(SRC_DIR)/burst_write_fifo/burst_write_fifo.vhd
VHDL_SOURCES += $(SRC_DIR)/memory_writer.vhd

# Dump waves
SIM_ARGS +=--wave=waves.ghw
EXTRA_ARGS += --std=08
SIM_BUILD = sim_build

include $(shell cocotb-config --makefiles)/Makefile.sim
