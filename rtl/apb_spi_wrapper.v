`timescale 1ns / 1ps

// ----------------------------------------------------------------------------
// Register map (32-bit APB, zero wait states)
//   0x00 TX_REG   [7:0]  R/W  byte to send (writes ignored while BUSY)
//   0x04 RX_REG   [7:0]  R    last byte received
//   0x08 CTRL     [0]    W    write 1 to START (ignored while BUSY)
//                 [1]    R    DONE  - set when a transfer completes,
//                               cleared by the CTRL read that returned it as 1
//                 [2]    R    BUSY  - transfer in progress
//   0x0C CFG      [0]    R/W  CPOL  - SCK idle level        (writes ignored while BUSY)
//                 [1]    R/W  CPHA  - 0: sample on leading edge, 1: on trailing edge
//                               {CPOL,CPHA} = SPI mode 0..3
// ----------------------------------------------------------------------------
module apb_spi_wrapper #(
    parameter CLK_DIV = 4          // NEW: SPI divider is now set from the top level
)(
    // ============================================================
    // APB BUS INTERFACE
    // ============================================================
    input  wire        PCLK,      // System clock
    input  wire        PRESETn,   // Active-low reset
    /* verilator lint_off UNUSEDSIGNAL */   // only PADDR[7:0] / PWDATA[7:0] are decoded
    input  wire [31:0] PADDR,     // Address bus
    input  wire        PSEL,      // Peripheral select
    input  wire        PENABLE,   // Enable phase
    input  wire        PWRITE,    // Write (1) / Read (0)
    input  wire [31:0] PWDATA,    // Write data
    /* verilator lint_on UNUSEDSIGNAL */
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
    reg  [1:0] cfg_reg;            // NEW: {CPHA, CPOL}
    wire       done_wire;
    wire       core_busy;

    // BUSY from the moment START is accepted until the core returns to IDLE
    wire       busy = start_reg | core_busy;                       // NEW

    // Decoded APB access strobes (end of access phase)
    wire wr_access   = PSEL & PENABLE &  PWRITE;
    wire rd_ctrl_end = PSEL & PENABLE & ~PWRITE & (PADDR[7:0] == 8'h08);

    // APB is always ready in this simple zero-wait-state implementation
    assign PREADY = 1'b1;

    // ============================================================
    // INSTANTIATE THE SPI MASTER CORE
    // ============================================================
    spi_master #(
        .CLK_DIV(CLK_DIV)                                          // NEW: passed through
    ) spi_core (
        .clk      (PCLK),
        .rst_n    (PRESETn),
        .start    (start_reg),
        .data_in  (tx_reg),
        .miso     (miso),
        .cpol     (cfg_reg[0]),                                    // NEW
        .cpha     (cfg_reg[1]),                                    // NEW

        .mosi     (mosi),
        .sck      (sck),
        .cs_n     (cs_n),
        .done     (done_wire),
        .busy     (core_busy),                                     // NEW
        .data_out (rx_wire)
    );

    // ============================================================
    // APB WRITE LOGIC
    // ============================================================
    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            tx_reg    <= 8'd0;
            start_reg <= 1'b0;
            cfg_reg   <= 2'b00;                                    // reset to SPI mode 0
        end
        else begin
            // Clear start register automatically after one clock cycle
            // to create the single-cycle pulse the SPI core expects
            if (start_reg) begin
                start_reg <= 1'b0;
            end

            // APB Write Phase: PSEL and PENABLE must be HIGH
            // NEW: TX and START are protected while a transfer is in flight
            if (wr_access && !busy) begin
                case (PADDR[7:0])
                    8'h00: tx_reg    <= PWDATA[7:0]; // Write to TX_REG
                    8'h08: start_reg <= PWDATA[0];   // Write 1 to CTRL_REG to start
                    8'h0C: cfg_reg   <= PWDATA[1:0]; // NEW: SPI mode
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
            // FIX 1: clear-on-read clears DONE only if the value the CPU is
            // reading in this access phase actually showed DONE = 1.
            // (PRDATA was loaded at the end of the setup phase.)
            if (rd_ctrl_end && PRDATA[1]) begin
                done_latch <= 1'b0;
            end

            // FIX 2: SET has priority over CLEAR. This statement comes last, so
            // a completion that lands on the same edge as the clearing read
            // is never lost.
            if (done_wire) begin
                rx_reg     <= rx_wire;
                done_latch <= 1'b1;
            end

            // APB Read Phase: Output data based on address
            if (PSEL && !PWRITE) begin
                case (PADDR[7:0])
                    8'h00: PRDATA <= {24'd0, tx_reg};                   // Read TX_REG
                    8'h04: PRDATA <= {24'd0, rx_reg};                   // Read RX_REG
                    8'h08: PRDATA <= {29'd0, busy, done_latch, 1'b0};   // CTRL: [2]=BUSY [1]=DONE
                    8'h0C: PRDATA <= {30'd0, cfg_reg};                  // CFG:  [1]=CPHA [0]=CPOL
                    default: PRDATA <= 32'd0;
                endcase
            end
            else begin
                PRDATA <= 32'd0; // Drive zero when not reading
            end
        end
    end

endmodule
