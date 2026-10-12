`timescale 1ns / 1ps

module tb_apb_spi;

    // ============================================================
    // APB BUS SIGNALS
    // ============================================================
    reg         PCLK;
    reg         PRESETn;
    reg  [31:0] PADDR;
    reg         PSEL;
    reg         PENABLE;
    reg         PWRITE;
    reg  [31:0] PWDATA;
    wire [31:0] PRDATA;
    wire        PREADY;

    // ============================================================
    // SPI SIGNALS
    // ============================================================
    wire mosi;
    wire sck;
    wire cs_n;
    reg  miso;

    // ============================================================
    // INSTANTIATE APB WRAPPER (TOP LEVEL)
    // ============================================================
    apb_spi_wrapper uut (
        .PCLK(PCLK),
        .PRESETn(PRESETn),
        .PADDR(PADDR),
        .PSEL(PSEL),
        .PENABLE(PENABLE),
        .PWRITE(PWRITE),
        .PWDATA(PWDATA),
        .PRDATA(PRDATA),
        .PREADY(PREADY),

        .mosi(mosi),
        .sck(sck),
        .cs_n(cs_n),
        .miso(miso)
    );

    // ============================================================
    // CLOCK GENERATION (100 MHz)
    // ============================================================
    always #5 PCLK = ~PCLK;

    // ============================================================
    // CPU TASKS (Bus Functional Models with #1 Delays)
    // ============================================================

    task apb_write(input [31:0] address, input [31:0] data);
        begin
            @(posedge PCLK);
            #1; // Drive 1ns AFTER the clock edge
            PADDR   = address;
            PWDATA  = data;
            PSEL    = 1'b1;
            PWRITE  = 1'b1;
            PENABLE = 1'b0;

            @(posedge PCLK);
            #1;
            PENABLE = 1'b1;

            @(posedge PCLK);
            #1;
            PSEL    = 1'b0;
            PENABLE = 1'b0;
        end
    endtask

    task apb_read(input [31:0] address, output [31:0] data);
        begin
            @(posedge PCLK);
            #1; // Drive 1ns AFTER the clock edge
            PADDR   = address;
            PSEL    = 1'b1;
            PWRITE  = 1'b0;
            PENABLE = 1'b0;

            @(posedge PCLK);
            #1;
            PENABLE = 1'b1;

            @(posedge PCLK);
            #1;
            data    = PRDATA; // Sample data 1ns AFTER the clock edge
            PSEL    = 1'b0;
            PENABLE = 1'b0;
        end
    endtask

    // ============================================================
    // FAKE SLAVE BEHAVIOR
    // ============================================================
    reg [7:0] slave_data;
    reg       sck_q, cs_n_q;

    initial begin
        slave_data = 8'h3C;
        sck_q = 0; cs_n_q = 1; miso = 0;
    end

    always @(posedge PCLK) begin
        sck_q  <= sck;
        cs_n_q <= cs_n;

        if (cs_n_q == 1'b1 && cs_n == 1'b0) begin
            miso <= slave_data[7];
            slave_data <= {slave_data[6:0], 1'b0};
        end
        else if (sck_q == 1'b1 && sck == 1'b0) begin
            if (!cs_n) begin
                miso <= slave_data[7];
                slave_data <= {slave_data[6:0], 1'b0};
            end
        end
    end

    // ============================================================
    // MAIN CPU FIRMWARE SIMULATION
    // ============================================================
    reg [31:0] read_val;

    initial begin
        $dumpfile("apb_waveforms.vcd");
        $dumpvars(0, tb_apb_spi);

        PCLK    = 0;
        PRESETn = 0;
        PSEL    = 0;
        PENABLE = 0;
        PWRITE  = 0;
        PADDR   = 0;
        PWDATA  = 0;

        #20 PRESETn = 1;
        #20;

        $display("--- CPU STARTING SPI TRANSFER ---");

        // CPU writes 0xB2 to TX_REG
        apb_write(32'h0000_0000, 32'h0000_00B2);

        // CPU writes 1 to CTRL_REG to trigger transfer
        apb_write(32'h0000_0008, 32'h0000_0001);

        // CPU Polls the CTRL_REG waiting for 'done' bit
        read_val = 0;
        while ((read_val & 32'h0000_0002) == 0) begin
            apb_read(32'h0000_0008, read_val);
        end
        $display("CPU: SPI Transfer Done flag detected!");

        // CPU reads the RX_REG
        apb_read(32'h0000_0004, read_val);
        $display("CPU Read RX Data: 0x%h", read_val);

        if (read_val == 32'h0000_003C)
            $display("STATUS: PASS - CPU successfully received 0x3C over APB");
        else
            $display("STATUS: FAIL");

        #50 $finish;
    end

endmodule
