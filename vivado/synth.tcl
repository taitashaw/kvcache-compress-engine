# KV-Cache Compression Engine -- Vivado Synthesis @ 400 MHz
set top "kvcache_compress_top"
set part "xczu7ev-ffvc1156-2-e"
set proj_name "kvcache_synth"
set proj_dir "."

create_project $proj_name $proj_dir -part $part -force
set_property target_language Verilog [current_project]

add_files -norecurse {
    ../../rtl/group_quantizer.sv
    ../../rtl/group_dequantizer.sv
    ../../rtl/kvcache_compress_top.sv
}
update_compile_order -fileset sources_1

# Timing constraints -- false_path on I/O (proven from softmax project)
set xdc_file "timing.xdc"
set xdc_fd [open $xdc_file w]
puts $xdc_fd "# 400 MHz clock constraint"
puts $xdc_fd "create_clock -period 2.500 -name sys_clk \[get_ports clk\]"
puts $xdc_fd ""
puts $xdc_fd "set_false_path -from \[get_ports rst_n\]"
puts $xdc_fd "set_false_path -to \[get_ports s_axil_*\]"
puts $xdc_fd "set_false_path -from \[get_ports s_axil_*\]"
puts $xdc_fd "set_false_path -to \[get_ports irq_done\]"
puts $xdc_fd "# AXI4-Stream data ports (DMA path -- false_path for standalone synth)"
puts $xdc_fd "set_false_path -from \[get_ports s_axis_data_*\]"
puts $xdc_fd "set_false_path -to \[get_ports s_axis_data_*\]"
puts $xdc_fd "set_false_path -from \[get_ports m_axis_data_*\]"
puts $xdc_fd "set_false_path -to \[get_ports m_axis_data_*\]"
close $xdc_fd
add_files -fileset constrs_1 $xdc_file

# Synthesis
puts ""
puts "Running synthesis..."
synth_design -top $top -part $part
report_utilization -file utilization_synth.rpt
report_timing_summary -file timing_synth.rpt -max_paths 10
report_power -file power_synth.rpt
write_checkpoint -force ${top}_synth.dcp

# Implementation
puts ""
puts "Running implementation..."
opt_design
place_design
route_design

puts ""
puts [report_utilization -return_string]
puts ""
puts [report_timing_summary -return_string]

report_utilization -file utilization_impl.rpt
report_timing_summary -file timing_impl.rpt -max_paths 10
write_checkpoint -force ${top}_impl.dcp

close_project
