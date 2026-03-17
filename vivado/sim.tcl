# KV-Cache Compression Engine -- Vivado xsim
set proj_name "kvcache_sim"
set proj_dir "."
set part "xczu7ev-ffvc1156-2-e"

set rtl_files [list \
    "../../rtl/group_quantizer.sv" \
    "../../rtl/group_dequantizer.sv" \
    "../../rtl/kvcache_compress_top.sv" \
]

set tb_files [list \
    "../../tb/tb_top.sv" \
]

create_project $proj_name $proj_dir -part $part -force
set_property target_language Verilog [current_project]
set_property simulator_language "Mixed" [current_project]

foreach f $rtl_files { add_files -norecurse $f }
foreach f $tb_files  { add_files -fileset sim_1 -norecurse $f }

set_property top tb_top [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation

# ---- Add key waveform signals ----
create_wave_config

# Group 1: Clock and Control
add_wave /tb_top/clk
add_wave /tb_top/rst_n
add_wave /tb_top/irq_done

# Group 2: Top-Level FSM
add_wave /tb_top/dut/main_state
add_wave /tb_top/dut/dma_mode
add_wave /tb_top/dut/group_idx
add_wave /tb_top/dut/num_groups_reg
add_wave /tb_top/dut/cycle_cnt
add_wave /tb_top/dut/compress_cnt
add_wave /tb_top/dut/decompress_cnt

# Group 3: Compression Metrics
add_wave /tb_top/dut/original_bits
add_wave /tb_top/dut/compressed_bits
add_wave /tb_top/dut/outlier_cnt

# Group 4: Quantizer Pipeline
add_wave /tb_top/dut/u_quantizer/state
add_wave /tb_top/dut/u_quantizer/ingest_cnt
add_wave /tb_top/dut/u_quantizer/proc_idx
add_wave /tb_top/dut/u_quantizer/scale_val
add_wave /tb_top/dut/u_quantizer/outlier_bitmap
add_wave /tb_top/dut/u_quantizer/outlier_count

# Group 5: Quantizer AXI-Stream
add_wave /tb_top/dut/q_s_axis_tvalid
add_wave /tb_top/dut/q_s_axis_tready

# Group 6: Dequantizer Pipeline
add_wave /tb_top/dut/u_dequantizer/state
add_wave /tb_top/dut/u_dequantizer/out_idx
add_wave /tb_top/dut/dq_m_axis_tvalid
add_wave /tb_top/dut/dq_m_axis_tlast

# Group 7: DMA AXI-Stream Ports
add_wave /tb_top/dut/s_axis_data_tdata
add_wave /tb_top/dut/s_axis_data_tvalid
add_wave /tb_top/dut/s_axis_data_tready
add_wave /tb_top/dut/m_axis_data_tdata
add_wave /tb_top/dut/m_axis_data_tvalid
add_wave /tb_top/dut/m_axis_data_tready
add_wave /tb_top/dut/m_axis_data_tlast

# Group 8: Testbench Counters
add_wave /tb_top/pass_count
add_wave /tb_top/fail_count

# Run full simulation (both INT2 + INT4 runs)
restart
run 300us

# Save wave config
save_wave_config kvcache_waves.wcfg
