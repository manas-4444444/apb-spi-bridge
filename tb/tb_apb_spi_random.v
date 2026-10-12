`timescale 1ns / 1ps
// ============================================================================
// tb_apb_spi_random.v  --  Self-checking, constrained-random testbench
//
//   * APB BFM that samples PRDATA exactly where the APB spec says
//     (on the rising edge that ends the access phase)
//   * Event-driven SPI slave model supporting all four SPI modes
//   * Scoreboard: checks every byte in BOTH directions
//   * Protocol monitor: SCK idle level = CPOL, MOSI stable on the sampling
//     edge, exactly 8 sampling edges per CS window, exact SCK half-period
//   * Directed tests: register readback, unmapped addresses, corner bytes in
//     every mode, BUSY behaviour, CFG write while busy, reset mid-transfer
//   * Random tests: random data, random SPI mode, random gaps and poll spacing
//
// Compile-time knobs (pass with -D):
//   CLK_DIV=<even number >= 2>   SPI clock divider            (default 4)
//   NUM_TX=<n>                   number of random transfers   (default 500)
//   ORIG_RTL                     original wrapper (no CLK_DIV parameter, no BUSY bit)
//   HAS_BUSY                     wrapper exposes BUSY in CTRL[2]
//   HAS_MODES                    wrapper has the CFG register (SPI modes 0-3)
//   GATE_LEVEL                   DUT is a synthesized netlist (no parameters)
//   LEGACY_BFM                   sample PRDATA 1 ns after the edge (original TB timing)
//   DUMP                         write a VCD for GTKWave
// Run-time knob:
//   +seed=<n>                    random seed (default 1)
// ============================================================================

`ifndef CLK_DIV
  `define CLK_DIV 4
`endif
`ifndef NUM_TX
  `define NUM_TX 500
`endif

module tb_apb_spi_random;

    // ------------------------------------------------------------------
    // Register map
    // ------------------------------------------------------------------
    localparam [31:0] ADDR_TX   = 32'h00;
    localparam [31:0] ADDR_RX   = 32'h04;
    localparam [31:0] ADDR_CTRL = 32'h08;
    localparam [31:0] ADDR_CFG  = 32'h0C;
    localparam [31:0] ADDR_NONE = 32'h10;   // unmapped
    localparam        DONE_BIT  = 1;
    localparam        BUSY_BIT  = 2;
    localparam integer HALF     = `CLK_DIV / 2;        // PCLKs per SCK half-period
    localparam integer TIMEOUT  = 40 * `CLK_DIV + 200; // PCLKs before declaring a hang

    // ------------------------------------------------------------------
    // DUT signals
    // ------------------------------------------------------------------
    reg         PCLK = 0;
    reg         PRESETn;
    reg  [31:0] PADDR;
    reg         PSEL;
    reg         PENABLE;
    reg         PWRITE;
    reg  [31:0] PWDATA;
    wire [31:0] PRDATA;
    wire        PREADY;
    wire        mosi, sck, cs_n;
    reg         miso;

    // Inputs start unknown and get their reset values 1 ns later. That
    // x -> value change is an event every model sees, which matters for
    // gate-level netlists whose I/O-cell models only update on input changes.
    initial begin
        #1;
        PRESETn = 0; PADDR = 0; PSEL = 0; PENABLE = 0; PWRITE = 0; PWDATA = 0; miso = 0;
    end

`ifdef ORIG_RTL
    apb_spi_wrapper uut (
`elsif GATE_LEVEL
    apb_spi_wrapper uut (
`else
    apb_spi_wrapper #(.CLK_DIV(`CLK_DIV)) uut (
`endif
        .PCLK(PCLK), .PRESETn(PRESETn), .PADDR(PADDR), .PSEL(PSEL),
        .PENABLE(PENABLE), .PWRITE(PWRITE), .PWDATA(PWDATA),
        .PRDATA(PRDATA), .PREADY(PREADY),
        .mosi(mosi), .sck(sck), .cs_n(cs_n), .miso(miso)
    );

    always #5 PCLK = ~PCLK;   // 100 MHz

    // ------------------------------------------------------------------
    // Error accounting
    // ------------------------------------------------------------------
    integer errors      = 0;
    integer n_transfers = 0;
    integer n_polls     = 0;
    integer n_mode [0:3];
    initial begin n_mode[0] = 0; n_mode[1] = 0; n_mode[2] = 0; n_mode[3] = 0; end

    task fail(input [8*80-1:0] msg);
        begin
            errors = errors + 1;
            $display("[%0t] ERROR: %0s", $time, msg);
        end
    endtask

    // ------------------------------------------------------------------
    // APB bus-functional model
    //   Inputs are driven 1 ns after a clock edge (no races with the DUT).
    //   PRDATA is sampled AT the rising edge that ends the access phase,
    //   i.e. the value the slave presented during the access phase.
    // ------------------------------------------------------------------
    task apb_write(input [31:0] addr, input [31:0] data);
        begin
            @(posedge PCLK); #1;
            PADDR = addr; PWDATA = data; PWRITE = 1; PSEL = 1; PENABLE = 0;  // setup
            @(posedge PCLK); #1;
            PENABLE = 1;                                                    // access
            @(posedge PCLK);                                                // transfer happens here
            if (PREADY !== 1'b1) fail("PREADY low during write access");
            #1; PSEL = 0; PENABLE = 0; PWRITE = 0;
        end
    endtask

    task apb_read(input [31:0] addr, output [31:0] data);
        begin
            @(posedge PCLK); #1;
            PADDR = addr; PWRITE = 0; PSEL = 1; PENABLE = 0;                // setup
            @(posedge PCLK); #1;
            PENABLE = 1;                                                    // access
            @(posedge PCLK);                                                // sample here
`ifdef LEGACY_BFM
            #1;   // original testbench timing: sample 1 ns AFTER the edge
`endif
            data = PRDATA;
            if (PREADY !== 1'b1) fail("PREADY low during read access");
`ifndef LEGACY_BFM
            #1;
`endif
            PSEL = 0; PENABLE = 0;
        end
    endtask

    task idle(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) @(posedge PCLK);
        end
    endtask

    // ------------------------------------------------------------------
    // Current SPI mode, as the testbench has configured it
    // ------------------------------------------------------------------
    reg     s_cpol = 0, s_cpha = 0;
    integer mode_settle = 0;   // PCLKs to wait before checking the new idle level

    // ------------------------------------------------------------------
    // SPI slave model (event driven, independent of PCLK)
    //   CS falls         -> CPHA=0: put MSB of reply on MISO
    //   sampling edge    -> capture MOSI
    //   shifting edge    -> CPHA=0: next reply bit, CPHA=1: current reply bit
    //   CS rises         -> hand the received byte to the scoreboard
    // "Leading" edge = SCK moving away from its idle level (CPOL).
    // ------------------------------------------------------------------
    reg  [7:0] slave_reply;      // byte the slave sends (set before each transfer)
    reg  [7:0] slave_shift;
    reg  [7:0] slave_rx;
    integer    sample_count;
    reg  [7:0] slave_rx_last;    // last byte the slave received
    integer    slave_rx_count = 0;
    reg        lead;

    always @(negedge cs_n) begin
        slave_shift  = slave_reply;
        slave_rx     = 8'h00;
        sample_count = 0;
        if (!s_cpha) miso = slave_shift[7];
    end

    always @(posedge sck or negedge sck) if (!cs_n) begin
        lead = (sck !== s_cpol);                 // SCK just left its idle level
        if (lead ^ s_cpha) begin                 // sampling edge
            slave_rx     = {slave_rx[6:0], mosi};
            sample_count = sample_count + 1;
        end else if (s_cpha) begin               // CPHA=1: drive current bit
            miso        = slave_shift[7];
            slave_shift = {slave_shift[6:0], 1'b0};
        end else begin                           // CPHA=0: drive next bit
            slave_shift = {slave_shift[6:0], 1'b0};
            miso        = slave_shift[7];
        end
    end

    always @(posedge cs_n) if (PRESETn) begin
        if (sample_count != 8) begin
            errors = errors + 1;
            $display("[%0t] ERROR: CS window had %0d sampling edges (expected 8)", $time, sample_count);
        end
        slave_rx_last  = slave_rx;
        slave_rx_count = slave_rx_count + 1;
    end

    // ------------------------------------------------------------------
    // Protocol monitor (sampled on PCLK; all DUT outputs are registered)
    // ------------------------------------------------------------------
    reg     sck_q = 0, mosi_q = 0, cs_n_q = 1;
    integer half_len = 0;        // PCLKs since last SCK toggle
    reg     in_window = 0;       // seen at least one SCK toggle in this CS window
    reg     ph, ph_q, samp_edge;

    always @(posedge PCLK) begin
        if (PRESETn) begin
            // SCK must sit at its idle level (CPOL) whenever CS is high
            if (mode_settle > 0) mode_settle = mode_settle - 1;
            else if (cs_n && (sck !== s_cpol)) fail("SCK not at CPOL idle level while CS deasserted");

            // MOSI must be stable on the edge where the slave samples it
            ph   = sck   ^ s_cpol;                      // 0 = idle phase
            ph_q = sck_q ^ s_cpol;
            samp_edge = s_cpha ? (!ph && ph_q) : (ph && !ph_q);
            if (!cs_n && samp_edge && (mosi !== mosi_q)) fail("MOSI changed on the sampling edge");

            // SCK half-period must be exactly CLK_DIV/2 PCLKs inside a transfer
            if (sck !== sck_q) begin
                if (in_window && (half_len != HALF)) begin
                    errors = errors + 1;
                    $display("[%0t] ERROR: SCK half-period %0d PCLKs (expected %0d)", $time, half_len, HALF);
                end
                in_window = 1;
                half_len  = 1;
            end else begin
                half_len = half_len + 1;
            end
            if (cs_n) in_window = 0;

            // APB: zero-wait-state slave
            if (PREADY !== 1'b1) fail("PREADY not high");
        end
        sck_q  <= sck;
        mosi_q <= mosi;
        cs_n_q <= cs_n;
    end

    // ------------------------------------------------------------------
    // Select an SPI mode (0..3). No-op on RTL without the CFG register.
    // ------------------------------------------------------------------
    task set_mode(input [1:0] mode);
        reg [31:0] rd;
        begin
`ifdef HAS_MODES
            if ({s_cpol, s_cpha} != {mode[1], mode[0]}) begin
                apb_write(ADDR_CFG, {30'd0, mode[0], mode[1]});    // CFG = {CPHA, CPOL}
                s_cpol = mode[1];
                s_cpha = mode[0];
                mode_settle = 3;
                apb_read(ADDR_CFG, rd);
                if (rd !== {30'd0, mode[0], mode[1]}) fail("CFG readback mismatch");
            end
`endif
        end
    endtask

    // ------------------------------------------------------------------
    // One complete firmware-style transfer, fully checked
    // ------------------------------------------------------------------
    task do_transfer(input [1:0] mode, input [7:0] tx_byte, input [7:0] reply_byte,
                     input integer max_poll_gap);
        reg [31:0] rd;
        integer    waited, gap, prev_count;
        begin
            set_mode(mode);
            slave_reply = reply_byte;
            prev_count  = slave_rx_count;

            apb_write(ADDR_TX, {24'd0, tx_byte});
            idle($urandom % 4);
            apb_write(ADDR_CTRL, 32'h1);                       // START

            // Poll CTRL until DONE, with random spacing between polls
            rd = 0; waited = 0;
            while (!rd[DONE_BIT] && waited < TIMEOUT) begin
                gap = (max_poll_gap == 0) ? 0 : ($urandom % (max_poll_gap + 1));
                idle(gap);
                apb_read(ADDR_CTRL, rd);
                n_polls = n_polls + 1;
                waited  = waited + gap + 3;
            end

            if (!rd[DONE_BIT]) begin
                errors = errors + 1;
                $display("[%0t] ERROR: transfer %0d: DONE never seen after %0d PCLKs (status flag lost?)",
                         $time, n_transfers, waited);
                // recover: wait for the SPI side to finish so the next test starts clean
                wait (cs_n == 1'b1); idle(8);
            end else begin
                // CPU side: byte read back must equal what the slave sent
                apb_read(ADDR_RX, rd);
                if (rd[7:0] !== reply_byte) begin
                    errors = errors + 1;
                    $display("[%0t] ERROR: mode %0d RX mismatch: got %02h expected %02h",
                             $time, {s_cpol, s_cpha}, rd[7:0], reply_byte);
                end
                if (rd[31:8] !== 24'd0) fail("RX_REG upper bits not zero");
            end

            // Slave side: byte on MOSI must equal what the CPU wrote
            if (slave_rx_count != prev_count + 1) begin
                errors = errors + 1;
                $display("[%0t] ERROR: slave saw %0d transfers (expected 1)", $time, slave_rx_count - prev_count);
            end else if (slave_rx_last !== tx_byte) begin
                errors = errors + 1;
                $display("[%0t] ERROR: mode %0d MOSI mismatch: slave got %02h expected %02h",
                         $time, {s_cpol, s_cpha}, slave_rx_last, tx_byte);
            end

            n_transfers = n_transfers + 1;
            n_mode[{s_cpol, s_cpha}] = n_mode[{s_cpol, s_cpha}] + 1;
        end
    endtask

    // ------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------
    integer    i, m, seed, seed_user, err_before;
    reg [31:0] rd;
    reg [7:0]  tx_b, rx_b;
    reg [1:0]  mode_r;

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        seed_user = seed;
        rd = $urandom(seed);    // seed the generator
`ifdef DUMP
        $dumpfile("tb_apb_spi_random.vcd");
        $dumpvars(0, tb_apb_spi_random);
`endif
        $display("==== APB-SPI random regression: CLK_DIV=%0d NUM_TX=%0d seed=%0d ====",
                 `CLK_DIV, `NUM_TX, seed_user);

        #1; idle(3); #1 PRESETn = 1; idle(2);

        // ---- Directed 1: register readback and unmapped addresses ----
        apb_write(ADDR_TX, 32'hFFFF_FFA5);
        apb_read (ADDR_TX, rd);
        if (rd !== 32'h0000_00A5) fail("TX_REG readback mismatch");
        apb_read (ADDR_NONE, rd);
        if (rd !== 32'h0) fail("unmapped address 0x10 did not read as zero");
        apb_read (ADDR_CTRL, rd);
        if (rd[DONE_BIT] !== 1'b0) fail("DONE set out of reset");
`ifdef HAS_MODES
        apb_read (ADDR_CFG, rd);
        if (rd !== 32'h0) fail("CFG not mode 0 out of reset");
`endif

        // ---- Directed 1b: writes to unmapped addresses have no side effects ----
        apb_write(ADDR_NONE,     32'hFFFF_FFFF);
        apb_write(32'h0000_00F3, 32'hFFFF_FFFF);
        apb_read (32'h0000_00F3, rd);
        if (rd !== 32'h0) fail("unmapped address 0xF3 did not read as zero");
        apb_read (ADDR_TX, rd);
        if (rd !== 32'h0000_00A5) fail("unmapped write changed TX_REG");
        idle(4 * `CLK_DIV);
        if (cs_n !== 1'b1) fail("unmapped write started a transfer");

        // ---- Directed 2: corner data patterns in every SPI mode ----
        for (m = 0; m < 4; m = m + 1) begin
            do_transfer(m[1:0], 8'h00, 8'hFF, 0);
            do_transfer(m[1:0], 8'hFF, 8'h00, 0);
            do_transfer(m[1:0], 8'hA5, 8'h5A, 0);
            do_transfer(m[1:0], 8'h80, 8'h01, 0);
            do_transfer(m[1:0], 8'h01, 8'h80, 0);
        end
        set_mode(2'd0);

`ifdef HAS_BUSY
        // ---- Directed 3: BUSY bit, START / TX / CFG writes while busy ----
        slave_reply = 8'h3C;
        apb_write(ADDR_TX, 32'h96);
        apb_write(ADDR_CTRL, 32'h1);
        apb_read (ADDR_CTRL, rd);
        if (!rd[BUSY_BIT]) fail("BUSY not set during transfer");
        apb_write(ADDR_TX, 32'h11);                 // firmware misbehaves: rewrites TX ...
`ifdef HAS_MODES
        apb_write(ADDR_CFG, 32'h3);                 // ... changes the SPI mode ...
`endif
        apb_write(ADDR_CTRL, 32'h1);                // ... and re-STARTs while busy
        rd = 0;
        while (!rd[DONE_BIT]) apb_read(ADDR_CTRL, rd);
        if (rd[BUSY_BIT]) fail("BUSY still set after DONE");
        idle(4 * `CLK_DIV);
        if (cs_n !== 1'b1) fail("START while busy launched a second transfer");
        if (slave_rx_last !== 8'h96) fail("TX byte corrupted by a write while busy");
        apb_read(ADDR_RX, rd);
        if (rd[7:0] !== 8'h3C) fail("RX wrong after busy test");
`ifdef HAS_MODES
        apb_read(ADDR_CFG, rd);
        if (rd !== 32'h0) fail("CFG changed by a write while busy");
`endif
`endif

        // ---- Directed 4: reset in the middle of a transfer ----
        slave_reply = 8'hC3;
        apb_write(ADDR_TX, 32'h3C);
        apb_write(ADDR_CTRL, 32'h1);
        idle(5 * `CLK_DIV);
        #1 PRESETn = 0;
        #1 if (cs_n !== 1'b1 || sck !== 1'b0) fail("outputs not idle during reset");
        s_cpol = 0; s_cpha = 0;                     // reset returns CFG to mode 0
        idle(2); #1 PRESETn = 1; idle(2);
        apb_read(ADDR_CTRL, rd);
        if (rd[DONE_BIT]) fail("DONE set after mid-transfer reset");
        do_transfer(2'd0, 8'h5A, 8'hA5, 0);          // must work normally again

        // ---- Random regression ----
        err_before = errors;
        for (i = 0; i < `NUM_TX; i = i + 1) begin
            tx_b = $urandom; rx_b = $urandom;
`ifdef HAS_MODES
            mode_r = $urandom;
`else
            mode_r = 2'd0;
`endif
            do_transfer(mode_r, tx_b, rx_b, 6);      // random 0..6 idle cycles between polls
            if (errors > err_before + 5) begin
                $display("Too many errors, stopping random phase early.");
                i = `NUM_TX;
            end
        end

        // ---- Summary ----
        $display("--------------------------------------------------------------");
        $display("Transfers: %0d   Status polls: %0d   Errors: %0d", n_transfers, n_polls, errors);
        $display("Per SPI mode: m0=%0d m1=%0d m2=%0d m3=%0d", n_mode[0], n_mode[1], n_mode[2], n_mode[3]);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $display("--------------------------------------------------------------");
        $finish;
    end

endmodule
