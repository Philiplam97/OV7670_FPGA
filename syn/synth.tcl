source OV7670_FPGA_prj.tcl
read_xdc Arty-A7-35-Master.xdc
synth_design -flatten_hierarchy rebuilt -top top -part XC7A35TICSG324-1L  -assert
write_checkpoint -force OV7670_FPGA_build/top_synth.dcp
report_timing_summary -file OV7670_FPGA_build/synth_timing_summary.txt
