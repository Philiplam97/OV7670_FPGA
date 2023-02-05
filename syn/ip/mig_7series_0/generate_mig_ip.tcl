# Refer to UG586: Zynq-7000 SoC and 7 Series FPGAs MIS v4.2 
# Chapter 6: Upgrading the ISE/CORE Generator MIG Core in Vivado

# This script will create the mig xci based on the configurations provided in the
# mig.prj file.
create_project -in_memory -part XC7A35TICSG324-1L
create_ip -name mig_7series -vendor xilinx.com -library ip -module_name mig_7series_0
set_property CONFIG.XML_INPUT_FILE [file normalize ./mig_a.prj] [get_ips mig_7series_0]
