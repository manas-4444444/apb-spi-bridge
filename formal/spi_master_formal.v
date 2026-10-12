`default_nettype none
// ============================================================================
// spi_master_formal.v  --  formal property harness for spi_master (SPI modes 0-3)
//
// The solver drives start / miso / rst_n / cpol / cpha with ANY sequence of
// values and picks ANY 8-bit transmit byte. Every assert() below must hold on
// every possible trace -- not just the ones a testbench happens to generate.
//
// Only the core's ports are observed (black-box properties), so the RTL
// needs no edits to be checked.
// ============================================================================
module spi_master_formal #(
    parameter CLK_DIV = 4
)(
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire miso,
    input wire cpol,
    input wire cpha
);
    (* anyconst *) wire [7:0] f_data;     // solver chooses any byte, held constant

    wire       mosi, sck, cs_n, done, busy;
    wire [7:0] data_out;

    spi_master #(.CLK_DIV(CLK_DIV)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .data_in(f_data), .miso(miso),
        .cpol(cpol), .cpha(cpha),
        .mosi(mosi), .sck(sck), .cs_n(cs_n), .done(done), .busy(busy),
        .data_out(data_out)
    );

    // ------------------------------------------------------------------
    // Reset: asserted in the first cycle, released afterwards
    // ------------------------------------------------------------------
    reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

    always @(*) begin
        if (!f_past_valid) assume(!rst_n);
        else               assume( rst_n);
    end

    // ------------------------------------------------------------------
    // Previous-cycle copies
    // ------------------------------------------------------------------
    reg f_sck_q = 1'b0, f_cs_q = 1'b1, f_mosi_q = 1'b0, f_miso_q = 1'b0;
    reg f_cpol_q = 1'b0, f_cpha_q = 1'b0;
    always @(posedge clk) begin
        f_sck_q  <= sck;
        f_cs_q   <= cs_n;
        f_mosi_q <= mosi;
        f_miso_q <= miso;
        f_cpol_q <= cpol;
        f_cpha_q <= cpha;
    end

    // Contract (enforced by the APB wrapper): the mode only changes while idle,
    // and it is mode 0 while in reset (the wrapper's CFG register resets to 0)
    always @(*) if (f_past_valid && busy) assume(cpol == f_cpol_q && cpha == f_cpha_q);
    always @(*) if (!rst_n) assume(!cpol && !cpha);

    // ------------------------------------------------------------------
    // Edge classification. phase = 0 means "SCK at its idle level".
    // ------------------------------------------------------------------
    wire ph         = sck     ^ cpol;
    wire ph_q       = f_sck_q ^ cpol;
    wire lead_edge  =  ph & ~ph_q;          // SCK just left idle
    wire trail_edge = ~ph &  ph_q;          // SCK just returned to idle
    wire samp_edge  = cpha ? trail_edge : lead_edge;   // slave samples MOSI here
    wire shift_edge = cpha ? lead_edge  : trail_edge;  // data may change here
    wire cs_rise    = cs_n & ~f_cs_q;

    // ------------------------------------------------------------------
    // Observer: what a perfect SPI slave in this mode would have seen
    // ------------------------------------------------------------------
    reg [3:0] f_samples  = 0;   // sampling edges in the current CS window
    reg [7:0] f_mosi_cap = 0;   // MOSI bits captured at each sampling edge
    reg [7:0] f_miso_cap = 0;   // MISO bits the master should have sampled
    always @(posedge clk) begin
        if (!rst_n || cs_n) begin
            f_samples <= 0;
        end else if (samp_edge) begin
            f_samples  <= f_samples + 1'b1;
            f_mosi_cap <= {f_mosi_cap[6:0], mosi};
            // the master samples MISO on the PCLK edge where SCK makes this
            // transition, i.e. the MISO value from the previous cycle
            f_miso_cap <= {f_miso_cap[6:0], f_miso_q};
        end
    end

    // Cycles spent busy in the current transfer
    reg [7:0] f_busy_len = 0;
    always @(posedge clk)
        if (!rst_n || !busy) f_busy_len <= 0;
        else if (f_busy_len != 8'hFF) f_busy_len <= f_busy_len + 1'b1;

    // Worst case: 1 (IDLE->LOAD) + CLK_DIV/2 (wait for tick) + 16 half-periods + FINISH
    localparam integer MAX_BUSY = (CLK_DIV / 2) * 17 + 2;

    // ------------------------------------------------------------------
    // PROPERTIES
    // ------------------------------------------------------------------
    always @(*) if (f_past_valid && rst_n) begin
        // P1  SCK sits at its idle level (CPOL) whenever CS is deasserted
        //     (one cycle of slack after software changes CPOL)
        if (cs_n && cpol == f_cpol_q) assert(sck == cpol);

        // P2  never more than 8 sampling edges in one CS window
        assert(f_samples <= 4'd8);

        // P3  when CS rises, exactly 8 bits were sampled
        if (cs_rise) assert(f_samples == 4'd8);

        // P4  DONE is a single-cycle pulse, aligned with CS deassertion
        if (done) assert(cs_rise);

        // P5  MOSI is stable on the sampling edge ...
        if (!cs_n && samp_edge) assert(mosi == f_mosi_q);
        // P5b ... and inside a transfer it only ever changes on a shifting edge
        if (!cs_n && !f_cs_q && mosi != f_mosi_q) assert(shift_edge);

        // P6  TX data integrity: the 8 bits on MOSI are exactly the byte loaded
        if (done) assert(f_mosi_cap == f_data);

        // P7  RX data integrity: data_out is exactly the 8 bits presented on MISO
        if (done) assert(data_out == f_miso_cap);

        // P8  BUSY is high for the whole time CS is asserted
        if (!cs_n) assert(busy);

        // P9  bounded completion: a transfer never stays busy forever
        assert(f_busy_len <= MAX_BUSY);
    end

    // ------------------------------------------------------------------
    // COVER: show a real end-to-end transfer in every SPI mode
    // ------------------------------------------------------------------
    always @(*) if (f_past_valid && rst_n) begin
        cover(done && {cpol, cpha} == 2'd0 && f_data == 8'hB2 && data_out == 8'h3C);
        cover(done && {cpol, cpha} == 2'd1 && f_data == 8'hB2 && data_out == 8'h3C);
        cover(done && {cpol, cpha} == 2'd2 && f_data == 8'hB2 && data_out == 8'h3C);
        cover(done && {cpol, cpha} == 2'd3 && f_data == 8'hB2 && data_out == 8'h3C);
    end

endmodule
