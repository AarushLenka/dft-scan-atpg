// -----------------------------------------------------------------------------
// top.v -- 8N1 UART with small TX/RX FIFOs.
//
// DUT for the full-scan DFT + stuck-at ATPG project. Written so that scan
// insertion and DFT rule checks stay boring:
//   * exactly one clock (clk) and one asynchronous active-low reset (rst_n),
//     both top-level ports, so test mode needs no clock/reset override mux
//   * no internally generated clocks, no gated clocks, no latches, no tristate
//   * all sequential state is plain posedge-clk / negedge-rst_n flops
//
// Frame: 1 start bit (0), 8 data bits LSB first, 1 stop bit (1).
// baud_div is the number of clk cycles per bit.
// -----------------------------------------------------------------------------
`default_nettype none

// -----------------------------------------------------------------------------
// Sync FIFO with combinational read. Storage is a plain register array so it
// maps to flops (and therefore to scan flops) with any standard-cell library.
// -----------------------------------------------------------------------------
module fifo_sync #(
    parameter W  = 8,
    parameter AW = 2                // depth = 2**AW
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         wr_en,
    input  wire [W-1:0] wdata,
    input  wire         rd_en,
    output wire [W-1:0] rdata,
    output wire         full,
    output wire         empty
);

    localparam DEPTH = (1 << AW);

    reg [W-1:0] mem [0:DEPTH-1];
    reg [AW:0]  wptr;               // one extra bit distinguishes full from empty
    reg [AW:0]  rptr;

    assign full  = (wptr[AW] != rptr[AW]) && (wptr[AW-1:0] == rptr[AW-1:0]);
    assign empty = (wptr == rptr);
    assign rdata = mem[rptr[AW-1:0]];

    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;

    always @(posedge clk) begin
        if (do_wr) mem[wptr[AW-1:0]] <= wdata;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= {(AW+1){1'b0}};
            rptr <= {(AW+1){1'b0}};
        end else begin
            if (do_wr) wptr <= wptr + 1'b1;
            if (do_rd) rptr <= rptr + 1'b1;
        end
    end

endmodule

// -----------------------------------------------------------------------------
// UART top
// -----------------------------------------------------------------------------
module top (
    input  wire        clk,
    input  wire        rst_n,

    // host -> TX FIFO
    input  wire        wr_en,
    input  wire [7:0]  wr_data,
    output wire        tx_full,
    output wire        tx_empty,

    // RX FIFO -> host
    input  wire        rd_en,
    output wire [7:0]  rd_data,
    output wire        rx_empty,
    output wire        rx_full,
    output wire        rx_err,      // framing error on the last received frame

    input  wire [11:0] baud_div,    // clk cycles per bit

    output wire        tx,
    input  wire        rx,

    output wire        tx_busy
);

    // Clamp the bit period so the counters always have a reachable terminal
    // count, even if software writes 0 or 1 into baud_div.
    wire [11:0] bit_period = (baud_div < 12'd2) ? 12'd2 : baud_div;

    // -------------------------------------------------------------------------
    // TX datapath
    // -------------------------------------------------------------------------
    wire [7:0] tx_fifo_rdata;
    wire       tx_pop;

    fifo_sync #(.W(8), .AW(2)) u_tx_fifo (
        .clk   (clk),
        .rst_n (rst_n),
        .wr_en (wr_en),
        .wdata (wr_data),
        .rd_en (tx_pop),
        .rdata (tx_fifo_rdata),
        .full  (tx_full),
        .empty (tx_empty)
    );

    localparam TX_IDLE  = 2'd0,
               TX_START = 2'd1,
               TX_DATA  = 2'd2,
               TX_STOP  = 2'd3;

    reg [1:0]  tx_state;
    reg [11:0] tx_bcnt;
    reg [2:0]  tx_bitcnt;
    reg [7:0]  tx_shreg;
    reg        tx_out;

    wire tx_tick = (tx_bcnt == (bit_period - 12'd1));

    assign tx_pop  = (tx_state == TX_IDLE) && !tx_empty;
    assign tx      = tx_out;
    assign tx_busy = (tx_state != TX_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state  <= TX_IDLE;
            tx_bcnt   <= 12'd0;
            tx_bitcnt <= 3'd0;
            tx_shreg  <= 8'd0;
            tx_out    <= 1'b1;           // idle line is high
        end else begin
            if (tx_tick) tx_bcnt <= 12'd0;
            else         tx_bcnt <= tx_bcnt + 12'd1;

            case (tx_state)
                TX_IDLE: begin
                    tx_out <= 1'b1;
                    if (!tx_empty) begin
                        tx_shreg <= tx_fifo_rdata;
                        tx_state <= TX_START;
                        tx_bcnt  <= 12'd0;   // start bit gets a full period
                    end
                end

                TX_START: begin
                    tx_out <= 1'b0;
                    if (tx_tick) begin
                        tx_state  <= TX_DATA;
                        tx_bitcnt <= 3'd0;
                    end
                end

                TX_DATA: begin
                    tx_out <= tx_shreg[0];
                    if (tx_tick) begin
                        tx_shreg <= {1'b0, tx_shreg[7:1]};
                        if (tx_bitcnt == 3'd7) tx_state  <= TX_STOP;
                        else                   tx_bitcnt <= tx_bitcnt + 3'd1;
                    end
                end

                default: begin            // TX_STOP
                    tx_out <= 1'b1;
                    if (tx_tick) tx_state <= TX_IDLE;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // RX datapath
    // -------------------------------------------------------------------------
    // Two-flop synchronizer for the asynchronous serial input.
    reg rx_meta;
    reg rx_sync_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta   <= 1'b1;
            rx_sync_r <= 1'b1;
        end else begin
            rx_meta   <= rx;
            rx_sync_r <= rx_meta;
        end
    end

    localparam RX_IDLE  = 2'd0,
               RX_START = 2'd1,
               RX_DATA  = 2'd2,
               RX_STOP  = 2'd3;

    reg [1:0]  rx_state;
    reg [11:0] rx_bcnt;
    reg [2:0]  rx_bitcnt;
    reg [7:0]  rx_shreg;

    // Sample the middle of each bit: the start bit is confirmed at
    // floor(period/2) cycles, every data/stop bit at `period` cycles.
    wire [11:0] rx_half_point = {1'b0, bit_period[11:1]};
    wire        rx_half       = (rx_bcnt == (rx_half_point - 12'd1));
    wire        rx_tick       = (rx_bcnt == (bit_period - 12'd1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state  <= RX_IDLE;
            rx_bcnt   <= 12'd0;
            rx_bitcnt <= 3'd0;
            rx_shreg  <= 8'd0;
        end else begin
            if (rx_tick) rx_bcnt <= 12'd0;
            else         rx_bcnt <= rx_bcnt + 12'd1;

            case (rx_state)
                RX_IDLE: begin
                    if (!rx_sync_r) begin  // falling edge = start bit
                        rx_state <= RX_START;
                        rx_bcnt  <= 12'd0;
                    end
                end

                RX_START: begin
                    if (rx_half) begin
                        if (!rx_sync_r) begin
                            rx_state  <= RX_DATA;
                            rx_bitcnt <= 3'd0;
                            rx_bcnt   <= 12'd0;
                        end else begin
                            rx_state <= RX_IDLE;   // glitch, not a frame
                        end
                    end
                end

                RX_DATA: begin
                    if (rx_tick) begin
                        rx_shreg <= {rx_sync_r, rx_shreg[7:1]};
                        if (rx_bitcnt == 3'd7) rx_state  <= RX_STOP;
                        else                   rx_bitcnt <= rx_bitcnt + 3'd1;
                    end
                end

                default: begin          // RX_STOP
                    if (rx_tick) rx_state <= RX_IDLE;
                end
            endcase
        end
    end

    // At the RX_STOP tick rx_shreg holds the complete byte; push it only if the
    // stop bit is actually high (otherwise flag a framing error).
    wire rx_push = (rx_state == RX_STOP) && rx_tick &&  rx_sync_r;

    assign rx_err = (rx_state == RX_STOP) && rx_tick && !rx_sync_r;

    fifo_sync #(.W(8), .AW(2)) u_rx_fifo (
        .clk   (clk),
        .rst_n (rst_n),
        .wr_en (rx_push),
        .wdata (rx_shreg),
        .rd_en (rd_en),
        .rdata (rd_data),
        .full  (rx_full),
        .empty (rx_empty)
    );

endmodule

`default_nettype wire
