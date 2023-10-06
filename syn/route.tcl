open_checkpoint OV7670_FPGA_build/top_synth.dcp
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force OV7670_FPGA_build/top_route.dcp
report_timing_summary -file OV7670_FPGA_build/route_timing_summary.txt
report_timing -sort_by group -max_paths 100 -path_type summary -file OV7670_FPGA_build/route_timing.txt
report_utilization -file OV7670_FPGA_build/route_util.txt
write_debug_probes -force probes.ltx
