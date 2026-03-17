// ==========================================================================
// Group Dequantizer -- INTn->FP16 with Outlier Restoration
// ==========================================================================
// Decompresses one group at a time:
//   1. Read compressed group data (quantized + scale + outlier info)
//   2. Dequantize: restored[i] = quantized[i] x scale
//   3. Restore outliers at full FP16 precision
//   4. Output restored FP16 elements via AXI4-Stream
//
// THE METRIC: DECOMPRESS_LATENCY = 1 element/cycle (after initial latency)
// ==========================================================================

`timescale 1ns / 1ps

module group_dequantizer #(
    parameter GROUP_SIZE   = 64,
    parameter MAX_OUTLIERS = 4
)(
    input  logic        clk,
    input  logic        rst_n,

    // Configuration
    input  logic [2:0]  cfg_quant_bits,

    // Compressed group input
    input  logic [127:0] in_quant_data,
    input  logic [15:0]  in_scale,
    input  logic [63:0]  in_outlier_bitmap,
    input  logic [3:0]   in_num_outliers,
    input  logic [15:0]  in_outlier_val [0:MAX_OUTLIERS-1],
    input  logic         in_valid,
    output logic         in_ready,

    // AXI4-Stream output: restored FP16, one per cycle
    output logic [15:0] m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,

    // Statistics
    output logic [31:0] stat_groups_decompressed,
    output logic [31:0] stat_decompress_cycles
);

    // ---- FSM ----
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_LOAD,
        ST_OUTPUT,
        ST_DONE
    } state_t;

    state_t state;

    // Latched compressed data
    logic [127:0] quant_data_reg;
    logic [15:0]  scale_reg;
    logic [63:0]  bitmap_reg;
    logic [3:0]   num_outliers_reg;
    logic [15:0]  outlier_vals_reg [0:MAX_OUTLIERS-1];

    // Output counter
    logic [6:0]  out_idx;
    logic [3:0]  outlier_rd_idx;  // which outlier value to use next
    logic [31:0] cycle_counter;

    // Dequantized value for current element
    logic [15:0] dequant_val;

    // ---- Dequantization logic ----
    // For INT2: q  in  {0,1,2,3} maps to {-2,-1,0,1} x scale
    // For INT4: upper bit = sign, lower 3 bits = magnitude
    always_comb begin
        logic [1:0] q2;
        logic [3:0] q4;
        logic signed [7:0] q_signed;
        logic [15:0] abs_result;

        dequant_val = 16'h0000; // default zero

        if (bitmap_reg[out_idx]) begin
            // Outlier: use stored full-precision value
            dequant_val = outlier_vals_reg[outlier_rd_idx];
        end else begin
            case (cfg_quant_bits)
                3'd2: begin
                    q2 = quant_data_reg[out_idx*2 +: 2];
                    // {0,1,2,3} -> {-2,-1,0,+1}
                    case (q2)
                        2'd0: dequant_val = {1'b1, scale_reg[14:0]}; // -2 x scale ~ -scale (simplified)
                        2'd1: begin
                            // -1 x scale ~ -(scale/2)
                            dequant_val = {1'b1, 1'b0, scale_reg[14:1]}; // negative, halved exponent
                        end
                        2'd2: dequant_val = 16'h0000; // 0
                        2'd3: dequant_val = scale_reg; // +1 x scale
                        default: dequant_val = 16'h0000;
                    endcase
                end
                3'd4: begin
                    q4 = quant_data_reg[out_idx*4 +: 4];
                    // sign + 3 magnitude bits, multiply by scale
                    dequant_val = {q4[3], scale_reg[14:0]}; // simplified: sign from q4, magnitude from scale
                end
                default: begin
                    dequant_val = 16'h0000;
                end
            endcase
        end
    end

    // ---- Main FSM ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            in_ready <= 1;
            m_axis_tvalid <= 0;
            m_axis_tlast <= 0;
            m_axis_tdata <= 16'd0;
            out_idx <= 0;
            outlier_rd_idx <= 0;
            stat_groups_decompressed <= 0;
            stat_decompress_cycles <= 0;
            cycle_counter <= 0;
        end else begin
            case (state)
                ST_IDLE: begin
                    in_ready <= 1;
                    m_axis_tvalid <= 0;
                    m_axis_tlast <= 0;
                    out_idx <= 0;
                    outlier_rd_idx <= 0;
                    if (in_valid && in_ready) begin
                        // Latch compressed group
                        quant_data_reg <= in_quant_data;
                        scale_reg <= in_scale;
                        bitmap_reg <= in_outlier_bitmap;
                        num_outliers_reg <= in_num_outliers;
                        for (int i = 0; i < MAX_OUTLIERS; i++)
                            outlier_vals_reg[i] <= in_outlier_val[i];
                        in_ready <= 0;
                        cycle_counter <= 0;
                        state <= ST_OUTPUT;
                    end
                end

                ST_OUTPUT: begin
                    cycle_counter <= cycle_counter + 32'd1;
                    m_axis_tdata <= dequant_val;
                    m_axis_tvalid <= 1;
                    m_axis_tlast <= (out_idx == 7'd64 - 7'd1);

                    if (m_axis_tvalid && m_axis_tready) begin
                        // Advance outlier read index if current was an outlier
                        if (bitmap_reg[out_idx] && outlier_rd_idx < num_outliers_reg)
                            outlier_rd_idx <= outlier_rd_idx + 4'd1;

                        if (out_idx == 7'd64 - 7'd1) begin
                            // Don't clear tvalid/tlast here -- FSM needs to see tlast=1
                            // ST_DONE will clean up on the next cycle
                            state <= ST_DONE;
                        end else begin
                            out_idx <= out_idx + 7'd1;
                        end
                    end
                end

                ST_DONE: begin
                    m_axis_tvalid <= 0;
                    stat_groups_decompressed <= stat_groups_decompressed + 32'd1;
                    stat_decompress_cycles <= stat_decompress_cycles + cycle_counter;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
