// =============================================================================
// tb_apb2csr.sv - self-checking testbench for the apb2csr bridge
// -----------------------------------------------------------------------------
// * APB4 master BFM -> apb2csr -> behavioural CSR slave (memory) with random
//   latency, an error region and a "hang" word (never acks, for timeout).
// * Checks: read data vs. reference model, PSLVERR, transfer length (cycle
//   accurate: 2 + slave latency), exactly one CSR handshake per forwarded
//   transfer, CSR request stability, local error filtering (alignment, PPROT).
// * All bridge parameters are top-level parameters -> override with vsim -G.
// =============================================================================
`timescale 1ns/1ps

module tb_apb2csr;

  parameter int unsigned DATA_WIDTH     = 32;
  parameter int unsigned CSR_ADDR_WIDTH = 10;
  parameter bit          USE_PSTRB      = 1'b1;
  parameter bit          ERR_UNALIGNED  = 1'b1;
  parameter bit          PRIV_ONLY      = 1'b0;
  parameter bit          SECURE_ONLY    = 1'b0;
  parameter int unsigned TIMEOUT_CYCLES = 16;
  parameter bit          ASYNC_RESET    = 1'b1;
  parameter int unsigned MAX_LATENCY   = 4;     // CSR slave latency 0..MAX_LATENCY
  parameter int unsigned NUM_RANDOM     = 3000;

  localparam int unsigned APB_ADDR_WIDTH = 32;
  localparam int unsigned SW        = DATA_WIDTH / 8;
  localparam int unsigned LSB       = (SW > 1) ? $clog2(SW) : 0;
  localparam int unsigned WAW       = CSR_ADDR_WIDTH - LSB;
  localparam int unsigned DEPTH     = 1 << WAW;
  localparam int unsigned ERR_BASE  = DEPTH - 4;         // last 4 words: slave error
  localparam int unsigned HANG_IDX  = DEPTH - 5;         // never acknowledged
  localparam logic [31:0] APB_BASE  = 32'h4000_0000;     // upper bits ignored by bridge

  typedef logic [DATA_WIDTH-1:0] data_t;
  typedef logic [SW-1:0]         strb_t;

  // ---------------------------------------------------------------------------
  // Clock / reset / DUT
  // ---------------------------------------------------------------------------
  logic pclk = 1'b0;
  logic presetn;
  always #5 pclk = ~pclk;

  apb4_master_if #(.ADDR_WIDTH(APB_ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)) apb (pclk, presetn);

  logic                      csr_req, csr_we, csr_ack, csr_err;
  logic [CSR_ADDR_WIDTH-1:0] csr_addr;
  data_t                     csr_wdata, csr_rdata;
  strb_t                     csr_wstrb;
  logic [2:0]                csr_prot;

  apb2csr #(
    .APB_ADDR_WIDTH (APB_ADDR_WIDTH),
    .DATA_WIDTH     (DATA_WIDTH),
    .CSR_ADDR_WIDTH (CSR_ADDR_WIDTH),
    .USE_PSTRB      (USE_PSTRB),
    .ERR_UNALIGNED  (ERR_UNALIGNED),
    .PRIV_ONLY      (PRIV_ONLY),
    .SECURE_ONLY    (SECURE_ONLY),
    .TIMEOUT_CYCLES (TIMEOUT_CYCLES),
    .ASYNC_RESET    (ASYNC_RESET)
  ) dut (
    .pclk      (pclk),
    .presetn   (presetn),
    .psel      (apb.psel),
    .penable   (apb.penable),
    .paddr     (apb.paddr),
    .pwrite    (apb.pwrite),
    .pwdata    (apb.pwdata),
    .pstrb     (apb.pstrb),
    .pprot     (apb.pprot),
    .pready    (apb.pready),
    .prdata    (apb.prdata),
    .pslverr   (apb.pslverr),
    .csr_req   (csr_req),
    .csr_we    (csr_we),
    .csr_addr  (csr_addr),
    .csr_wdata (csr_wdata),
    .csr_wstrb (csr_wstrb),
    .csr_prot  (csr_prot),
    .csr_ack   (csr_ack),
    .csr_rdata (csr_rdata),
    .csr_err   (csr_err)
  );

  // ---------------------------------------------------------------------------
  // Behavioural CSR slave
  // ---------------------------------------------------------------------------
  data_t       mem [DEPTH];
  int unsigned next_lat;          // latency of the next new request
  int unsigned remain;            // remaining wait cycles of current request
  bit          inflight;
  int unsigned req_age;           // cycles the current request has been pending
  int unsigned last_hs_lat;       // latency of the last completed handshake
  int unsigned hs_count;          // number of handshakes
  data_t       junk;              // garbage driven on csr_rdata when not valid

  logic [WAW-1:0] widx;
  logic           hang;
  assign widx = csr_addr[CSR_ADDR_WIDTH-1:LSB];
  assign hang = (widx == WAW'(HANG_IDX));

  always_comb begin
    csr_ack = 1'b0;
    if (csr_req && !hang) csr_ack = inflight ? (remain == 0) : (next_lat == 0);
  end
  assign csr_err   = csr_ack && (widx >= WAW'(ERR_BASE));
  assign csr_rdata = (csr_ack && !csr_we && !csr_err) ? mem[widx] : junk;

  always @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
      inflight    <= 1'b0;
      remain      <= 0;
      req_age     <= 0;
      next_lat    <= 0;
      hs_count    <= 0;
      last_hs_lat <= 0;
    end else begin
      next_lat <= $urandom_range(MAX_LATENCY, 0);
      junk     <= data_t'($urandom);
      if (!csr_req) begin
        inflight <= 1'b0;
        req_age  <= 0;
      end else if (csr_ack) begin
        inflight    <= 1'b0;
        req_age     <= 0;
        hs_count    <= hs_count + 1;
        last_hs_lat <= req_age;
        if (csr_we && !csr_err) begin
          for (int b = 0; b < SW; b++)
            if (csr_wstrb[b]) mem[widx][8*b +: 8] <= csr_wdata[8*b +: 8];
        end
      end else begin
        req_age <= req_age + 1;
        if (!inflight) begin
          inflight <= 1'b1;
          remain   <= next_lat - 1;
        end else if (remain != 0) begin
          remain <= remain - 1;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Scoreboard / checkers
  // ---------------------------------------------------------------------------
  data_t       ref_mem [DEPTH];
  int unsigned errors;
  int unsigned n_rd, n_wr, n_err, n_tmo, n_local, n_partial;

  function automatic void fail(string msg);
    errors++;
    $error("[%0t] %s", $time, msg);
  endfunction

  // CSR side: request must stay stable until ack (or until a timeout drop)
  logic                      p_req, p_ack, p_we;
  logic [CSR_ADDR_WIDTH-1:0] p_addr;
  data_t                     p_wdata;
  strb_t                     p_wstrb;
  always @(posedge pclk) begin
    if (presetn) begin
      if (p_req && !p_ack) begin
        if (csr_req && (csr_we !== p_we || csr_addr !== p_addr ||
                        (p_we && (csr_wdata !== p_wdata || csr_wstrb !== p_wstrb))))
          fail("CSR request changed before acknowledge");
        if (!csr_req && !(TIMEOUT_CYCLES > 0 && p_addr[CSR_ADDR_WIDTH-1:LSB] == WAW'(HANG_IDX)))
          fail("CSR request dropped before acknowledge");
      end
      if (csr_req && !apb.psel) fail("CSR request without PSEL");
      if (csr_req && !csr_we && csr_wstrb !== '0) fail("csr_wstrb not zero on read");
    end
    p_req <= csr_req; p_ack <= csr_ack; p_we <= csr_we;
    p_addr <= csr_addr; p_wdata <= csr_wdata; p_wstrb <= csr_wstrb;
  end

  // Full checked transfer
  task automatic check_xfer(bit write, logic [CSR_ADDR_WIDTH-1:0] off, data_t wdata,
                            strb_t strb, logic [2:0] prot);
    data_t          rdata, exp_data;
    bit             err, exp_err, local_err, handshake;
    int unsigned    cycles, exp_cycles, hs_before;
    logic [WAW-1:0] w;
    string          tag;

    w         = off[CSR_ADDR_WIDTH-1:LSB];
    local_err = (ERR_UNALIGNED && (off % SW) != 0) ||
                (PRIV_ONLY && !prot[0]) || (SECURE_ONLY && prot[1]);
    handshake = !local_err && (w != WAW'(HANG_IDX));
    exp_err   = local_err || (w == WAW'(HANG_IDX)) || (w >= WAW'(ERR_BASE));
    exp_data  = (write || exp_err) ? '0 : ref_mem[w];

    hs_before = hs_count;
    apb.xfer(write, APB_BASE | 32'(off), wdata, strb, prot, rdata, err, cycles);

    if      (local_err)               exp_cycles = 2;
    else if (w == WAW'(HANG_IDX))     exp_cycles = TIMEOUT_CYCLES + 2;
    else                              exp_cycles = last_hs_lat + 2;

    tag = $sformatf("%s off=0x%0h prot=%b strb=%b", write ? "WR" : "RD", off, prot, strb);
    if (err !== exp_err)
      fail($sformatf("%s: PSLVERR=%0b expected %0b", tag, err, exp_err));
    if (!write && rdata !== exp_data)
      fail($sformatf("%s: PRDATA=0x%0h expected 0x%0h", tag, rdata, exp_data));
    if (cycles != exp_cycles)
      fail($sformatf("%s: %0d cycles, expected %0d", tag, cycles, exp_cycles));
    if (hs_count - hs_before != (handshake ? 1 : 0))
      fail($sformatf("%s: %0d CSR handshakes, expected %0d", tag,
                     hs_count - hs_before, handshake));

    // Reference model update
    if (write && !exp_err)
      for (int b = 0; b < SW; b++)
        if (!USE_PSTRB || strb[b]) ref_mem[w][8*b +: 8] = wdata[8*b +: 8];

    if (write) n_wr++; else n_rd++;
    if (exp_err) n_err++;
    if (local_err) n_local++;
    if (w == WAW'(HANG_IDX) && !local_err) n_tmo++;
    if (write && strb != '1 && strb != '0) n_partial++;
  endtask

  function automatic logic [CSR_ADDR_WIDTH-1:0] word_off(int unsigned idx);
    return CSR_ADDR_WIDTH'(idx << LSB);
  endfunction

  function automatic int unsigned rand_word(bit allow_err);
    int unsigned w;
    do w = $urandom_range(DEPTH - 1, 0);
    while (w == HANG_IDX || (!allow_err && w >= ERR_BASE));
    return w;
  endfunction

  // A protection value accepted by the bridge configuration
  function automatic logic [2:0] good_prot();
    logic [2:0] p = 3'($urandom);
    if (PRIV_ONLY)   p[0] = 1'b1;
    if (SECURE_ONLY) p[1] = 1'b0;
    return p;
  endfunction

  // ---------------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------------
  initial begin
    errors = 0;
    {n_rd, n_wr, n_err, n_tmo, n_local, n_partial} = '0;
    for (int i = 0; i < DEPTH; i++) begin
      mem[i]     = '0;
      ref_mem[i] = '0;
    end

    $display("==== tb_apb2csr: DW=%0d CSR_AW=%0d PSTRB=%0d UNALIGN_ERR=%0d PRIV=%0d SEC=%0d TMO=%0d ARST=%0d LAT<=%0d",
             DATA_WIDTH, CSR_ADDR_WIDTH, USE_PSTRB, ERR_UNALIGNED, PRIV_ONLY, SECURE_ONLY,
             TIMEOUT_CYCLES, ASYNC_RESET, MAX_LATENCY);

    if (TIMEOUT_CYCLES > 0 && MAX_LATENCY > TIMEOUT_CYCLES)
      $fatal(1, "config error: MAX_LATENCY (%0d) must be <= TIMEOUT_CYCLES (%0d)",
             MAX_LATENCY, TIMEOUT_CYCLES);

    apb.init();
    presetn = 1'b0;
    repeat (5) @(posedge pclk);
    // Outputs during / right after reset
    if (apb.pready !== 1'b0 || apb.pslverr !== 1'b0 || csr_req !== 1'b0)
      fail("bad output values during reset");
    presetn <= 1'b1;
    repeat (2) @(posedge pclk);

    // T1: write / read back every regular word (back-to-back, no idle)
    $display("T1: full address sweep");
    for (int i = 0; i < ERR_BASE; i++)
      if (i != HANG_IDX) check_xfer(1'b1, word_off(i), data_t'($urandom), '1, good_prot());
    for (int i = 0; i < ERR_BASE; i++)
      if (i != HANG_IDX) check_xfer(1'b0, word_off(i), '0, '0, good_prot());

    // T2: byte strobes (APB4 PSTRB)
    $display("T2: write strobes");
    for (int s = 0; s < (1 << SW); s++) begin
      automatic int unsigned w = rand_word(1'b0);
      check_xfer(1'b1, word_off(w), '1, '1, good_prot());
      check_xfer(1'b1, word_off(w), '0, strb_t'(s), good_prot());
      check_xfer(1'b0, word_off(w), '0, '0, good_prot());
    end

    // T3: slave error responses
    $display("T3: slave error region");
    for (int i = ERR_BASE; i < DEPTH; i++) begin
      check_xfer(1'b1, word_off(i), data_t'($urandom), '1, good_prot());
      check_xfer(1'b0, word_off(i), '0, '0, good_prot());
    end

    // T4: unaligned accesses
    if (SW > 1) begin
      $display("T4: unaligned accesses");
      for (int i = 0; i < 20; i++) begin
        automatic logic [CSR_ADDR_WIDTH-1:0] off = word_off(rand_word(1'b0)) | CSR_ADDR_WIDTH'($urandom_range(SW - 1, 1));
        check_xfer(1'($urandom), off, data_t'($urandom), '1, good_prot());
      end
    end

    // T5: PPROT filtering - all 8 combinations, read and write
    $display("T5: PPROT combinations");
    for (int p = 0; p < 8; p++) begin
      automatic int unsigned w = rand_word(1'b0);
      check_xfer(1'b1, word_off(w), data_t'($urandom), '1, 3'(p));
      check_xfer(1'b0, word_off(w), '0, '0, 3'(p));
    end

    // T6: timeout on a hung slave
    if (TIMEOUT_CYCLES > 0) begin
      $display("T6: CSR timeout");
      check_xfer(1'b0, word_off(HANG_IDX), '0, '0, good_prot());
      check_xfer(1'b1, word_off(HANG_IDX), data_t'($urandom), '1, good_prot());
      // Bus must be fully functional afterwards
      check_xfer(1'b0, word_off(0), '0, '0, good_prot());
    end

    // T7: constrained-random traffic with random idle gaps
    $display("T7: %0d random transfers", NUM_RANDOM);
    for (int n = 0; n < NUM_RANDOM; n++) begin
      automatic bit                        wr   = 1'($urandom);
      automatic logic [CSR_ADDR_WIDTH-1:0] off  = word_off(rand_word($urandom_range(9, 0) == 0));
      automatic logic [2:0]                prot = ($urandom_range(9, 0) == 0) ? 3'($urandom) : good_prot();
      if (SW > 1 && $urandom_range(19, 0) == 0) off |= CSR_ADDR_WIDTH'($urandom_range(SW - 1, 1));
      check_xfer(wr, off, data_t'($urandom), strb_t'($urandom), prot);
      repeat ($urandom_range(2, 0)) @(posedge pclk);
    end

    // T8: reset while a CSR request is outstanding
    $display("T8: %s reset during an outstanding transfer", ASYNC_RESET ? "async" : "sync");
    apb.psel    <= 1'b1;
    apb.penable <= 1'b0;
    apb.paddr   <= APB_BASE | 32'(word_off(HANG_IDX));
    apb.pwrite  <= 1'b0;
    apb.pstrb   <= '0;
    apb.pprot   <= good_prot();
    @(posedge pclk);
    apb.penable <= 1'b1;
    #2;
    if (csr_req !== 1'b1 || apb.pready !== 1'b0) fail("T8: transfer not outstanding before reset");
    presetn = 1'b0;
    if (ASYNC_RESET) #1;                     // asynchronous: cleared immediately
    else @(posedge pclk) #1;                 // synchronous: cleared at the next edge
    if (apb.pready !== 1'b0 || apb.pslverr !== 1'b0 || csr_req !== 1'b0)
      fail("T8: outputs not cleared by reset");
    apb.init();
    repeat (3) @(posedge pclk);
    presetn <= 1'b1;
    @(posedge pclk);
    check_xfer(1'b1, word_off(1), data_t'($urandom), '1, good_prot());
    check_xfer(1'b0, word_off(1), '0, '0, good_prot());

    // T9: final read-back of the whole memory
    $display("T9: final consistency sweep");
    for (int i = 0; i < ERR_BASE; i++)
      if (i != HANG_IDX) check_xfer(1'b0, word_off(i), '0, '0, good_prot());

    repeat (5) @(posedge pclk);
    $display("---- stats: reads=%0d writes=%0d errors_resp=%0d (local=%0d timeout=%0d) partial_strb=%0d handshakes=%0d",
             n_rd, n_wr, n_err, n_local, n_tmo, n_partial, hs_count);
    if (errors == 0) $display("TEST PASSED");
    else             $display("TEST FAILED: %0d error(s)", errors);
    $finish;
  end

  // Global watchdog
  initial begin
    #50ms;
    $fatal(1, "global timeout");
  end

endmodule : tb_apb2csr
