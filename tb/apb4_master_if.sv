// =============================================================================
// apb4_master_if.sv - AMBA APB4 master BFM (interface with transfer tasks)
// -----------------------------------------------------------------------------
// All tasks must be called right after a rising edge of pclk (i.e. after an
// @(posedge pclk)). Consecutive calls produce back-to-back transfers with no
// idle cycle in between.
// =============================================================================
`timescale 1ns/1ps

interface apb4_master_if #(
  parameter int unsigned ADDR_WIDTH = 32,
  parameter int unsigned DATA_WIDTH = 32
) (
  input logic pclk,
  input logic presetn
);
  localparam int unsigned STRB_WIDTH = DATA_WIDTH / 8;

  logic                  psel;
  logic                  penable;
  logic [ADDR_WIDTH-1:0] paddr;
  logic                  pwrite;
  logic [DATA_WIDTH-1:0] pwdata;
  logic [STRB_WIDTH-1:0] pstrb;
  logic [2:0]            pprot;
  logic                  pready;
  logic [DATA_WIDTH-1:0] prdata;
  logic                  pslverr;

  int unsigned max_wait = 1000;   // watchdog (cycles) per transfer

  task automatic init();
    psel    = 1'b0;
    penable = 1'b0;
    paddr   = '0;
    pwrite  = 1'b0;
    pwdata  = '0;
    pstrb   = '0;
    pprot   = 3'b000;
  endtask

  // Generic APB4 transfer. 'cycles' = number of clock cycles of the transfer
  // (SETUP + ACCESS), i.e. 2 for a zero-wait-state transfer.
  task automatic xfer(input  bit                    write,
                      input  logic [ADDR_WIDTH-1:0] addr,
                      input  logic [DATA_WIDTH-1:0] wdata,
                      input  logic [STRB_WIDTH-1:0] strb,
                      input  logic [2:0]            prot,
                      output logic [DATA_WIDTH-1:0] rdata,
                      output bit                    err,
                      output int unsigned           cycles);
    // SETUP phase
    psel    <= 1'b1;
    penable <= 1'b0;
    paddr   <= addr;
    pwrite  <= write;
    pwdata  <= write ? wdata : DATA_WIDTH'($urandom);  // PWDATA don't care on read
    pstrb   <= write ? strb  : '0;                     // APB4: PSTRB low on read
    pprot   <= prot;
    @(posedge pclk);
    // ACCESS phase
    penable <= 1'b1;
    cycles  = 1;
    do begin
      @(posedge pclk);
      cycles++;
      if (cycles > max_wait) begin
        $fatal(1, "[APB4 BFM] PREADY timeout at addr 0x%0h", addr);
      end
    end while (pready !== 1'b1);
    rdata = prdata;
    err   = (pslverr === 1'b1);
    // Back to IDLE; scramble the bus so stale values are never relied upon
    psel    <= 1'b0;
    penable <= 1'b0;
    paddr   <= ADDR_WIDTH'($urandom);
    pwrite  <= 1'($urandom);
    pwdata  <= DATA_WIDTH'($urandom);
    pstrb   <= '0;
  endtask

  task automatic write(input  logic [ADDR_WIDTH-1:0] addr,
                       input  logic [DATA_WIDTH-1:0] data,
                       output bit                    err,
                       input  logic [STRB_WIDTH-1:0] strb = '1,
                       input  logic [2:0]            prot = 3'b001);
    logic [DATA_WIDTH-1:0] unused_rdata;
    int unsigned           unused_cycles;
    xfer(1'b1, addr, data, strb, prot, unused_rdata, err, unused_cycles);
  endtask

  task automatic read(input  logic [ADDR_WIDTH-1:0] addr,
                      output logic [DATA_WIDTH-1:0] data,
                      output bit                    err,
                      input  logic [2:0]            prot = 3'b001);
    int unsigned unused_cycles;
    xfer(1'b0, addr, '0, '0, prot, data, err, unused_cycles);
  endtask

endinterface : apb4_master_if
