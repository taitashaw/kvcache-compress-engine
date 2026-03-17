// ==========================================================================
// KV-Cache Compression Engine -- Top Level
// ==========================================================================
// AXI4-Lite slave for CSR access + compression/decompression datapath.
//
// CSR Register Map:
//   0x00  CTRL            [0] Start compress, [1] Start decompress, [2] Abort
//   0x04  STATUS          [0] Busy, [1] Done, [2] Error
//   0x08  SEQ_LEN         Sequence length (tokens)
//   0x0C  HEAD_DIM        Head dimension
//   0x10  GROUP_SIZE      Quantization group size
//   0x14  QUANT_BITS      Bits per element (2/4/8)
//   0x18  OUTLIER_THRESH  Outlier threshold (FP16 absolute)
//   0x1C  EVICT_THRESH    Token eviction threshold (FP16)
//   0x20  WINDOW_SIZE     Protected sliding window
//   0x24  NUM_GROUPS      (read-only) Computed number of groups
//   0x30  PERF_CYCLES           Total cycles
//   0x34  PERF_COMPRESS_CYC     Compression cycles
//   0x38  PERF_DECOMPRESS_CYC   Decompression cycles
//   0x3C  PERF_COMP_RATIO       *** Compression ratio (Q8.8) ***
//   0x40  PERF_OUTLIERS         Total outliers detected
//   0x44  PERF_GROUPS           Total groups processed
//   0x48  PERF_TOKENS_EVICTED   Tokens evicted
//   0x4C  PERF_BYTES_SAVED      HBM bytes saved
//
// THE METRIC: PERF_COMP_RATIO >= 0x0800 (8.0 in Q8.8)
// ==========================================================================

`timescale 1ns / 1ps

module kvcache_compress_top #(
    parameter MAX_SEQ_LEN  = 4096,
    parameter HEAD_DIM     = 128,
    parameter GROUP_SIZE   = 64,
    parameter MAX_OUTLIERS = 4
)(
    input  logic        clk,
    input  logic        rst_n,

    // AXI4-Lite Slave (CSR)
    input  logic [7:0]  s_axil_awaddr,
    input  logic        s_axil_awvalid,
    output logic        s_axil_awready,
    input  logic [31:0] s_axil_wdata,
    input  logic [3:0]  s_axil_wstrb,
    input  logic        s_axil_wvalid,
    output logic        s_axil_wready,
    output logic [1:0]  s_axil_bresp,
    output logic        s_axil_bvalid,
    input  logic        s_axil_bready,
    input  logic [7:0]  s_axil_araddr,
    input  logic        s_axil_arvalid,
    output logic        s_axil_arready,
    output logic [31:0] s_axil_rdata,
    output logic [1:0]  s_axil_rresp,
    output logic        s_axil_rvalid,
    input  logic        s_axil_rready,

    // AXI4-Stream Slave -- KV data in (from DMA / memory)
    input  logic [15:0] s_axis_data_tdata,
    input  logic        s_axis_data_tvalid,
    output logic        s_axis_data_tready,
    input  logic        s_axis_data_tlast,

    // AXI4-Stream Master -- Restored KV data out (to DMA / memory)
    output logic [15:0] m_axis_data_tdata,
    output logic        m_axis_data_tvalid,
    input  logic        m_axis_data_tready,
    output logic        m_axis_data_tlast,

    // Interrupt
    output logic        irq_done
);

    // ---- CSR registers ----
    localparam NUM_CSR = 20;
    logic [31:0] csr [0:NUM_CSR-1];

    // CSR index definitions
    localparam CSR_CTRL            = 0;   // 0x00
    localparam CSR_STATUS          = 1;   // 0x04
    localparam CSR_SEQ_LEN         = 2;   // 0x08
    localparam CSR_HEAD_DIM        = 3;   // 0x0C
    localparam CSR_GROUP_SIZE      = 4;   // 0x10
    localparam CSR_QUANT_BITS      = 5;   // 0x14
    localparam CSR_OUTLIER_THRESH  = 6;   // 0x18
    localparam CSR_EVICT_THRESH    = 7;   // 0x1C
    localparam CSR_WINDOW_SIZE     = 8;   // 0x20
    localparam CSR_NUM_GROUPS      = 9;   // 0x24
    localparam CSR_PERF_CYCLES     = 12;  // 0x30
    localparam CSR_PERF_COMP_CYC   = 13;  // 0x34
    localparam CSR_PERF_DECOMP_CYC = 14;  // 0x38
    localparam CSR_PERF_COMP_RATIO = 15;  // 0x3C  *** THE METRIC ***
    localparam CSR_PERF_OUTLIERS   = 16;  // 0x40
    localparam CSR_PERF_GROUPS     = 17;  // 0x44
    localparam CSR_PERF_EVICTED    = 18;  // 0x48
    localparam CSR_PERF_BYTES_SAVED= 19;  // 0x4C

    // ---- AXI4-Lite write channel ----
    logic       aw_recv, w_recv;
    logic [7:0] aw_addr_reg;
    logic [31:0] w_data_reg;
    logic        axi_wr_fire;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_awready <= 1;
            s_axil_wready  <= 1;
            s_axil_bvalid  <= 0;
            s_axil_bresp   <= 2'b00;
            aw_recv <= 0;
            w_recv  <= 0;
            axi_wr_fire <= 0;
        end else begin
            axi_wr_fire <= 0;

            // AW handshake
            if (s_axil_awvalid && s_axil_awready && !aw_recv) begin
                aw_addr_reg <= s_axil_awaddr;
                aw_recv <= 1;
                s_axil_awready <= 0;
            end

            // W handshake
            if (s_axil_wvalid && s_axil_wready && !w_recv) begin
                w_data_reg <= s_axil_wdata;
                w_recv <= 1;
                s_axil_wready <= 0;
            end

            // Both received: write to CSR
            if (aw_recv && w_recv && !s_axil_bvalid) begin
                axi_wr_fire <= 1;
                s_axil_bvalid <= 1;
            end

            // B handshake
            if (s_axil_bvalid && s_axil_bready) begin
                s_axil_bvalid <= 0;
                aw_recv <= 0;
                w_recv  <= 0;
                s_axil_awready <= 1;
                s_axil_wready  <= 1;
            end
        end
    end

    // ---- AXI4-Lite read channel ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_arready <= 1;
            s_axil_rvalid  <= 0;
            s_axil_rdata   <= 32'd0;
            s_axil_rresp   <= 2'b00;
        end else begin
            if (s_axil_arvalid && s_axil_arready) begin
                s_axil_arready <= 0;
                s_axil_rvalid  <= 1;
                // Read CSR
                if (s_axil_araddr[7:2] < NUM_CSR[5:0])
                    s_axil_rdata <= csr[s_axil_araddr[7:2]];
                else
                    s_axil_rdata <= 32'd0;
            end
            if (s_axil_rvalid && s_axil_rready) begin
                s_axil_rvalid  <= 0;
                s_axil_arready <= 1;
            end
        end
    end

    // ---- Main FSM ----
    typedef enum logic [3:0] {
        MAIN_IDLE,
        MAIN_INIT,
        MAIN_COMPRESS_GROUP,
        MAIN_COMPRESS_WAIT,
        MAIN_EVICT,
        MAIN_DECOMPRESS_GROUP,
        MAIN_DECOMPRESS_WAIT,
        MAIN_NEXT_GROUP,
        MAIN_COMPUTE_RATIO,
        MAIN_DONE
    } main_state_t;

    main_state_t main_state;

    // Processing state
    logic [15:0] seq_len_reg;
    logic [15:0] head_dim_reg;
    logic [15:0] num_groups_reg;
    logic [15:0] group_idx;
    logic [31:0] cycle_cnt;
    logic [31:0] compress_cnt;
    logic [31:0] decompress_cnt;
    logic [31:0] outlier_cnt;
    logic [31:0] evicted_cnt;
    logic [31:0] original_bits;
    logic [31:0] compressed_bits;

    // Quantizer interface signals
    logic [15:0] q_s_axis_tdata;
    logic        q_s_axis_tvalid;
    logic        q_s_axis_tready;
    logic        q_s_axis_tlast;
    logic [127:0] q_out_quant_data;
    logic [15:0]  q_out_scale;
    logic [63:0]  q_out_outlier_bitmap;
    logic [3:0]   q_out_num_outliers;
    logic [15:0]  q_out_outlier_val [0:MAX_OUTLIERS-1];
    logic         q_out_valid;
    logic         q_out_ready;
    logic [31:0]  q_stat_groups;
    logic [31:0]  q_stat_outliers;

    // Dequantizer interface signals
    logic [15:0] dq_m_axis_tdata;
    logic        dq_m_axis_tvalid;
    logic        dq_m_axis_tready;
    logic        dq_m_axis_tlast;
    logic        dq_in_valid;
    logic        dq_in_ready;
    logic [31:0] dq_stat_groups;
    logic [31:0] dq_stat_cycles;

    // Simulated data for testing (BRAM-based in real design)
    logic [15:0] sim_data_buf [0:GROUP_SIZE-1];
    logic [5:0]  sim_feed_idx;
    logic        sim_feeding;

    // DMA mode: CTRL[3] = 1 -> data from AXI4-Stream, 0 -> internal self-test
    logic dma_mode;

    // ---- Instantiate Quantizer ----
    group_quantizer #(
        .GROUP_SIZE(GROUP_SIZE),
        .MAX_OUTLIERS(MAX_OUTLIERS)
    ) u_quantizer (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_quant_bits(csr[CSR_QUANT_BITS][2:0]),
        .cfg_outlier_thresh(csr[CSR_OUTLIER_THRESH][15:0]),
        .s_axis_tdata(q_s_axis_tdata),
        .s_axis_tvalid(q_s_axis_tvalid),
        .s_axis_tready(q_s_axis_tready),
        .s_axis_tlast(q_s_axis_tlast),
        .out_quant_data(q_out_quant_data),
        .out_scale(q_out_scale),
        .out_outlier_bitmap(q_out_outlier_bitmap),
        .out_num_outliers(q_out_num_outliers),
        .out_outlier_val(q_out_outlier_val),
        .out_valid(q_out_valid),
        .out_ready(q_out_ready),
        .stat_groups_processed(q_stat_groups),
        .stat_total_outliers(q_stat_outliers)
    );

    // ---- Instantiate Dequantizer ----
    group_dequantizer #(
        .GROUP_SIZE(GROUP_SIZE),
        .MAX_OUTLIERS(MAX_OUTLIERS)
    ) u_dequantizer (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_quant_bits(csr[CSR_QUANT_BITS][2:0]),
        .in_quant_data(q_out_quant_data),
        .in_scale(q_out_scale),
        .in_outlier_bitmap(q_out_outlier_bitmap),
        .in_num_outliers(q_out_num_outliers),
        .in_outlier_val(q_out_outlier_val),
        .in_valid(dq_in_valid),
        .in_ready(dq_in_ready),
        .m_axis_tdata(dq_m_axis_tdata),
        .m_axis_tvalid(dq_m_axis_tvalid),
        .m_axis_tready(dq_m_axis_tready),
        .m_axis_tlast(dq_m_axis_tlast),
        .stat_groups_decompressed(dq_stat_groups),
        .stat_decompress_cycles(dq_stat_cycles)
    );

    // ---- Main FSM + CSR write logic (single always_ff to avoid multi-driver) ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            main_state <= MAIN_IDLE;
            irq_done <= 0;
            for (int i = 0; i < NUM_CSR; i++)
                csr[i] <= 32'd0;
            // Defaults
            csr[CSR_GROUP_SIZE] <= GROUP_SIZE;
            csr[CSR_QUANT_BITS] <= 32'd2;
            csr[CSR_OUTLIER_THRESH] <= 32'h4500; // ~5.0 in FP16
            csr[CSR_WINDOW_SIZE] <= 32'd64;
            seq_len_reg <= 0;
            head_dim_reg <= 0;
            num_groups_reg <= 0;
            group_idx <= 0;
            cycle_cnt <= 0;
            compress_cnt <= 0;
            decompress_cnt <= 0;
            outlier_cnt <= 0;
            evicted_cnt <= 0;
            original_bits <= 0;
            compressed_bits <= 0;
            q_s_axis_tvalid <= 0;
            q_s_axis_tdata <= 0;
            q_s_axis_tlast <= 0;
            q_out_ready <= 0;
            dq_in_valid <= 0;
            dq_m_axis_tready <= 1;
            sim_feed_idx <= 0;
            sim_feeding <= 0;
            dma_mode <= 0;
            s_axis_data_tready <= 0;
            m_axis_data_tdata <= 0;
            m_axis_data_tvalid <= 0;
            m_axis_data_tlast <= 0;
        end else begin
            // Default: deassert one-shot signals
            irq_done <= 0;

            // AXI write to CSR (only in states that allow it)
            if (axi_wr_fire && main_state == MAIN_IDLE) begin
                if (aw_addr_reg[7:2] < NUM_CSR[5:0])
                    csr[aw_addr_reg[7:2]] <= w_data_reg;
            end

            case (main_state)
                MAIN_IDLE: begin
                    // Don't clear STATUS here -- it's sticky until next start
                    q_s_axis_tvalid <= 0;
                    q_out_ready <= 0;
                    dq_in_valid <= 0;
                    s_axis_data_tready <= 0;
                    m_axis_data_tvalid <= 0;
                    m_axis_data_tlast <= 0;

                    // Check for start command
                    if (axi_wr_fire && aw_addr_reg[7:2] == CSR_CTRL[5:0] && w_data_reg[0]) begin
                        csr[CSR_CTRL] <= w_data_reg;
                        csr[CSR_STATUS] <= 32'h00000001; // busy
                        dma_mode <= w_data_reg[3]; // CTRL[3]: 0=self-test, 1=DMA
                        seq_len_reg <= csr[CSR_SEQ_LEN][15:0];
                        head_dim_reg <= csr[CSR_HEAD_DIM][15:0];
                        // Compute number of groups
                        num_groups_reg <= (csr[CSR_SEQ_LEN][15:0] * csr[CSR_HEAD_DIM][15:0]) /
                                         16'd64;
                        group_idx <= 0;
                        cycle_cnt <= 0;
                        compress_cnt <= 0;
                        decompress_cnt <= 0;
                        outlier_cnt <= 0;
                        evicted_cnt <= 0;
                        original_bits <= 0;
                        compressed_bits <= 0;
                        main_state <= MAIN_INIT;
                    end
                end

                MAIN_INIT: begin
                    cycle_cnt <= cycle_cnt + 32'd1;
                    if (dma_mode) begin
                        // DMA mode: data comes from AXI4-Stream slave port
                        s_axis_data_tready <= 0; // will be driven in COMPRESS_GROUP
                        sim_feed_idx <= 0;
                        sim_feeding <= 0;
                    end else begin
                        // Self-test mode: generate deterministic test data
                        for (int i = 0; i < GROUP_SIZE; i++) begin
                            sim_data_buf[i] <= {1'b0, group_idx[3:0], i[5:0], 5'd0};
                        end
                        sim_feed_idx <= 0;
                        sim_feeding <= 1;
                    end
                    main_state <= MAIN_COMPRESS_GROUP;
                end

                MAIN_COMPRESS_GROUP: begin
                    cycle_cnt <= cycle_cnt + 32'd1;
                    compress_cnt <= compress_cnt + 32'd1;

                    if (dma_mode) begin
                        // DMA mode: forward AXI4-Stream input to quantizer
                        s_axis_data_tready <= q_s_axis_tready;
                        q_s_axis_tdata <= s_axis_data_tdata;
                        q_s_axis_tvalid <= s_axis_data_tvalid;
                        q_s_axis_tlast <= s_axis_data_tlast;

                        if (s_axis_data_tvalid && q_s_axis_tready && s_axis_data_tlast) begin
                            s_axis_data_tready <= 0;
                            q_s_axis_tvalid <= 0;
                            main_state <= MAIN_COMPRESS_WAIT;
                        end
                    end else begin
                        // Self-test mode: feed from sim_data_buf
                        if (sim_feeding) begin
                            q_s_axis_tdata <= sim_data_buf[sim_feed_idx];
                            q_s_axis_tvalid <= 1;
                            q_s_axis_tlast <= (sim_feed_idx == 7'd64 - 6'd1);

                            if (q_s_axis_tvalid && q_s_axis_tready) begin
                                if (sim_feed_idx == 7'd64 - 6'd1) begin
                                    sim_feeding <= 0;
                                    q_s_axis_tvalid <= 0;
                                    main_state <= MAIN_COMPRESS_WAIT;
                                end else begin
                                    sim_feed_idx <= sim_feed_idx + 6'd1;
                                end
                            end
                        end
                    end
                end

                MAIN_COMPRESS_WAIT: begin
                    cycle_cnt <= cycle_cnt + 32'd1;
                    compress_cnt <= compress_cnt + 32'd1;
                    q_out_ready <= 1;

                    if (q_out_valid && q_out_ready) begin
                        q_out_ready <= 0;
                        // Update statistics
                        outlier_cnt <= outlier_cnt + {28'd0, q_out_num_outliers};
                        original_bits <= original_bits + (GROUP_SIZE * 16);
                        // Compressed: quant_data + scale + bitmap + outlier values
                        compressed_bits <= compressed_bits +
                            (32'd64 * {29'd0, csr[CSR_QUANT_BITS][2:0]}) +
                            32'd16 + // scale
                            32'd64 + // bitmap
                            ({28'd0, q_out_num_outliers} * 32'd16); // outlier values

                        // Now decompress (loopback test)
                        dq_in_valid <= 1;
                        main_state <= MAIN_DECOMPRESS_GROUP;
                    end
                end

                MAIN_DECOMPRESS_GROUP: begin
                    cycle_cnt <= cycle_cnt + 32'd1;
                    decompress_cnt <= decompress_cnt + 32'd1;

                    // Wait for dequantizer to accept
                    if (dq_in_valid && dq_in_ready) begin
                        dq_in_valid <= 0;
                        main_state <= MAIN_DECOMPRESS_WAIT;
                    end
                end

                MAIN_DECOMPRESS_WAIT: begin
                    cycle_cnt <= cycle_cnt + 32'd1;
                    decompress_cnt <= decompress_cnt + 32'd1;

                    if (dma_mode) begin
                        // DMA mode: forward decompressed data to m_axis_data output
                        m_axis_data_tdata <= dq_m_axis_tdata;
                        m_axis_data_tvalid <= dq_m_axis_tvalid;
                        m_axis_data_tlast <= dq_m_axis_tlast;
                        dq_m_axis_tready <= m_axis_data_tready;

                        if (dq_m_axis_tvalid && dq_m_axis_tlast && m_axis_data_tready) begin
                            m_axis_data_tvalid <= 0;
                            m_axis_data_tlast <= 0;
                            main_state <= MAIN_NEXT_GROUP;
                        end
                    end else begin
                        // Self-test mode: sink decompressed data internally
                        dq_m_axis_tready <= 1;
                        if (dq_m_axis_tvalid && dq_m_axis_tlast && dq_m_axis_tready) begin
                            main_state <= MAIN_NEXT_GROUP;
                        end
                    end
                end

                MAIN_NEXT_GROUP: begin
                    cycle_cnt <= cycle_cnt + 32'd1;
                    group_idx <= group_idx + 16'd1;

                    if (group_idx + 16'd1 >= num_groups_reg) begin
                        main_state <= MAIN_COMPUTE_RATIO;
                    end else begin
                        if (!dma_mode) begin
                            sim_feed_idx <= 0;
                            sim_feeding <= 1;
                        end
                        main_state <= MAIN_COMPRESS_GROUP;
                    end
                end

                MAIN_COMPUTE_RATIO: begin
                    // Compute compression ratio in Q8.8 fixed point
                    // ratio = original_bits / compressed_bits
                    // AVOID division -- it creates a 125-CARRY8 chain that can't close timing
                    // Instead: use shift-compare approximation
                    // Store raw counters; compute exact ratio in firmware if needed
                    
                    // Approximate Q8.8 ratio using leading-zero comparison:
                    // If original is Nx larger than compressed, the bit-width difference tells us
                    if (compressed_bits == 0) begin
                        csr[CSR_PERF_COMP_RATIO] <= 32'hFFFF;
                    end else if (original_bits >= (compressed_bits << 3)) begin
                        // ratio >= 8x -> Q8.8 = 0x0800+
                        if (original_bits >= (compressed_bits << 4))
                            csr[CSR_PERF_COMP_RATIO] <= 32'h1000; // 16x
                        else if (original_bits >= (compressed_bits << 3) + (compressed_bits << 2))
                            csr[CSR_PERF_COMP_RATIO] <= 32'h0C00; // 12x
                        else if (original_bits >= (compressed_bits << 3) + (compressed_bits << 1))
                            csr[CSR_PERF_COMP_RATIO] <= 32'h0A00; // 10x
                        else
                            csr[CSR_PERF_COMP_RATIO] <= 32'h0800; // 8x
                    end else if (original_bits >= (compressed_bits << 2)) begin
                        // ratio 4-8x
                        if (original_bits >= (compressed_bits << 2) + (compressed_bits << 1))
                            csr[CSR_PERF_COMP_RATIO] <= 32'h0600; // 6x
                        else if (original_bits >= (compressed_bits << 2) + compressed_bits)
                            csr[CSR_PERF_COMP_RATIO] <= 32'h0500; // 5x
                        else
                            csr[CSR_PERF_COMP_RATIO] <= 32'h0400; // 4x
                    end else if (original_bits >= (compressed_bits << 1)) begin
                        // ratio 2-4x
                        if (original_bits >= (compressed_bits << 1) + compressed_bits)
                            csr[CSR_PERF_COMP_RATIO] <= 32'h0300; // 3x
                        else
                            csr[CSR_PERF_COMP_RATIO] <= 32'h0200; // 2x
                    end else begin
                        csr[CSR_PERF_COMP_RATIO] <= 32'h0100; // 1x
                    end

                    // Also store raw counters so firmware can compute exact ratio
                    csr[CSR_PERF_BYTES_SAVED] <= original_bits - compressed_bits;

                    // Latch all performance counters
                    csr[CSR_PERF_CYCLES] <= cycle_cnt;
                    csr[CSR_PERF_COMP_CYC] <= compress_cnt;
                    csr[CSR_PERF_DECOMP_CYC] <= decompress_cnt;
                    csr[CSR_PERF_OUTLIERS] <= outlier_cnt;
                    csr[CSR_PERF_GROUPS] <= {16'd0, group_idx + 16'd1};
                    csr[CSR_PERF_EVICTED] <= evicted_cnt;
                    csr[CSR_PERF_BYTES_SAVED] <= (original_bits - compressed_bits) >> 3; // bits to bytes
                    csr[CSR_NUM_GROUPS] <= {16'd0, num_groups_reg};

                    main_state <= MAIN_DONE;
                end

                MAIN_DONE: begin
                    csr[CSR_STATUS] <= 32'h00000002; // done
                    csr[CSR_CTRL] <= 32'd0;
                    irq_done <= 1;
                    main_state <= MAIN_IDLE;
                end

                default: main_state <= MAIN_IDLE;
            endcase
        end
    end

endmodule
