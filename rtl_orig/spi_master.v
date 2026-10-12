`timescale 1ns / 1ps

module spi_master #(
    parameter CLK_DIV = 4   // System clocks per SPI clock cycle
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] data_in,
    input  wire       miso,

    output reg        mosi,
    output reg        sck,
    output reg        cs_n,
    output reg        done,

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

    // ============================================================
    // 2x CLOCK ENABLE GENERATOR
    // Generates a tick at exactly twice the SPI frequency
    // ============================================================
    reg [$clog2(CLK_DIV)-1:0] clk_count;
    reg spi_en;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_count <= 0;
            spi_en    <= 0;
        end
        else begin
            // Toggle at half the SPI clock period
            if (clk_count == (CLK_DIV/2) - 1) begin
                clk_count <= 0;
                spi_en    <= 1;
            end
            else begin
                clk_count <= clk_count + 1;
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
                // Wait for the host to assert 'start'
                // ====================================================
                IDLE: begin
                    sck  <= 0;
                    cs_n <= 1;

                    if (start) begin
                        state <= LOAD;
                    end
                end

                // ====================================================
                // LOAD DATA & SETUP TIME
                // Pull CS low, put first bit on MOSI, wait for spi_en
                // ====================================================
                LOAD: begin
                    cs_n         <= 0;
                    tx_shift_reg <= data_in;
                    rx_shift_reg <= 8'd0;
                    bit_count    <= 3'd7;
                    mosi         <= data_in[7]; // Drive MSB immediately

                    // Wait for the next SPI enable tick before toggling clock
                    // This creates the critical cs_n to first sck setup time
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

                        // --------------------------------------------
                        // RISING EDGE: Sample MISO
                        // sck evaluates to 0 (before the non-blocking toggle)
                        // --------------------------------------------
                        if (sck == 1'b0) begin
                            rx_shift_reg <= {rx_shift_reg[6:0], miso};
                        end

                        // --------------------------------------------
                        // FALLING EDGE: Drive MOSI
                        // sck evaluates to 1
                        // --------------------------------------------
                        else begin
                            tx_shift_reg <= {tx_shift_reg[6:0], 1'b0};
                            mosi         <= tx_shift_reg[6];

                            if (bit_count == 0) begin
                                state <= FINISH;
                            end
                            else begin
                                bit_count <= bit_count - 1;
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
                    sck      <= 0;
                    data_out <= rx_shift_reg;
                    done     <= 1;
                    state    <= IDLE;
                end

            endcase
        end
    end

endmodule
