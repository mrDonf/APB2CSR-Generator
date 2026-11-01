// =============================================================================
// tb_demo_apb_csr.sv - directed test of the csrgen-generated "demo" APB4 IP
// -----------------------------------------------------------------------------
// Exercises every field access type (RW, RO, WO, W1C, W1S, W0C, W0S, W0T, RC, W1P, const,
// hw_write, access strobes), reset values, byte strobes and error responses.
// Offsets / reset values are taken from the generated demo_csr_pkg.
// =============================================================================
`timescale 1ns/1ps

module tb_demo_apb_csr;
  import demo_csr_pkg::*;

  localparam logic [31:0] BASE = 32'h4001_0000;

  logic pclk = 1'b0;
  logic presetn;
  always #5 pclk = ~pclk;

  apb4_master_if #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) apb (pclk, presetn);

  // Hardware side
  logic        ctrl_en, ctrl_start;
  logic [2:0]  ctrl_mode;
  logic [7:0]  ctrl_prescaler;
  logic        status_busy;
  logic [3:0]  status_state;
  logic        int_done, int_err, int_done_set, int_err_set;
  logic        int_en_done, int_en_err;
  logic [7:0]  cmd_flags, cmd_flags_clr;
  logic [3:0]  event_flags, event_flags_set;
  logic [31:0] counter_value, counter_d;
  logic        counter_we;
  logic [31:0] key_value, data_value;
  logic        data_wr, data_rd;
  logic [3:0]  zw_clr, zw_clr_set, zw_set, zw_set_clr, zw_tog;

  demo_apb_csr dut (
    .pclk                  (pclk),
    .presetn               (presetn),
    .psel                  (apb.psel),
    .penable               (apb.penable),
    .paddr                 (apb.paddr),
    .pwrite                (apb.pwrite),
    .pwdata                (apb.pwdata),
    .pstrb                 (apb.pstrb),
    .pprot                 (apb.pprot),
    .pready                (apb.pready),
    .prdata                (apb.prdata),
    .pslverr               (apb.pslverr),
    .ctrl_en_o             (ctrl_en),
    .ctrl_mode_o           (ctrl_mode),
    .ctrl_prescaler_o      (ctrl_prescaler),
    .ctrl_start_o          (ctrl_start),
    .status_busy_i         (status_busy),
    .status_state_i        (status_state),
    .int_status_done_o     (int_done),
    .int_status_done_set_i (int_done_set),
    .int_status_err_o      (int_err),
    .int_status_err_set_i  (int_err_set),
    .int_en_done_o         (int_en_done),
    .int_en_err_o          (int_en_err),
    .cmd_flags_o           (cmd_flags),
    .cmd_flags_clr_i       (cmd_flags_clr),
    .event_flags_o         (event_flags),
    .event_flags_set_i     (event_flags_set),
    .counter_value_o       (counter_value),
    .counter_value_we_i    (counter_we),
    .counter_value_d_i     (counter_d),
    .key_value_o           (key_value),
    .data_value_i          (data_value),
    .data_wr_o             (data_wr),
    .data_rd_o             (data_rd),
    .zero_wr_clr_o         (zw_clr),
    .zero_wr_clr_set_i     (zw_clr_set),
    .zero_wr_set_o         (zw_set),
    .zero_wr_set_clr_i     (zw_set_clr),
    .zero_wr_tog_o         (zw_tog)
  );

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  int unsigned errors = 0;
  int unsigned n_start, n_data_wr, n_data_rd;

  always @(posedge pclk) begin
    if (presetn) begin
      n_start   += ctrl_start;
      n_data_wr += data_wr;
      n_data_rd += data_rd;
    end
  end

  function automatic void check(string what, logic [31:0] act, logic [31:0] exp);
    if (act !== exp) begin
      errors++;
      $error("[%0t] %s: got 0x%08h expected 0x%08h", $time, what, act, exp);
    end
  endfunction

  task automatic wr(logic [7:0] off, logic [31:0] data, bit exp_err = 1'b0, logic [3:0] strb = 4'hF);
    bit err;
    apb.write(BASE | off, data, err, strb);
    check($sformatf("PSLVERR wr 0x%02h", off), 32'(err), 32'(exp_err));
  endtask

  task automatic rd(logic [7:0] off, output logic [31:0] data, input bit exp_err = 1'b0);
    bit err;
    apb.read(BASE | off, data, err);
    check($sformatf("PSLVERR rd 0x%02h", off), 32'(err), 32'(exp_err));
  endtask

  task automatic rd_chk(logic [7:0] off, logic [31:0] exp, string what);
    logic [31:0] d;
    rd(off, d);
    check(what, d, exp);
  endtask

  // ---------------------------------------------------------------------------
  // Test
  // ---------------------------------------------------------------------------
  initial begin
    logic [31:0] d;
    int unsigned c0;

    apb.init();
    {status_busy, status_state, int_done_set, int_err_set, cmd_flags_clr,
     event_flags_set, counter_we, counter_d, data_value, zw_clr_set, zw_set_clr} = '0;
    {n_start, n_data_wr, n_data_rd} = '0;
    presetn = 1'b0;
    repeat (4) @(posedge pclk);
    presetn <= 1'b1;
    @(posedge pclk);

    // --- Reset values (hardware inputs are 0)
    $display("T1: reset values");
    rd_chk(DEMO_CTRL_OFFSET,       DEMO_CTRL_RESET,       "CTRL reset");
    rd_chk(DEMO_STATUS_OFFSET,     DEMO_STATUS_RESET,     "STATUS reset");
    rd_chk(DEMO_INT_STATUS_OFFSET, DEMO_INT_STATUS_RESET, "INT_STATUS reset");
    rd_chk(DEMO_INT_EN_OFFSET,     DEMO_INT_EN_RESET,     "INT_EN reset");
    rd_chk(DEMO_CMD_OFFSET,        DEMO_CMD_RESET,        "CMD reset");
    rd_chk(DEMO_EVENT_OFFSET,      DEMO_EVENT_RESET,      "EVENT reset");
    rd_chk(DEMO_COUNTER_OFFSET,    DEMO_COUNTER_RESET,    "COUNTER reset");
    rd_chk(DEMO_KEY_OFFSET,        DEMO_KEY_RESET,        "KEY reset");
    rd_chk(DEMO_ZERO_WR_OFFSET,    DEMO_ZERO_WR_RESET,    "ZERO_WR reset");
    check("ZERO_WR reset value", DEMO_ZERO_WR_RESET, 32'h0005_0000);
    rd_chk(DEMO_VERSION_OFFSET,    DEMO_VERSION_RESET,    "VERSION reset");
    check("VERSION value", DEMO_VERSION_RESET, 32'h0001_0003);
    check("ctrl_mode_o reset", 32'(ctrl_mode), 32'h2);
    check("ctrl_prescaler_o reset", 32'(ctrl_prescaler), 32'h10);

    // --- RW + W1P
    $display("T2: RW fields, W1P pulse");
    wr(DEMO_CTRL_OFFSET, 32'hFFFF_FFFF & ~DEMO_CTRL_START_MASK);
    rd_chk(DEMO_CTRL_OFFSET, DEMO_CTRL_EN_MASK | DEMO_CTRL_MODE_MASK | DEMO_CTRL_PRESCALER_MASK, "CTRL RW");
    check("ctrl_en_o", 32'(ctrl_en), 1);
    check("ctrl_mode_o", 32'(ctrl_mode), 7);
    check("ctrl_prescaler_o", 32'(ctrl_prescaler), 8'hFF);
    c0 = n_start;
    wr(DEMO_CTRL_OFFSET, DEMO_CTRL_START_MASK | 32'h0000_3401);  // START + PRESCALER=0x34, EN=1, MODE=0
    repeat (3) @(posedge pclk);
    check("START pulse count", n_start - c0, 1);
    rd_chk(DEMO_CTRL_OFFSET, 32'h0000_3401, "CTRL after START (W1P reads 0)");

    // --- Byte strobe: only PRESCALER byte
    $display("T3: PSTRB byte lanes");
    wr(DEMO_CTRL_OFFSET, 32'hFFFF_A5FE, 1'b0, 4'b0010);
    rd_chk(DEMO_CTRL_OFFSET, 32'h0000_A501, "CTRL byte-lane write");
    c0 = n_start;
    wr(DEMO_CTRL_OFFSET, 32'hFFFF_FFFF, 1'b0, 4'b0000);   // no lanes -> no effect, no pulse
    repeat (2) @(posedge pclk);
    check("START with strobe off", n_start - c0, 0);
    rd_chk(DEMO_CTRL_OFFSET, 32'h0000_A501, "CTRL unchanged with PSTRB=0");

    // --- RO
    $display("T4: RO fields");
    status_busy  <= 1'b1;
    status_state <= 4'hA;
    @(posedge pclk);
    rd_chk(DEMO_STATUS_OFFSET, 32'h0000_00A1, "STATUS RO");
    wr(DEMO_STATUS_OFFSET, 32'h0000_0000);
    rd_chk(DEMO_STATUS_OFFSET, 32'h0000_00A1, "STATUS write ignored");

    // --- W1C
    $display("T5: W1C");
    int_done_set <= 1'b1;
    @(posedge pclk);
    int_done_set <= 1'b0;
    int_err_set  <= 1'b1;
    @(posedge pclk);
    int_err_set  <= 1'b0;
    rd_chk(DEMO_INT_STATUS_OFFSET, 32'h3, "INT_STATUS set by hw");
    wr(DEMO_INT_STATUS_OFFSET, 32'h1);
    rd_chk(DEMO_INT_STATUS_OFFSET, 32'h2, "INT_STATUS W1C DONE");
    wr(DEMO_INT_STATUS_OFFSET, 32'h0);
    rd_chk(DEMO_INT_STATUS_OFFSET, 32'h2, "INT_STATUS write 0 no effect");
    // Simultaneous hardware set and software clear: set wins
    int_err_set <= 1'b1;
    wr(DEMO_INT_STATUS_OFFSET, 32'h2);
    int_err_set <= 1'b0;
    rd_chk(DEMO_INT_STATUS_OFFSET, 32'h2, "INT_STATUS set beats clear");
    wr(DEMO_INT_STATUS_OFFSET, 32'h3);
    rd_chk(DEMO_INT_STATUS_OFFSET, 32'h0, "INT_STATUS cleared");
    // W1C must honour PSTRB and ignore 0 bits
    int_done_set <= 1'b1;
    int_err_set  <= 1'b1;
    @(posedge pclk);
    int_done_set <= 1'b0;
    int_err_set  <= 1'b0;
    wr(DEMO_INT_STATUS_OFFSET, 32'h3, 1'b0, 4'b0000);
    rd_chk(DEMO_INT_STATUS_OFFSET, 32'h3, "INT_STATUS W1C with PSTRB=0");
    wr(DEMO_INT_STATUS_OFFSET, 32'h0);
    rd_chk(DEMO_INT_STATUS_OFFSET, 32'h3, "INT_STATUS W1C write 0");
    wr(DEMO_INT_STATUS_OFFSET, 32'h3);
    rd_chk(DEMO_INT_STATUS_OFFSET, 32'h0, "INT_STATUS cleared again");

    // --- INT_EN (RW, 1-bit fields)
    wr(DEMO_INT_EN_OFFSET, 32'hFFFF_FFFF);
    rd_chk(DEMO_INT_EN_OFFSET, 32'h3, "INT_EN RW");
    check("int_en outputs", {int_en_err, int_en_done}, 2'b11);
    wr(DEMO_INT_EN_OFFSET, 32'h1);
    rd_chk(DEMO_INT_EN_OFFSET, 32'h1, "INT_EN write DONE only");
    wr(DEMO_INT_EN_OFFSET, 32'h0, 1'b0, 4'b0000);
    rd_chk(DEMO_INT_EN_OFFSET, 32'h1, "INT_EN PSTRB=0 no effect");

    // --- W1S
    $display("T6: W1S");
    wr(DEMO_CMD_OFFSET, 32'h05);
    wr(DEMO_CMD_OFFSET, 32'h02);
    rd_chk(DEMO_CMD_OFFSET, 32'h07, "CMD W1S accumulate");
    check("cmd_flags_o", 32'(cmd_flags), 32'h07);
    cmd_flags_clr <= 8'h01;
    @(posedge pclk);
    cmd_flags_clr <= 8'h00;
    rd_chk(DEMO_CMD_OFFSET, 32'h06, "CMD hw clear");

    // --- RC
    $display("T7: RC");
    event_flags_set <= 4'b1001;
    @(posedge pclk);
    event_flags_set <= 4'b0000;
    rd_chk(DEMO_EVENT_OFFSET, 32'h9, "EVENT read returns flags");
    rd_chk(DEMO_EVENT_OFFSET, 32'h0, "EVENT cleared by read");
    check("event_flags_o after RC", 32'(event_flags), 0);

    // --- RW with hardware write
    $display("T8: RW + hw_write");
    wr(DEMO_COUNTER_OFFSET, 32'h1234_5678);
    check("counter_value_o sw", counter_value, 32'h1234_5678);
    counter_d  <= 32'hCAFE_0001;
    counter_we <= 1'b1;
    @(posedge pclk);
    counter_we <= 1'b0;
    rd_chk(DEMO_COUNTER_OFFSET, 32'hCAFE_0001, "COUNTER hw write");

    // --- WO
    $display("T9: WO");
    wr(DEMO_KEY_OFFSET, 32'hDEAD_BEEF);
    check("key_value_o", key_value, 32'hDEAD_BEEF);
    rd_chk(DEMO_KEY_OFFSET, 32'h0, "KEY reads 0");

    // --- RO + access strobes
    $display("T10: access strobes");
    data_value <= 32'h0BAD_F00D;
    @(posedge pclk);
    c0 = n_data_rd;
    rd_chk(DEMO_DATA_OFFSET, 32'h0BAD_F00D, "DATA RO");
    check("DATA rd strobe count", n_data_rd - c0, 1);
    c0 = n_data_wr;
    wr(DEMO_DATA_OFFSET, 32'h1);
    @(posedge pclk);
    check("DATA wr strobe count", n_data_wr - c0, 1);

    // --- W0C / W0S / W0T   (ZERO_WR: CLR[3:0] W0C, SET[11:8] W0S, TOG[19:16] W0T)
    $display("T11: W0C / W0S / W0T");
    wr(DEMO_ZERO_WR_OFFSET, 32'hFFFF_FFFF);                   // all ones: no action
    rd_chk(DEMO_ZERO_WR_OFFSET, 32'h0005_0000, "ZERO_WR write all-ones");
    zw_clr_set <= 4'b1011;                                     // hardware sets CLR bits
    @(posedge pclk);
    zw_clr_set <= 4'b0000;
    rd_chk(DEMO_ZERO_WR_OFFSET, 32'h0005_000B, "W0C set by hw");
    wr(DEMO_ZERO_WR_OFFSET, 32'hFFFF_FFFE);                   // W0C: clear bit 0
    rd_chk(DEMO_ZERO_WR_OFFSET, 32'h0005_000A, "W0C write 0 clears");
    check("zero_wr_clr_o", 32'(zw_clr), 32'hA);
    wr(DEMO_ZERO_WR_OFFSET, 32'h0000_0000, 1'b0, 4'b0000);    // no lanes: no action
    rd_chk(DEMO_ZERO_WR_OFFSET, 32'h0005_000A, "W0x with PSTRB=0");
    wr(DEMO_ZERO_WR_OFFSET, 32'h0000_0000, 1'b0, 4'b0100);    // lane 2 only: toggle TOG
    rd_chk(DEMO_ZERO_WR_OFFSET, 32'h000A_000A, "W0T toggle, other lanes masked");
    wr(DEMO_ZERO_WR_OFFSET, 32'hFFFF_F9FF);                   // W0S: set SET bits 2,1
    rd_chk(DEMO_ZERO_WR_OFFSET, 32'h000A_060A, "W0S write 0 sets");
    check("zero_wr_set_o", 32'(zw_set), 32'h6);
    zw_set_clr <= 4'b0010;                                     // hardware clears SET bit 1
    @(posedge pclk);
    zw_set_clr <= 4'b0000;
    rd_chk(DEMO_ZERO_WR_OFFSET, 32'h000A_040A, "W0S cleared by hw");
    // Same-cycle conflicts: the software write happens in the APB SETUP cycle,
    // so the hardware pulse is applied in exactly that cycle.
    fork
      wr(DEMO_ZERO_WR_OFFSET, 32'hFFFF_FFFE);                 // W0C clear bit 0 ...
      begin zw_clr_set <= 4'b0001; @(posedge pclk); zw_clr_set <= 4'b0000; end  // ... hw sets it
    join
    rd_chk(DEMO_ZERO_WR_OFFSET, 32'h000A_040B, "W0C: hw set beats sw clear");
    fork
      wr(DEMO_ZERO_WR_OFFSET, 32'hFFFF_F7FF);                 // W0S set bit 3 ...
      begin zw_set_clr <= 4'b1000; @(posedge pclk); zw_set_clr <= 4'b0000; end  // ... hw clears it
    join
    rd_chk(DEMO_ZERO_WR_OFFSET, 32'h000A_0C0B, "W0S: sw set beats hw clear");
    wr(DEMO_ZERO_WR_OFFSET, 32'hFFF0_FFFF);                   // W0T toggle all: A -> 5
    rd_chk(DEMO_ZERO_WR_OFFSET, 32'h0005_0C0B, "W0T toggle all");
    wr(DEMO_ZERO_WR_OFFSET, 32'hFFFA_FFFF);                   // W0T toggle bits 0,2: 5 -> 0
    rd_chk(DEMO_ZERO_WR_OFFSET, 32'h0000_0C0B, "W0T toggle selected bits");
    check("zero_wr_tog_o", 32'(zw_tog), 32'h0);

    // --- Error responses
    $display("T12: error responses");
    rd(8'h40, d, 1'b1);
    check("unmapped read data", d, 0);
    wr(8'h40, 32'h1, 1'b1);
    rd(DEMO_CTRL_OFFSET | 8'h1, d, 1'b1);                // unaligned
    wr(DEMO_CTRL_OFFSET | 8'h2, 32'h0, 1'b1);            // unaligned, must not write
    rd_chk(DEMO_CTRL_OFFSET, 32'h0000_A501, "CTRL unchanged after unaligned write");
    rd_chk(DEMO_VERSION_OFFSET, 32'h0001_0003, "VERSION after errors");

    repeat (5) @(posedge pclk);
    if (errors == 0) $display("TEST PASSED");
    else             $display("TEST FAILED: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #1ms;
    $fatal(1, "global timeout");
  end

endmodule : tb_demo_apb_csr
