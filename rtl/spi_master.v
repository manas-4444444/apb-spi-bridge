`timescale 1ns / 1ps

// ----------------------------------------------------------------------------
// SPI master, 8-bit, MSB first, all four SPI modes
//
//   Mode | CPOL CPHA | SCK idle | data sampled on   | data changed on
//   -----+-----------+----------+-------------------+------------------
//    0   |  0    0   |   low    | leading (rising)  | trailing (falling)
//    1   |  0    1   |   low    | trailing (falling)| leading (rising)
//    2   |  1    0   |   high   | leading (falling) | trailing (rising)
//    3   |  1    1   |   high   | trailing (rising) | leading (falling)
//
// "Leading" = first SCK edge after CS falls, "trailing" = the second.
// cpol / cpha must be held stable while busy (the APB wrapper enforces this).
// ----------------------------------------------------------------------------
module spi_master #(
    parameter CLK_DIV = 4   // System clocks per SPI clock cycle (even, >= 2)
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] data_in,
    input  wire       miso,
    input  wire       cpol,      // NEW: SCK idle level
    input  wire       cpha,      // NEW: 0 = sample on leading edge, 1 = on trailing edge

    output reg        mosi,
    output reg        sck,
    output reg        cs_n,
    output reg        done,
    output wire       busy,      // high whenever a transfer is in progress

    output reg [7:0]  data_out
);

    // ============================================================
    // FSM STATES
    // ============================================================
    localparam IDLE     = 2'b00;
    localparam LOAD     = 2'b01;
    localparam TRANSFER = 2'b10;
    localparam FINISH   = 2'b11;

    reg [1:0] state;

    assign busy = (state != IDLE);

    // ============================================================
    // 2x CLOCK ENABLE GENERATOR
    // Generates a tick at exactly twice the SPI frequency
    // ============================================================
    // counter only has to reach CLK_DIV/2 - 1, so size it for that (>= 1 bit)
    localparam CW = (CLK_DIV > 2) ? $clog2(CLK_DIV / 2) : 1;
    localparam integer HALF_M1 = (CLK_DIV / 2) - 1;          // last count value

    reg [CW-1:0] clk_count;
    reg spi_en;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_count <= 0;
            spi_en    <= 0;
        end
        else begin
            // Toggle at half the SPI clock period
            if (clk_count == HALF_M1[CW-1:0]) begin             // sized compare (lint-clean)
                clk_count <= 0;
                spi_en    <= 1;
            end
            else begin
                clk_count <= clk_count + 1'b1;
                spi_en    <= 0;
            end
        end
    end

    // ============================================================
    // SHIFT REGISTERS & COUNTERS
    // ============================================================
    reg [7:0] tx_shift_reg;
    reg [7:0] rx_shift_reg;
    reg [2:0] bit_count;

    // The next SCK toggle is a LEADING edge when SCK is still at its idle level
    wire leading = (sck == cpol);
    // Edge on which this mode samples MISO (the other edge shifts MOSI)
    wire sample_edge = leading ^ cpha;        // CPHA=0: leading, CPHA=1: trailing

    // ============================================================
    // MAIN FSM
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            sck          <= 0;
            cs_n         <= 1;
            done         <= 0;
            mosi         <= 0;
            tx_shift_reg <= 0;
            rx_shift_reg <= 0;
            data_out     <= 0;
            bit_count    <= 0;
        end
        else begin
            done <= 0; // Default to 0 unless in FINISH state

            case(state)

                // ====================================================
                // IDLE
                // Wait for the host to assert 'start'; SCK sits at CPOL
                // ====================================================
                IDLE: begin
                    sck  <= cpol;
                    cs_n <= 1;

                    if (start) begin
                        state <= LOAD;
                    end
                end

                // ====================================================
                // LOAD DATA & SETUP TIME
                // Pull CS low, put first bit on MOSI, wait for spi_en
                // (for CPHA=0 the slave samples on the first edge, so the
                //  MSB must already be on MOSI before SCK moves)
                // ====================================================
                LOAD: begin
                    cs_n         <= 0;
                    tx_shift_reg <= data_in;
                    rx_shift_reg <= 8'd0;
                    bit_count    <= 3'd7;
                    mosi         <= data_in[7]; // Drive MSB immediately

                    if (spi_en) begin
                        state <= TRANSFER;
                    end
                end

                // ====================================================
                // TRANSFER
                // Fully synchronous shifting and sampling
                // ====================================================
                TRANSFER: begin
                    if (spi_en) begin
                        sck <= ~sck; // Toggle SPI clock

                        if (sample_edge) begin
                            // ----------------------------------------
                            // SAMPLE EDGE: capture MISO
                            // ----------------------------------------
                            rx_shift_reg <= {rx_shift_reg[6:0], miso};
                        end
                        else if (!cpha) begin
                            // ----------------------------------------
                            // CPHA=0 SHIFT (trailing) EDGE: next bit out
                            // ----------------------------------------
                            tx_shift_reg <= {tx_shift_reg[6:0], 1'b0};
                            mosi         <= tx_shift_reg[6];
                        end
                        else begin
                            // ----------------------------------------
                            // CPHA=1 SHIFT (leading) EDGE: current bit out
                            // ----------------------------------------
                            tx_shift_reg <= {tx_shift_reg[6:0], 1'b0};
                            mosi         <= tx_shift_reg[7];
                        end

                        // every trailing edge completes one bit
                        if (!leading) begin
                            if (bit_count == 0) begin
                                state <= FINISH;
                            end
                            else begin
                                bit_count <= bit_count - 1'b1;
                            end
                        end
                    end
                end

                // ====================================================
                // FINISH
                // Tear down transaction and output data
                // ====================================================
                FINISH: begin
                    cs_n     <= 1;
                    sck      <= cpol;
                    data_out <= rx_shift_reg;
                    done     <= 1;
                    state    <= IDLE;
                end

            endcase
        end
    end

endmodule
