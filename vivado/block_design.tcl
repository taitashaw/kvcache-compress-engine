# KV-Cache Compression Engine -- Vivado Block Design + DMA + Bitstream
set proj_name  "kvcache_soc"
set proj_dir   "."
set part       "xczu7ev-ffvc1156-2-e"
set board      "xilinx.com:zcu104:part0:1.1"
set bd_name    "kvcache_bd"
set top_module "kvcache_compress_wrapper"

set rtl_files [list \
    "../../rtl/group_quantizer.sv" \
    "../../rtl/group_dequantizer.sv" \
    "../../rtl/kvcache_compress_top.sv" \
    "../../rtl/kvcache_compress_wrapper.v" \
]

# ============================================================
# Step 1: Create Project
# ============================================================
puts ""
puts "============================================"
puts "  Step 1: Creating Vivado Project"
puts "============================================"

create_project $proj_name $proj_dir -part $part -force
catch {set_property board_part $board [current_project]}
set_property target_language Verilog [current_project]

foreach f $rtl_files { add_files -norecurse $f }
update_compile_order -fileset sources_1

# ============================================================
# Step 2: Create Block Design
# ============================================================
puts ""
puts "============================================"
puts "  Step 2: Creating Block Design"
puts "============================================"

create_bd_design $bd_name

# ---- Zynq PS ----
set zynq [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 zynq_ps]
catch {
    apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
        -config {apply_board_preset "1"} $zynq
}

set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0       {1} \
    CONFIG.PSU__USE__M_AXI_GP1       {0} \
    CONFIG.PSU__USE__M_AXI_GP2       {0} \
    CONFIG.PSU__USE__S_AXI_GP2       {1} \
    CONFIG.PSU__USE__IRQ0            {1} \
    CONFIG.PSU__FPGA_PL0_ENABLE      {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {400} \
] $zynq

# ---- Our compression engine ----
set compress_ip [create_bd_cell -type module -reference $top_module compress_engine]

# ---- AXI DMA (data path: DDR4 <-> AXI-Stream <-> compress_engine) ----
set axi_dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0]
set_property -dict [list \
    CONFIG.c_include_sg          {0} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_include_mm2s        {1} \
    CONFIG.c_include_s2mm        {1} \
    CONFIG.c_mm2s_burst_size     {16} \
    CONFIG.c_s2mm_burst_size     {16} \
    CONFIG.c_m_axi_mm2s_data_width {32} \
    CONFIG.c_m_axis_mm2s_tdata_width {16} \
    CONFIG.c_m_axi_s2mm_data_width {32} \
    CONFIG.c_s_axis_s2mm_tdata_width {16} \
] $axi_dma

# ---- AXI Interconnect for DMA CSR (PS -> DMA registers) ----
set axi_ic_dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_1]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] $axi_ic_dma

# ---- AXI SmartConnect for DMA memory access (DMA -> DDR4 via HP port) ----
set smartconnect [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_0]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $smartconnect

# ---- Processor System Reset ----
set ps_rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]

# ---- Concat for interrupts (DMA mm2s_introut + s2mm_introut + irq_done) ----
set concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0]
set_property -dict [list CONFIG.NUM_PORTS {3}] $concat

# ============================================================
# Step 3: Wire Block Design
# ============================================================
puts ""
puts "============================================"
puts "  Step 3: Wiring Block Design"
puts "============================================"

# ---- Clock distribution ----
set pl_clk [get_bd_pins zynq_ps/pl_clk0]

connect_bd_net $pl_clk [get_bd_pins compress_engine/clk]
connect_bd_net $pl_clk [get_bd_pins axi_interconnect_1/ACLK]
connect_bd_net $pl_clk [get_bd_pins axi_interconnect_1/S00_ACLK]
connect_bd_net $pl_clk [get_bd_pins axi_interconnect_1/M00_ACLK]
connect_bd_net $pl_clk [get_bd_pins axi_interconnect_1/M01_ACLK]
connect_bd_net $pl_clk [get_bd_pins axi_dma_0/s_axi_lite_aclk]
connect_bd_net $pl_clk [get_bd_pins axi_dma_0/m_axi_mm2s_aclk]
connect_bd_net $pl_clk [get_bd_pins axi_dma_0/m_axi_s2mm_aclk]
connect_bd_net $pl_clk [get_bd_pins smartconnect_0/aclk]
connect_bd_net $pl_clk [get_bd_pins proc_sys_reset_0/slowest_sync_clk]

# FPD AXI master clock (proven fix from softmax project)
connect_bd_net $pl_clk [get_bd_pins zynq_ps/maxihpm0_fpd_aclk]
# HP slave clock
connect_bd_net $pl_clk [get_bd_pins zynq_ps/saxihp0_fpd_aclk]

# ---- Reset distribution ----
connect_bd_net [get_bd_pins zynq_ps/pl_resetn0] [get_bd_pins proc_sys_reset_0/ext_reset_in]

set periph_rstn [get_bd_pins proc_sys_reset_0/peripheral_aresetn]
connect_bd_net $periph_rstn [get_bd_pins compress_engine/rst_n]
connect_bd_net $periph_rstn [get_bd_pins axi_interconnect_1/ARESETN]
connect_bd_net $periph_rstn [get_bd_pins axi_interconnect_1/S00_ARESETN]
connect_bd_net $periph_rstn [get_bd_pins axi_interconnect_1/M00_ARESETN]
connect_bd_net $periph_rstn [get_bd_pins axi_interconnect_1/M01_ARESETN]
connect_bd_net $periph_rstn [get_bd_pins axi_dma_0/axi_resetn]
connect_bd_net $periph_rstn [get_bd_pins smartconnect_0/aresetn]

# ---- CSR Path: PS -> AXI Interconnect 1 -> {DMA CSR, Compress Engine CSR} ----

# PS FPD master -> interconnect_1 slave
set ps_axi_connected 0
foreach ps_port {M_AXI_HPM0_FPD M_AXI_HPM0_LPD M_AXI_HPM1_FPD} {
    if {[catch {
        connect_bd_intf_net [get_bd_intf_pins zynq_ps/${ps_port}] \
                            [get_bd_intf_pins axi_interconnect_1/S00_AXI]
    }]} {
        puts "  PS port '${ps_port}' not found, trying next..."
    } else {
        puts "  Connected PS AXI: zynq_ps/${ps_port}"
        set ps_axi_connected 1
        break
    }
}
if {!$ps_axi_connected} { error "No PS AXI master port found" }

# interconnect_1 M00 -> compress_engine CSR (AXI-Lite)
set intf_connected 0
foreach intf_name {s_axil s_axi S_AXI s_axil_0} {
    if {[catch {
        connect_bd_intf_net [get_bd_intf_pins axi_interconnect_1/M00_AXI] \
                            [get_bd_intf_pins compress_engine/${intf_name}]
    }]} {
        puts "  Interface '${intf_name}' not found, trying next..."
    } else {
        puts "  Connected CSR via: compress_engine/${intf_name}"
        set intf_connected 1
        break
    }
}
if {!$intf_connected} { error "Could not connect AXI-Lite to compress engine" }

# interconnect_1 M01 -> DMA CSR (AXI-Lite)
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_1/M01_AXI] \
                    [get_bd_intf_pins axi_dma_0/S_AXI_LITE]

# ---- Data Path: DMA <-> AXI-Stream <-> Compress Engine ----

# DMA MM2S (memory->stream) -> compress_engine s_axis_data (KV data in)
set stream_in_connected 0
foreach stream_name {s_axis_data s_axis_data_0} {
    if {[catch {
        connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] \
                            [get_bd_intf_pins compress_engine/${stream_name}]
    }]} {
        puts "  Stream in '${stream_name}' not found, trying next..."
    } else {
        puts "  Connected DMA MM2S -> compress_engine/${stream_name}"
        set stream_in_connected 1
        break
    }
}
if {!$stream_in_connected} { error "Could not connect DMA MM2S to compress engine" }

# compress_engine m_axis_data (restored data out) -> DMA S2MM (stream->memory)
set stream_out_connected 0
foreach stream_name {m_axis_data m_axis_data_0} {
    if {[catch {
        connect_bd_intf_net [get_bd_intf_pins compress_engine/${stream_name}] \
                            [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]
    }]} {
        puts "  Stream out '${stream_name}' not found, trying next..."
    } else {
        puts "  Connected compress_engine/${stream_name} -> DMA S2MM"
        set stream_out_connected 1
        break
    }
}
if {!$stream_out_connected} { error "Could not connect compress engine to DMA S2MM" }

# ---- DMA Memory Path: DMA -> SmartConnect -> PS HP port -> DDR4 ----
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] [get_bd_intf_pins smartconnect_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] [get_bd_intf_pins smartconnect_0/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M00_AXI] [get_bd_intf_pins zynq_ps/S_AXI_HP0_FPD]

# ---- Interrupts: DMA + compress_engine -> concat -> PS ----
connect_bd_net [get_bd_pins axi_dma_0/mm2s_introut]  [get_bd_pins xlconcat_0/In0]
connect_bd_net [get_bd_pins axi_dma_0/s2mm_introut]   [get_bd_pins xlconcat_0/In1]
connect_bd_net [get_bd_pins compress_engine/irq_done]  [get_bd_pins xlconcat_0/In2]
connect_bd_net [get_bd_pins xlconcat_0/dout]           [get_bd_pins zynq_ps/pl_ps_irq0]

# ---- Address Map ----
assign_bd_address

# ============================================================
# Step 4: Validate
# ============================================================
puts ""
puts "============================================"
puts "  Step 4: Validating Block Design"
puts "============================================"

validate_bd_design
save_bd_design

make_wrapper -files [get_files ${bd_name}.bd] -top
add_files -norecurse ${proj_dir}/${proj_name}.gen/sources_1/bd/${bd_name}/hdl/${bd_name}_wrapper.v
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

# ============================================================
# Step 5: Synthesis
# ============================================================
puts ""
puts "============================================"
puts "  Step 5: Running Synthesis"
puts "============================================"

set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
launch_runs synth_1 -jobs 4
wait_on_run synth_1

# ============================================================
# Step 6: Implementation
# ============================================================
puts ""
puts "============================================"
puts "  Step 6: Running Implementation"
puts "============================================"

launch_runs impl_1 -jobs 4
wait_on_run impl_1

open_run impl_1
report_utilization -file utilization_bd.rpt
report_timing_summary -file timing_bd.rpt -max_paths 10
puts ""
puts [report_utilization -return_string]
puts ""
puts [report_timing_summary -return_string]

# ============================================================
# Step 7: Bitstream
# ============================================================
puts ""
puts "============================================"
puts "  Step 7: Generating Bitstream"
puts "============================================"

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

# ============================================================
# Step 8: Export XSA
# ============================================================
puts ""
puts "============================================"
puts "  Step 8: Exporting Hardware (XSA)"
puts "============================================"

write_hw_platform -fixed -include_bit -file ${proj_dir}/${proj_name}.xsa

puts ""
puts "============================================"
puts "  BLOCK DESIGN BUILD COMPLETE (WITH DMA)"
puts "============================================"
puts ""
puts "  SoC Architecture:"
puts "    Zynq PS -> AXI Interconnect -> Compress Engine (CSR)"
puts "                                -> AXI DMA (CSR)"
puts "    AXI DMA MM2S -> compress_engine s_axis_data (KV in)"
puts "    compress_engine m_axis_data -> AXI DMA S2MM (restored out)"
puts "    AXI DMA -> SmartConnect -> Zynq HP0 -> DDR4"
puts ""
puts "  Bitstream: ${proj_name}.runs/impl_1/${bd_name}_wrapper.bit"
puts "  XSA:       ${proj_name}.xsa"
puts ""
