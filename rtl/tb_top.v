// -----------------------------------------------------------------------------
// tb_top.v -- self-checking loopback testbench for top.
//
// TX is wired back to RX, so anything pushed into the TX FIFO must come out of
// the RX FIFO unchanged. This is the RTL-level sanity check for the project and
// the skeleton to reuse in step 5 (gate-level simulation of Modus vectors, with
// the netlist/cell models swapped in).
//
//   make sim     # iverilog -g2012 rtl/top.v rtl/tb_top.v
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;

    localparam integer BIT_PERIOD = 16;     // clk cycles per bit

    reg         clk      = 1'b0;
    reg         rst_n    = 1'b0;
    reg         wr_en    = 1'b0;
    reg  [7:0]  wr_data  = 8'd0;
    reg         rd_en    = 1'b0;
    reg  [11:0] baud_div = BIT_PERIOD;

    wire [7:0]  rd_data;
    wire        tx_full, tx_empty, rx_empty, rx_full, rx_err, tx_busy, tx_line;

    integer errors    = 0;
    integer rx_errors = 0;
    integer i;
    reg [7:0] got;

    always #5 clk = ~clk;                   // 100 MHz

    top dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .wr_en    (wr_en),
        .wr_data  (wr_data),
        .tx_full  (tx_full),
        .tx_empty (tx_empty),
        .rd_en    (rd_en),
        .rd_data  (rd_data),
        .rx_empty (rx_empty),
        .rx_full  (rx_full),
        .rx_err   (rx_err),
        .baud_div (baud_div),
        .tx       (tx_line),
        .rx       (tx_line),                // loopback
        .tx_busy  (tx_busy)
    );

    always @(posedge clk) begin
        if (rx_err) begin
            rx_errors = rx_errors + 1;
            $display("[%0t] framing error", $time);
        end
    end

    task fail(input [1023:0] msg);
        begin
            $display("FAIL: %0s", msg);
            errors = errors + 1;
        end
    endtask

    // Push one byte into the TX FIFO.
    task push(input [7:0] d);
        begin
            @(negedge clk);
            wr_en   = 1'b1;
            wr_data = d;
            @(negedge clk);
            wr_en   = 1'b0;
            wr_data = 8'd0;
        end
    endtask

    // Wait (bounded) for a byte to show up in the RX FIFO, then pop and compare.
    task pop_wait_and_check(input [7:0] expected);
        integer n;
        begin
            n = 0;
            while (rx_empty && n < (20 * BIT_PERIOD)) begin
                @(posedge clk);
                n = n + 1;
            end

            if (rx_empty) begin
                $display("FAIL: timed out waiting for byte 0x%02h", expected);
                errors = errors + 1;
            end else begin
                @(negedge clk);
                got   = rd_data;
                rd_en = 1'b1;
                @(negedge clk);
                rd_en = 1'b0;

                if (got !== expected) begin
                    $display("FAIL: got 0x%02h, expected 0x%02h", got, expected);
                    errors = errors + 1;
                end else begin
                    $display("ok:   received 0x%02h", got);
                end
            end
        end
    endtask

    reg [7:0] pattern [0:3];

    initial begin
        pattern[0] = 8'h55;
        pattern[1] = 8'hA3;
        pattern[2] = 8'h0F;
        pattern[3] = 8'hFF;

        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        // ---- reset state -------------------------------------------------
        if (!tx_empty) fail("tx fifo not empty after reset");
        if (!rx_empty) fail("rx fifo not empty after reset");
        if (rx_full)   fail("rx fifo full after reset");
        if (tx_line !== 1'b1) fail("tx line not idle high");
        if (tx_busy !== 1'b0) fail("tx_busy set after reset");

        // ---- test 1: three bytes through the loopback --------------------
        $display("--- test 1: 3-byte loopback ---");
        for (i = 0; i < 3; i = i + 1) push(pattern[i]);
        if (tx_empty !== 1'b0) fail("tx fifo still empty after push");

        for (i = 0; i < 3; i = i + 1) pop_wait_and_check(pattern[i]);

        // ---- test 2: tx fifo full flag -----------------------------------
        // One byte into the shifter, four more fill the 4-entry FIFO.
        $display("--- test 2: tx fifo full flag ---");
        push(pattern[0]);
        for (i = 0; i < 50 && !tx_busy; i = i + 1) @(posedge clk);
        if (!tx_busy) fail("transmitter never started");

        for (i = 0; i < 4; i = i + 1) push(pattern[i]);
        if (!tx_full) fail("tx fifo should be full with 1 byte shifting + 4 queued");

        pop_wait_and_check(pattern[0]);
        for (i = 0; i < 4; i = i + 1) pop_wait_and_check(pattern[i]);

        // ---- result ------------------------------------------------------
        if (rx_errors != 0) begin
            $display("FAIL: %0d framing errors", rx_errors);
            errors = errors + rx_errors;
        end

        if (errors == 0) $display("PASS: all checks passed");
        else             $display("FAIL: %0d error(s)", errors);

        $finish;
    end

    // Watchdog so a hang is a failure instead of a stall.
    initial begin
        #(50 * 10 * BIT_PERIOD * 50);
        $display("FAIL: timeout");
        $finish;
    end

endmodule
