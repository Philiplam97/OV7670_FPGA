set src_dir [file join [file dirname [info script]] .. src]
set ip_dir [file join [file dirname [info script]] .. syn ip]

# Common
read_vhdl -vhdl2008 [file join $src_dir common OV7670_util_pkg.vhd]
read_vhdl -vhdl2008 [file join $src_dir common ram_sdp.vhd]
read_vhdl -vhdl2008 [file join $src_dir common fifo_sync.vhd]
read_vhdl -vhdl2008 [file join $src_dir common button_debouncer.vhd]
read_vhdl -vhdl2008 [file join $src_dir common ram_sdp_dual_clk.vhd]
read_vhdl -vhdl2008 [file join $src_dir common sync_ff.vhd]
read_vhdl -vhdl2008 [file join $src_dir common sync_pulse.vhd]
read_vhdl -vhdl2008 [file join $src_dir common fifo_async fifo_async.vhd]

# Memory reader
read_vhdl -vhdl2008 [file join $src_dir memory_reader axi_reader axi_reader.vhd]
read_vhdl -vhdl2008 [file join $src_dir memory_reader burst_read_fifo burst_read_fifo.vhd]
read_vhdl -vhdl2008 [file join $src_dir memory_reader memory_reader.vhd]

# Memory Writer
read_vhdl -vhdl2008 [file join $src_dir memory_writer axi_writer axi_writer.vhd]
read_vhdl -vhdl2008 [file join $src_dir memory_writer burst_write_fifo burst_write_fifo.vhd]
read_vhdl -vhdl2008 [file join $src_dir memory_writer memory_writer.vhd]

# VGA
read_vhdl -vhdl2008 [file join $src_dir vga vga.vhd]

#SCCB & Capture
read_vhdl -vhdl2008 [file join $src_dir OV7670_wrapper capture capture.vhd]
read_vhdl -vhdl2008 [file join $src_dir OV7670_wrapper SCCB SCCB.vhd]
read_vhdl -vhdl2008 [file join $src_dir OV7670_wrapper OV7670_regs_pkg.vhd]
read_vhdl -vhdl2008 [file join $src_dir OV7670_wrapper OV7670_wrapper.vhd]

read_ip [file join $ip_dir mig_7series_0  mig_7series_0.xci]
read_ip [file join $ip_dir ila_256_2k  ila_256_2k.xci]

read_vhdl -vhdl2008 [file join $src_dir top.vhd]
