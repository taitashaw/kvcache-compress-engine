`timescale 1ns / 1ps

module kvcache_compress_wrapper #(
    parameter MAX_SEQ_LEN  = 4096,
    parameter HEAD_DIM     = 128,
    parameter GROUP_SIZE   = 64,
    parameter MAX_OUTLIERS = 4
)(
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Lite Slave (CSR)
    input  wire [7:0]  s_axil_awaddr,
    input  wire        s_axil_awvalid,
    output wire        s_axil_awready,
    input  wire [31:0] s_axil_wdata,
    input  wire [3:0]  s_axil_wstrb,
    input  wire        s_axil_wvalid,
    output wire        s_axil_wready,
    output wire [1:0]  s_axil_bresp,
    output wire        s_axil_bvalid,
    input  wire        s_axil_bready,
    input  wire [7:0]  s_axil_araddr,
    input  wire        s_axil_arvalid,
    output wire        s_axil_arready,
    output wire [31:0] s_axil_rdata,
    output wire [1:0]  s_axil_rresp,
    output wire        s_axil_rvalid,
    input  wire        s_axil_rready,

    // AXI4-Stream Slave -- KV data in (from DMA)
    input  wire [15:0] s_axis_data_tdata,
    input  wire        s_axis_data_tvalid,
    output wire        s_axis_data_tready,
    input  wire        s_axis_data_tlast,

    // AXI4-Stream Master -- Restored KV data out (to DMA)
    output wire [15:0] m_axis_data_tdata,
    output wire        m_axis_data_tvalid,
    input  wire        m_axis_data_tready,
    output wire        m_axis_data_tlast,

    // Interrupt
    output wire        irq_done
);

    kvcache_compress_top #(
        .MAX_SEQ_LEN(MAX_SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .GROUP_SIZE(GROUP_SIZE),
        .MAX_OUTLIERS(MAX_OUTLIERS)
    ) u_core (
        .clk(clk), .rst_n(rst_n),
        .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb),
        .s_axil_wvalid(s_axil_wvalid), .s_axil_wready(s_axil_wready),
        .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid), .s_axil_bready(s_axil_bready),
        .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid), .s_axil_arready(s_axil_arready),
        .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp),
        .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready),
        .s_axis_data_tdata(s_axis_data_tdata), .s_axis_data_tvalid(s_axis_data_tvalid),
        .s_axis_data_tready(s_axis_data_tready), .s_axis_data_tlast(s_axis_data_tlast),
        .m_axis_data_tdata(m_axis_data_tdata), .m_axis_data_tvalid(m_axis_data_tvalid),
        .m_axis_data_tready(m_axis_data_tready), .m_axis_data_tlast(m_axis_data_tlast),
        .irq_done(irq_done)
    );

endmodule
