`default_nettype none
// ============================================================================
// apb_spi_formal.v  --  formal harness for the full APB-to-SPI bridge
//
// A legal APB master is built here from free (solver-controlled) inputs, so
// the solver can try ANY sequence of reads/writes to ANY register, with any
// spacing, back-to-back or idle -- plus any MISO data.
//
// Key property (what firmware relies on):
//   once a transfer has completed, the next status read that is late enough
//   to see it MUST return DONE = 1, and DONE must never appear without a
//   completion. In other words: every completion is reported exactly once.
// ============================================================================
module apb_spi_formal #(
    parameter CLK_DIV = 2
)(
    input wire        PCLK,
    input wire        PRESETn,
    input wire        f_go,        // master wants to start an APB transfer
    input wire        f_wr,        // 1 = write, 0 = read
    input wire [2:0]  f_reg,       // 0:TX 1:RX 2:CTRL 3:CFG 4-7:unmapped
    input wire [31:0] f_wdata,
    input wire        miso
);
    // ------------------------------------------------------------------
    // Legal APB master: IDLE -> SETUP -> ACCESS -> (IDLE | SETUP)
    // ------------------------------------------------------------------
    localparam M_IDLE = 2'd0, M_SETUP = 2'd1, M_ACCESS = 2'd2;
    reg [1:0]  m_state = M_IDLE;
    reg [31:0] PADDR   = 0;
    reg        PWRITE  = 0;
    reg [31:0] PWDATA  = 0;

    wire PSEL    = (m_state == M_SETUP) || (m_state == M_ACCESS);
    wire PENABLE = (m_state == M_ACCESS);

    wire [31:0] PRDATA;
    wire        PREADY;
    wire        mosi, sck, cs_n;

    always @(posedge PCLK) begin
        if (!PRESETn) begin
            m_state <= M_IDLE;
        end else begin
            case (m_state)
                M_IDLE, M_ACCESS:                 // ACCESS always ends (PREADY = 1)
                    if (f_go) begin
                        m_state <= M_SETUP;
                        PADDR   <= {27'd0, f_reg, 2'b00};
                        PWRITE  <= f_wr;
                        PWDATA  <= f_wdata;
                    end else
                        m_state <= M_IDLE;
                M_SETUP:  m_state <= M_ACCESS;    // address/data held stable
                default:  m_state <= M_IDLE;
            endcase
        end
    end

`ifdef ORIG_RTL
    apb_spi_wrapper dut (
`else
    apb_spi_wrapper #(.CLK_DIV(CLK_DIV)) dut (
`endif
        .PCLK(PCLK), .PRESETn(PRESETn), .PADDR(PADDR), .PSEL(PSEL),
        .PENABLE(PENABLE), .PWRITE(PWRITE), .PWDATA(PWDATA),
        .PRDATA(PRDATA), .PREADY(PREADY),
        .mosi(mosi), .sck(sck), .cs_n(cs_n), .miso(miso)
    );

    // ------------------------------------------------------------------
    // Reset in the first cycle only
    // ------------------------------------------------------------------
    reg f_past_valid = 1'b0;
    always @(posedge PCLK) f_past_valid <= 1'b1;
    always @(*) begin
        if (!f_past_valid) assume(!PRESETn);
        else               assume( PRESETn);
    end

    // ------------------------------------------------------------------
    // Scoreboard for "every completion reported exactly once"
    // ------------------------------------------------------------------
    reg f_cs_q = 1'b1;
    always @(posedge PCLK) f_cs_q <= cs_n;
    wire completion = cs_n & ~f_cs_q;                 // CS rising = transfer finished

    // The master samples PRDATA at the end of an ACCESS phase
    wire ctrl_read_sample = (m_state == M_ACCESS) && !PWRITE && (PADDR[7:0] == 8'h08);

    reg       f_pending = 1'b0;   // a completion has not yet been reported to the CPU
    reg [3:0] f_age     = 0;      // cycles since that completion (saturating)
    always @(posedge PCLK) begin
        if (!PRESETn) begin
            f_pending <= 1'b0;
            f_age     <= 0;
        end else if (completion) begin
            f_pending <= 1'b1;
            f_age     <= 0;
        end else begin
            if (ctrl_read_sample && PRDATA[1]) f_pending <= 1'b0;
            if (f_age != 4'hF) f_age <= f_age + 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // PROPERTIES
    // ------------------------------------------------------------------
    always @(*) if (f_past_valid && PRESETn) begin
        // W1  zero-wait-state slave
        assert(PREADY);

        // W2  a status read that starts after the completion has propagated
        //     (completion -> DONE latch -> PRDATA register)
        //     must report DONE. The original design fails this.
        if (ctrl_read_sample && f_pending && f_age >= 1) assert(PRDATA[1]);

        // W3  no spurious DONE: DONE is only reported for a real completion
        if (ctrl_read_sample && PRDATA[1]) assert(f_pending);

    end

    // COVER: a full CPU-level transaction -- start, complete, DONE read back
    always @(*) if (f_past_valid && PRESETn)
        cover(ctrl_read_sample && PRDATA[1]);

endmodule
