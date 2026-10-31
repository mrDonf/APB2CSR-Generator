// =============================================================================
// apb2csr.sv
// -----------------------------------------------------------------------------
// Parameterizable AMBA APB4 slave to generic CSR bus bridge.
// Compliant with AMBA APB Protocol Specification v2.0 (ARM IHI 0024C, APB4).
//
// Features
//   * APB4 slave: PSTRB write strobes, PPROT protection, PREADY wait states,
//     PSLVERR error response. (USE_PSTRB = 0 gives APB3 behaviour.)
//   * PSLVERR is driven only in the last ACCESS cycle (PSEL & PENABLE &
//     PREADY), PRDATA is 0 on errored reads; a write that errors locally
//     (unaligned / protection) never reaches the CSR slave.
//   * Data width 8 / 16 / 32 bit.
//   * All APB outputs (PREADY, PRDATA, PSLVERR) are registered, yet zero-wait
//     state transfers are still achieved: the CSR request is launched in the
//     APB SETUP phase, the response is captured and returned in ACCESS phase.
//   * Simple valid/ready style CSR bus: single-cycle (combinational ack) and
//     multi-cycle (wait state) CSR slaves are both supported.
//   * Optional response timeout -> PSLVERR (protects the APB bus from a hung
//     CSR slave).
//   * Optional PSLVERR on unaligned address, unprivileged or non-secure access.
//   * Asynchronous or synchronous active-low reset (ASYNC_RESET).
//   * Built-in SVA protocol checks (excluded when SYNTHESIS is defined).
//
// CSR bus protocol (bridge is the master)
//   * csr_req is asserted together with stable csr_we/addr/wdata/wstrb/prot
//     and is held until csr_ack is sampled high (or a timeout occurs).
//   * The slave answers with csr_ack = 1 for one cycle, together with
//     csr_rdata (reads) and csr_err. csr_ack may be combinational on csr_req
//     (zero latency) or arrive any number of cycles later.
//   * csr_ack / csr_rdata / csr_err are only sampled while csr_req = 1.
//   * Exactly one handshake (csr_req & csr_ack) is generated per forwarded APB
//     transfer, so read/write side effects (read-to-clear, FIFO pop, ...) fire
//     exactly once.
// =============================================================================

module apb2csr #(
  parameter int unsigned APB_ADDR_WIDTH = 32,   // PADDR width
  parameter int unsigned DATA_WIDTH     = 32,   // 8, 16 or 32
  parameter int unsigned CSR_ADDR_WIDTH = 12,   // CSR byte-address width (<= APB_ADDR_WIDTH)
  parameter bit          USE_PSTRB      = 1'b1, // 1: APB4 PSTRB honoured (default), 0: APB3 (all lanes written)
  parameter bit          ERR_UNALIGNED  = 1'b1, // 1: PSLVERR on address not aligned to DATA_WIDTH
  parameter bit          PRIV_ONLY      = 1'b0, // 1: PSLVERR on unprivileged access (PPROT[0] = 0)
  parameter bit          SECURE_ONLY    = 1'b0, // 1: PSLVERR on non-secure access  (PPROT[1] = 1)
  parameter int unsigned TIMEOUT_CYCLES = 0,    // 0: disabled, N: PSLVERR if no csr_ack within N wait cycles
  parameter bit          ASYNC_RESET    = 1'b1  // 1: PRESETn asynchronous (default), 0: synchronous
) (
  input  logic                      pclk,
  input  logic                      presetn,

  // APB slave interface
  input  logic                      psel,
  input  logic                      penable,
  input  logic [APB_ADDR_WIDTH-1:0] paddr,
  input  logic                      pwrite,
  input  logic [DATA_WIDTH-1:0]     pwdata,
  input  logic [DATA_WIDTH/8-1:0]   pstrb,
  input  logic [2:0]                pprot,
  output logic                      pready,
  output logic [DATA_WIDTH-1:0]     prdata,
  output logic                      pslverr,

  // CSR master interface
  output logic                      csr_req,
  output logic                      csr_we,
  output logic [CSR_ADDR_WIDTH-1:0] csr_addr,
  output logic [DATA_WIDTH-1:0]     csr_wdata,
  output logic [DATA_WIDTH/8-1:0]   csr_wstrb,
  output logic [2:0]                csr_prot,
  input  logic                      csr_ack,
  input  logic [DATA_WIDTH-1:0]     csr_rdata,
  input  logic                      csr_err
);

  localparam int unsigned STRB_WIDTH = DATA_WIDTH / 8;
  localparam int unsigned ADDR_LSB   = (STRB_WIDTH > 1) ? $clog2(STRB_WIDTH) : 0;

  typedef enum logic [1:0] {
    S_IDLE = 2'b00,   // waiting for an APB SETUP phase
    S_WAIT = 2'b01,   // CSR request outstanding, PREADY low
    S_RESP = 2'b10    // response captured, PREADY high (last ACCESS cycle)
  } state_e;

  state_e                  state_q, state_d;
  logic                    rsp_load;
  logic                    rsp_err_d;
  logic [DATA_WIDTH-1:0]   rsp_data_d;
  logic                    rsp_err_q;
  logic [DATA_WIDTH-1:0]   rsp_data_q;

  logic                    setup;
  logic                    unaligned;
  logic                    prot_err;
  logic                    local_err;
  logic                    timeout;
  logic [DATA_WIDTH-1:0]   csr_rdata_masked;

  // ---------------------------------------------------------------------------
  // Request decode / local error checks
  // ---------------------------------------------------------------------------
  assign setup = psel & ~penable;

  if ((ADDR_LSB > 0) && ERR_UNALIGNED) begin : g_align_chk
    assign unaligned = |paddr[ADDR_LSB-1:0];
  end else begin : g_no_align_chk
    assign unaligned = 1'b0;
  end

  // PADDR bits above CSR_ADDR_WIDTH select the peripheral; that decode is done
  // by the APB interconnect (PSEL), so they are intentionally unused here.
  if (APB_ADDR_WIDTH > CSR_ADDR_WIDTH) begin : g_paddr_hi
    logic [APB_ADDR_WIDTH-CSR_ADDR_WIDTH-1:0] unused_paddr_hi;
    assign unused_paddr_hi = paddr[APB_ADDR_WIDTH-1:CSR_ADDR_WIDTH];
  end

  assign prot_err  = (PRIV_ONLY   & ~pprot[0])
                   | (SECURE_ONLY &  pprot[1]);
  assign local_err = unaligned | prot_err;

  // ---------------------------------------------------------------------------
  // CSR request. APB guarantees PADDR/PWRITE/PWDATA/PSTRB/PPROT are stable from
  // SETUP until the transfer completes, so they are forwarded without flops.
  // ---------------------------------------------------------------------------
  assign csr_req   = ((state_q == S_IDLE) & setup & ~local_err)
                   |  (state_q == S_WAIT);
  assign csr_we    = pwrite;
  assign csr_addr  = paddr[CSR_ADDR_WIDTH-1:0];
  assign csr_wdata = pwdata;
  assign csr_wstrb = ~pwrite   ? '0    :
                     USE_PSTRB ? pstrb : '1;
  assign csr_prot  = pprot;

  // Read data is forced to zero for writes and error responses
  assign csr_rdata_masked = (pwrite | csr_err) ? '0 : csr_rdata;

  // ---------------------------------------------------------------------------
  // Optional timeout counter
  // ---------------------------------------------------------------------------
  if (TIMEOUT_CYCLES > 0) begin : g_timeout
    localparam int unsigned TW = (TIMEOUT_CYCLES > 1) ? $clog2(TIMEOUT_CYCLES) : 1;
    logic [TW-1:0] tmo_cnt_q, tmo_cnt_d;

    assign tmo_cnt_d = (state_q == S_WAIT) ? tmo_cnt_q + 1'b1 : '0;

    if (ASYNC_RESET) begin : g_arst
      always_ff @(posedge pclk or negedge presetn) begin
        if (!presetn) tmo_cnt_q <= '0;
        else          tmo_cnt_q <= tmo_cnt_d;
      end
    end else begin : g_srst
      always_ff @(posedge pclk) begin
        if (!presetn) tmo_cnt_q <= '0;
        else          tmo_cnt_q <= tmo_cnt_d;
      end
    end

    assign timeout = (state_q == S_WAIT) && (tmo_cnt_q == TW'(TIMEOUT_CYCLES - 1));
  end else begin : g_no_timeout
    assign timeout = 1'b0;
  end

  // ---------------------------------------------------------------------------
  // Control FSM
  // ---------------------------------------------------------------------------
  always_comb begin
    state_d    = state_q;
    rsp_load   = 1'b0;
    rsp_err_d  = 1'b0;
    rsp_data_d = '0;

    unique case (state_q)
      S_IDLE: begin
        if (setup) begin
          if (local_err) begin
            rsp_load  = 1'b1;
            rsp_err_d = 1'b1;
            state_d   = S_RESP;
          end else if (csr_ack) begin
            rsp_load   = 1'b1;
            rsp_err_d  = csr_err;
            rsp_data_d = csr_rdata_masked;
            state_d    = S_RESP;
          end else begin
            state_d    = S_WAIT;
          end
        end
      end

      S_WAIT: begin
        if (csr_ack) begin
          rsp_load   = 1'b1;
          rsp_err_d  = csr_err;
          rsp_data_d = csr_rdata_masked;
          state_d    = S_RESP;
        end else if (timeout) begin
          rsp_load   = 1'b1;
          rsp_err_d  = 1'b1;
          state_d    = S_RESP;
        end
      end

      S_RESP: begin
        // PREADY is high: the transfer completes in this ACCESS cycle
        if (psel & penable) state_d = S_IDLE;
      end

      default: state_d = S_IDLE;
    endcase
  end

  // ---------------------------------------------------------------------------
  // Registers (reset style selected by ASYNC_RESET)
  // ---------------------------------------------------------------------------
  logic                  rsp_err_n;
  logic [DATA_WIDTH-1:0] rsp_data_n;

  assign rsp_err_n  = rsp_load ? rsp_err_d  : rsp_err_q;
  assign rsp_data_n = rsp_load ? rsp_data_d : rsp_data_q;

  if (ASYNC_RESET) begin : g_arst
    always_ff @(posedge pclk or negedge presetn) begin
      if (!presetn) begin
        state_q    <= S_IDLE;
        rsp_err_q  <= 1'b0;
        rsp_data_q <= '0;
      end else begin
        state_q    <= state_d;
        rsp_err_q  <= rsp_err_n;
        rsp_data_q <= rsp_data_n;
      end
    end
  end else begin : g_srst
    always_ff @(posedge pclk) begin
      if (!presetn) begin
        state_q    <= S_IDLE;
        rsp_err_q  <= 1'b0;
        rsp_data_q <= '0;
      end else begin
        state_q    <= state_d;
        rsp_err_q  <= rsp_err_n;
        rsp_data_q <= rsp_data_n;
      end
    end
  end

  assign pready  = (state_q == S_RESP);
  assign pslverr = (state_q == S_RESP) & rsp_err_q;
  assign prdata  = rsp_data_q;

  // ---------------------------------------------------------------------------
  // Assertions (simulation only)
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin
    assert (DATA_WIDTH == 8 || DATA_WIDTH == 16 || DATA_WIDTH == 32)
      else $fatal(1, "apb2csr: DATA_WIDTH must be 8, 16 or 32 (got %0d)", DATA_WIDTH);
    assert (CSR_ADDR_WIDTH > ADDR_LSB && CSR_ADDR_WIDTH <= APB_ADDR_WIDTH)
      else $fatal(1, "apb2csr: CSR_ADDR_WIDTH (%0d) must be in (%0d, APB_ADDR_WIDTH=%0d]",
                  CSR_ADDR_WIDTH, ADDR_LSB, APB_ADDR_WIDTH);
  end

  // APB protocol: PENABLE only while selected
  a_apb_penable_psel: assert property (@(posedge pclk) disable iff (!presetn)
    penable |-> psel)
    else $error("apb2csr: PENABLE asserted without PSEL");

  // APB protocol: SETUP is always followed by ACCESS
  a_apb_setup_access: assert property (@(posedge pclk) disable iff (!presetn)
    (psel && !penable) |=> (psel && penable))
    else $error("apb2csr: SETUP phase not followed by ACCESS phase");

  // APB protocol: control/address/data stable until the transfer completes
  a_apb_stable: assert property (@(posedge pclk) disable iff (!presetn)
    (psel && !(penable && pready)) |=>
      ($stable(paddr) && $stable(pwrite) && $stable(pprot) &&
       (!pwrite || ($stable(pwdata) && $stable(pstrb)))))
    else $error("apb2csr: APB signals changed during a transfer");

  // APB4: master must drive all write strobes LOW during a read transfer
  a_apb4_pstrb_read: assert property (@(posedge pclk) disable iff (!presetn)
    (psel && !pwrite) |-> (pstrb == '0))
    else $error("apb2csr: PSTRB not zero during a read transfer (APB4)");

  // APB: no X/Z on control signals; no X/Z on address/control while selected
  a_apb_ctrl_known: assert property (@(posedge pclk) disable iff (!presetn)
    !$isunknown({psel, penable}))
    else $error("apb2csr: X/Z on PSEL/PENABLE");

  a_apb_addr_known: assert property (@(posedge pclk) disable iff (!presetn)
    psel |-> !$isunknown({paddr, pwrite, pprot}))
    else $error("apb2csr: X/Z on PADDR/PWRITE/PPROT while PSEL is high");

  a_apb_wdata_known: assert property (@(posedge pclk) disable iff (!presetn)
    (psel && pwrite) |-> !$isunknown({pwdata, pstrb}))
    else $error("apb2csr: X/Z on PWDATA/PSTRB during a write transfer");

  // APB protocol: an ACCESS phase must be preceded by a SETUP phase
  a_apb_access_after_setup: assert property (@(posedge pclk) disable iff (!presetn)
    (psel && penable && !pready) |-> (state_q != S_IDLE))
    else $error("apb2csr: ACCESS phase without preceding SETUP phase");

  // Bridge: PSLVERR only together with PREADY
  a_pslverr_pready: assert property (@(posedge pclk) disable iff (!presetn)
    pslverr |-> pready);

  // Bridge: CSR request held until acknowledged (or timed out)
  a_csr_req_hold: assert property (@(posedge pclk) disable iff (!presetn)
    (csr_req && !csr_ack && !timeout) |=> csr_req);
`endif

endmodule
