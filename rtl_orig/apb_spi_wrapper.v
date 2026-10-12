`timescale 1ns / 1ps

module apb_spi_wrapper (
    // ============================================================
    // APB BUS INTERFACE
    // ============================================================
    input  wire        PCLK,      // System clock
    input  wire        PRESETn,   // Active-low reset
    input  wire [31:0] PADDR,     // Address bus
    input  wire        PSEL,      // Peripheral select
    input  wire        PENABLE,   // Enable phase
    input  wire        PWRITE,    // Write (1) / Read (0)
    input  wire [31:0] PWDATA,    // Write data
    output reg  [31:0] PRDATA,    // Read data
    output wire        PREADY,    // Ready signal (always 1 for simple APB)

    // ============================================================
    // SPI PHYSICAL PINS
    // ============================================================
    output wire        mosi,
    output wire        sck,
    output wire        cs_n,
    input  wire        miso
);

    // ============================================================
    // INTERNAL REGISTERS & WIRES
    // ============================================================
    reg  [7:0] tx_reg;
    wire [7:0] rx_wire;
    reg  [7:0] rx_reg;
    reg        start_reg;
    wire       done_wire;

    // APB is always ready in this simple zero-wait-state implementation
    assign PREADY = 1'b1;

    // ============================================================
    // INSTANTIATE THE SPI MASTER CORE
    // ============================================================
    spi_master #(
        .CLK_DIV(4)
    ) spi_core (
        .clk      (PCLK),
        .rst_n    (PRESETn),
        .start    (start_reg),
        .data_in  (tx_reg),
        .miso     (miso),

        .mosi     (mosi),
        .sck      (sck),
        .cs_n     (cs_n),
        .done     (done_wire),
        .data_out (rx_wire)
    );

    // ============================================================
    // APB WRITE LOGIC
    // ============================================================
    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            tx_reg    <= 8'd0;
            start_reg <= 1'b0;
        end
        else begin
            // Clear start register automatically after one clock cycle
            // to create the single-cycle pulse the SPI core expects
            if (start_reg) begin
                start_reg <= 1'b0;
            end

            // APB Write Phase: PSEL and PENABLE must be HIGH
            if (PSEL && PENABLE && PWRITE) begin
                case (PADDR[7:0])
                    8'h00: tx_reg    <= PWDATA[7:0]; // Write to TX_REG
                    8'h08: start_reg <= PWDATA[0];   // Write 1 to CTRL_REG to start
                    default: ; // Ignore other addresses
                endcase
            end
        end
    end

    // ============================================================
    // APB READ LOGIC & STATUS LATCHING
    // ============================================================
    reg done_latch;

    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            PRDATA     <= 32'd0;
            rx_reg     <= 8'd0;
            done_latch <= 1'b0;
        end
        else begin
            // Latch the data and done signal when the SPI core finishes
            if (done_wire) begin
                rx_reg     <= rx_wire;
                done_latch <= 1'b1;
            end

            // Clear the done latch if the CPU reads the CTRL_REG
            // (Clear-on-read behavior)
            if (PSEL && PENABLE && !PWRITE && PADDR[7:0] == 8'h08) begin
                done_latch <= 1'b0;
            end

            // APB Read Phase: Output data based on address
            if (PSEL && !PWRITE) begin
                case (PADDR[7:0])
                    8'h00: PRDATA <= {24'd0, tx_reg};             // Read TX_REG
                    8'h04: PRDATA <= {24'd0, rx_reg};             // Read RX_REG
                    8'h08: PRDATA <= {30'd0, done_latch, 1'b0};   // Read CTRL_REG (Bit 1 is Done)
                    default: PRDATA <= 32'd0;
                endcase
            end
            else begin
                PRDATA <= 32'd0; // Drive zero when not reading
            end
        end
    end

endmodule
