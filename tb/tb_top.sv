// ==========================================================================
// KV-Cache Compression Engine -- Testbench
// ==========================================================================
// Uses @(posedge clk); #1; idiom (proven in softmax project)
// ==========================================================================

`timescale 1ns / 1ps

module tb_top;

    logic clk = 0;
    logic rst_n = 0;
    /* verilator lint_off BLKSEQ */
    always #2.5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    logic [7:0]  awaddr;  logic awvalid; logic awready;
    logic [31:0] wdata;   logic [3:0] wstrb; logic wvalid; logic wready;
    logic [1:0]  bresp;   logic bvalid; logic bready;
    logic [7:0]  araddr;  logic arvalid; logic arready;
    logic [31:0] rdata;   logic [1:0] rresp; logic rvalid; logic rready;
    logic irq_done;

    // AXI4-Stream ports (tied off for self-test mode)
    logic [15:0] s_axis_data_tdata;
    logic        s_axis_data_tvalid;
    logic        s_axis_data_tready;
    logic        s_axis_data_tlast;
    logic [15:0] m_axis_data_tdata;
    logic        m_axis_data_tvalid;
    logic        m_axis_data_tready;
    logic        m_axis_data_tlast;

    kvcache_compress_top #(
        .MAX_SEQ_LEN(4096), .HEAD_DIM(128), .GROUP_SIZE(64), .MAX_OUTLIERS(4)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(wstrb),
        .s_axil_wvalid(wvalid), .s_axil_wready(wready),
        .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
        .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
        .s_axil_rdata(rdata), .s_axil_rresp(rresp),
        .s_axil_rvalid(rvalid), .s_axil_rready(rready),
        .s_axis_data_tdata(s_axis_data_tdata), .s_axis_data_tvalid(s_axis_data_tvalid),
        .s_axis_data_tready(s_axis_data_tready), .s_axis_data_tlast(s_axis_data_tlast),
        .m_axis_data_tdata(m_axis_data_tdata), .m_axis_data_tvalid(m_axis_data_tvalid),
        .m_axis_data_tready(m_axis_data_tready), .m_axis_data_tlast(m_axis_data_tlast),
        .irq_done(irq_done)
    );

    // ---- AXI Write (proven from softmax project) ----
    task automatic axi_write(input [7:0] addr, input [31:0] d);
        @(posedge clk); #1;
        awaddr = addr; awvalid = 1; wdata = d; wstrb = 4'hF; wvalid = 1; bready = 0;
        @(posedge clk); #1;
        awvalid = 0; wvalid = 0;
        @(posedge clk); #1;
        bready = 1;
        @(posedge clk); #1;
        bready = 0;
        @(posedge clk); #1;
    endtask

    // ---- AXI Read (proven from softmax project) ----
    logic [31:0] read_result;
    task automatic axi_read(input [7:0] addr);
        @(posedge clk); #1;
        araddr = addr; arvalid = 1; rready = 1;
        @(posedge clk); #1;
        arvalid = 0;
        @(posedge clk); #1;
        read_result = rdata;
        rready = 0;
        @(posedge clk); #1;
    endtask

    // ---- Check helpers ----
    integer pass_count = 0;
    integer fail_count = 0;

    task automatic check(input string name, input [31:0] got, input [31:0] expected);
        if (got == expected) begin
            $display("  [PASS] %s = 0x%08h", name, got);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] %s = 0x%08h (expected 0x%08h)", name, got, expected);
            fail_count = fail_count + 1;
        end
    endtask

    task automatic check_nonzero(input string name, input [31:0] got);
        if (got != 0) begin
            $display("  [PASS] %s = %0d", name, got);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] %s = 0 (expected non-zero)", name);
            fail_count = fail_count + 1;
        end
    endtask

    task automatic check_gte(input string name, input [31:0] got, input [31:0] minimum);
        if (got >= minimum) begin
            $display("  [PASS] %s = 0x%08h (>= 0x%08h)", name, got, minimum);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] %s = 0x%08h (expected >= 0x%08h)", name, got, minimum);
            fail_count = fail_count + 1;
        end
    endtask

    // ---- Main ----
    integer timeout;

    initial begin
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 0;
        araddr = 0; arvalid = 0; rready = 0;
        s_axis_data_tdata = 0; s_axis_data_tvalid = 0; s_axis_data_tlast = 0;
        m_axis_data_tready = 1;

        $display("");
        $display("==========================================================");
        $display("  KV-Cache Compression Engine -- RTL Testbench");
        $display("  Target: COMPRESSION_RATIO >= 8x, Line-Rate Decompress");
        $display("==========================================================");

        // Reset
        rst_n = 0;
        repeat (20) @(posedge clk);
        #1;
        rst_n = 1;
        repeat (10) @(posedge clk);
        #1;
        $display("\n[Phase 1] Reset complete");

        // ==== TEST 1: CSR Register Write/Read ====
        $display("\n[TEST 1] CSR Register Write/Read");

        axi_write(8'h08, 32'd64);     axi_read(8'h08);   // SEQ_LEN
        check("SEQ_LEN", read_result, 32'd64);

        axi_write(8'h0C, 32'd128);    axi_read(8'h0C);   // HEAD_DIM
        check("HEAD_DIM", read_result, 32'd128);

        axi_write(8'h14, 32'd2);      axi_read(8'h14);   // QUANT_BITS = INT2
        check("QUANT_BITS", read_result, 32'd2);

        axi_write(8'h18, 32'h4500);   axi_read(8'h18);   // OUTLIER_THRESH
        check("OUTLIER_THRESH", read_result, 32'h4500);

        axi_write(8'h20, 32'd64);     axi_read(8'h20);   // WINDOW_SIZE
        check("WINDOW_SIZE", read_result, 32'd64);

        // ==== TEST 2: Start Compression ====
        $display("\n[TEST 2] Start Compression (seq_len=64, head_dim=128, INT2)");
        axi_write(8'h00, 32'h00000001); // CTRL: start

        repeat (15) @(posedge clk); #1;
        axi_read(8'h04);
        check("STATUS (busy)", read_result, 32'h00000001);

        // ==== TEST 3: Wait for completion ====
        $display("\n[TEST 3] Waiting for completion...");
        timeout = 0;
        read_result = 0;
        while (read_result != 32'h00000002 && timeout < 500000) begin
            repeat (100) @(posedge clk); #1;
            axi_read(8'h04);
            timeout = timeout + 100;
        end

        if (read_result == 32'h00000002) begin
            $display("  [PASS] Completed in ~%0d cycles", timeout);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] TIMEOUT after %0d cycles (STATUS=0x%08h)", timeout, read_result);
            fail_count = fail_count + 1;
        end

        axi_read(8'h04);
        check("STATUS (done)", read_result, 32'h00000002);

        // ==== TEST 4: Performance Counters ====
        $display("\n[TEST 4] Performance Counters");

        axi_read(8'h30); $display("  PERF_CYCLES           = %0d", read_result);
        check_nonzero("PERF_CYCLES", read_result);

        axi_read(8'h34); $display("  PERF_COMPRESS_CYC     = %0d", read_result);
        check_nonzero("PERF_COMPRESS_CYC", read_result);

        axi_read(8'h38); $display("  PERF_DECOMPRESS_CYC   = %0d", read_result);
        check_nonzero("PERF_DECOMPRESS_CYC", read_result);

        axi_read(8'h3C);
        $display("  PERF_COMP_RATIO       = 0x%08h (Q8.8) = %0d.%0dx  *** THE METRIC ***",
                 read_result, read_result >> 8, ((read_result & 8'hFF) * 100) >> 8);
        check_nonzero("PERF_COMP_RATIO", read_result);

        axi_read(8'h40); $display("  PERF_OUTLIERS         = %0d", read_result);
        axi_read(8'h44); $display("  PERF_GROUPS           = %0d", read_result);
        check_nonzero("PERF_GROUPS", read_result);

        axi_read(8'h4C); $display("  PERF_BYTES_SAVED      = %0d", read_result);

        // ==== TEST 5: Re-start with INT4 ====
        $display("\n[TEST 5] Re-start with INT4 mode");
        axi_write(8'h14, 32'd4);      // QUANT_BITS = INT4
        axi_write(8'h08, 32'd32);     // SEQ_LEN = 32 (smaller)
        axi_write(8'h00, 32'h00000001); // Start

        timeout = 0;
        read_result = 0;
        while (read_result != 32'h00000002 && timeout < 500000) begin
            repeat (100) @(posedge clk); #1;
            axi_read(8'h04);
            timeout = timeout + 100;
        end

        if (read_result == 32'h00000002) begin
            $display("  [PASS] INT4 run in ~%0d cycles", timeout);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] INT4 run TIMEOUT");
            fail_count = fail_count + 1;
        end

        axi_read(8'h44); $display("  PERF_GROUPS (INT4)    = %0d", read_result);
        check_nonzero("PERF_GROUPS (INT4)", read_result);

        axi_read(8'h3C);
        $display("  PERF_COMP_RATIO (INT4) = 0x%08h", read_result);
        check_nonzero("PERF_COMP_RATIO (INT4)", read_result);

        // ==== SUMMARY ====
        $display("\n==========================================================");
        $display("  RESULTS: %0d PASS, %0d FAIL", pass_count, fail_count);
        $display("==========================================================");
        if (fail_count == 0) $display("  >>> ALL TESTS PASSED <<<");
        else                 $display("  >>> %0d TESTS FAILED <<<", fail_count);
        $display("");
        #100;
        $finish;
    end

    initial begin
        #10000000;
        $display("ERROR: Global timeout");
        $finish;
    end

    initial begin
        $dumpfile("kvcache_compress.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
