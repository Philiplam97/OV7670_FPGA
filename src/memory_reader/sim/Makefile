TOPLEVEL_LANG ?= vhdl
SIM ?= ghdl

PRJ_DIR = $(shell pwd)/../../../

#Python test file
MODULE := test_memory_reader

#VHDL top level name
TOPLEVEL := memory_reader
SRC_DIR = $(PRJ_DIR)/src/memory_reader

VHDL_SOURCES = $(PRJ_DIR)/src/common/OV7670_util_pkg.vhd
VHDL_SOURCES += $(PRJ_DIR)/src/common/ram_sdp.vhd
VHDL_SOURCES += $(PRJ_DIR)/src/common/fifo_sync.vhd
VHDL_SOURCES += $(SRC_DIR)/axi_reader/axi_reader.vhd
VHDL_SOURCES += $(SRC_DIR)/burst_read_fifo/burst_read_fifo.vhd
VHDL_SOURCES += $(SRC_DIR)/memory_reader.vhd

# Dump waves
SIM_ARGS +=--wave=waves.ghw
EXTRA_ARGS += --std=08
SIM_BUILD = sim_build


include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: clean_ghdl

# Delete all the files dumped by GHDL
clean_ghdl : clean
	rm -f *.exe
	rm -f *.o
	rm -f *.xml
	rm -f *.ghw
