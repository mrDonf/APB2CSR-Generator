# apb2csr — IP Specification

| | |
|---|---|
| **IP** | `apb2csr` — AMBA APB4 slave to CSR bus bridge (+ generated register file) |
| **Revision** | 1.2 |
| **Bus standard** | AMBA APB Protocol Specification v2.0 (ARM IHI 0024C), APB4 |
| **RTL** | `rtl/apb2csr.sv` (SystemVerilog-2012, synthesizable, single module) |
| **Generator** | `tools/csrgen.py` v1.1.0 |

This document specifies the **features and behaviour** of the IP. How to generate a register block and integrate it is described in the [README](../README.md).

---

## Contents

1. [Overview](#1-overview)
2. [Features](#2-features)
3. [Block diagram](#3-block-diagram)
4. [Parameters](#4-parameters)
5. [Signal interface](#5-signal-interface)
6. [Functional description](#6-functional-description)
7. [CSR bus protocol](#7-csr-bus-protocol)
8. [Timing](#8-timing)
9. [Generated register file](#9-generated-register-file)
10. [Assertions](#10-assertions)
11. [Performance, resources and integration guidelines](#11-performance-resources-and-integration-guidelines)
12. [Verification](#12-verification)
13. [Limitations and extensions](#13-limitations-and-extensions)
14. [Revision history](#14-revision-history)

---

## 1. Overview

Every peripheral in an SoC needs a control/status register (CSR) block that the CPU uses, over APB, to configure it and read its state. `apb2csr` splits this into two layers:

1. **`apb2csr` (bridge)**: handles the whole APB4 protocol (SETUP/ACCESS phases, wait states, `PSLVERR`, `PSTRB`, `PPROT`) and turns every transfer into a simple request on an internal valid/ready style **CSR bus**.
2. **Register file**: only needs to understand the CSR bus. It is either **generated** by `csrgen.py` from a JSON spec or written by hand.

The APB4 protocol logic is therefore written and verified **once**; each project only changes the register map.

## 2. Features

**Protocol**
- Full APB4 slave: `PSEL`, `PENABLE`, `PADDR`, `PWRITE`, `PWDATA`, `PSTRB`, `PPROT`, `PREADY`, `PRDATA`, `PSLVERR`.
- 8, 16 or 32-bit data; parameterizable `PADDR` width and CSR address window.
- APB3 compatibility mode (`USE_PSTRB = 0`: `PSTRB` ignored, all byte lanes written).

**Performance**
- **Zero wait states**: 2 cycles per transfer (the APB minimum) when the slave answers immediately.
- **APB outputs depend only on internal flip-flops**: `PRDATA` comes straight from a flop and `PREADY`/`PSLVERR` are decoded from state flops. There is no combinational path from APB inputs to APB outputs, which eases timing closure in the interconnect.
- Multi-cycle slaves supported (unlimited wait states); back-to-back transfers.

**Safety and protection**
- `PSLVERR` on unaligned addresses (optional).
- `PSLVERR` on unprivileged (`PPROT[0]=0`) or non-secure (`PPROT[1]=1`) accesses (optional).
- Timeout for a hung slave — the APB bus is always released (optional).
- A transfer rejected by the bridge **never** reaches the register file, so it has no side effects.
- `PRDATA = 0` for every errored transfer and every write: no data leakage.

**Built for reuse**
- Asynchronous or synchronous active-low reset (`ASYNC_RESET`).
- Exactly one CSR handshake per forwarded transfer, so registers with read/write side effects (read-to-clear, FIFO pop/push) are safe.
- Embedded APB4 and CSR protocol SVA (removed when `SYNTHESIS` is defined).
- Lint clean under Questa (`-lint -pedanticerrors`) and Verilator (`-Wall`) across the whole parameter matrix.

**Register generator (`csrgen.py`)**
- 10 access types: `RW`, `RO`, `WO`, `W1C`, `W1S`, `W0C`, `W0S`, `W0T`, `RC`, `W1P`, plus constants (`const`), hardware write (`hw_write`) and access strobes.
- Generates RTL, APB4 wrapper, SV package, C header and Markdown documentation from a single source.
- Strict spec validation (overlapping bits, duplicate offsets, oversized reset values, misspelled keys, ...).

## 3. Block diagram

```
                         apb2csr
          +--------------------------------------------------+
          |                                                  |
 PSEL ───►|──┐  setup = PSEL & ~PENABLE                      |
 PENABLE─►|  ├──► local error check ──┐ (unaligned, PPROT)   |
 PADDR ──►|──┤                        ▼                      |
 PPROT ──►|  │                 +-------------+   csr_req     |
          |  │                 |  FSM        |──────────────►|── csr_req
          |  │                 | IDLE/WAIT/  |               |
          |  │                 |    RESP     |◄──────────────|── csr_ack
          |  │                 +------+------+   timeout     |
          |  │                        │   ▲ ┌──────────┐     |
          |  │                        │   └─┤ timeout  │     |
          |  │                        │     │ counter  │     |
          |  │                        ▼     └──────────┘     |
          |  │                 +-------------+               |
 PREADY ◄─|──┼─────────────────| rsp_err_q   |◄── csr_err ───|── csr_err
 PSLVERR◄─|──┼─────────────────| rsp_data_q  |◄── mask ◄─────|── csr_rdata
 PRDATA ◄─|──┼─────────────────| (flops)     |   (0 on wr/err)
          |  │                 +-------------+               |
          |  └── PADDR[CSR_AW-1:0], PWRITE, PWDATA, ─────────►|── csr_addr/we/wdata
          |      PSTRB (masked), PPROT  (pass-through) ──────►|── csr_wstrb/prot
          +--------------------------------------------------+
```

The request path (`csr_addr`, `csr_we`, `csr_wdata`, `csr_wstrb`, `csr_prot`) is taken directly from APB without flops. This is safe because APB4 guarantees these signals are stable from SETUP until the transfer completes. The response path is always registered.

## 4. Parameters

| Parameter | Type | Default | Legal values | Description |
|---|---|---|---|---|
| `APB_ADDR_WIDTH` | int | 32 | ≥ `CSR_ADDR_WIDTH` | `PADDR` width |
| `DATA_WIDTH` | int | 32 | 8, 16, 32 | `PWDATA`/`PRDATA` and CSR data width |
| `CSR_ADDR_WIDTH` | int | 12 | > log2(`DATA_WIDTH`/8), ≤ `APB_ADDR_WIDTH` | CSR byte-address width = `PADDR[CSR_ADDR_WIDTH-1:0]` |
| `USE_PSTRB` | bit | 1 | 0, 1 | 1: APB4, `csr_wstrb = PSTRB`; 0: `csr_wstrb` all ones on writes |
| `ERR_UNALIGNED` | bit | 1 | 0, 1 | 1: `PSLVERR` if `PADDR[log2(DW/8)-1:0] ≠ 0`; 0: forwarded, the slave ignores the low bits |
| `PRIV_ONLY` | bit | 0 | 0, 1 | 1: `PSLVERR` if `PPROT[0] = 0` (unprivileged) |
| `SECURE_ONLY` | bit | 0 | 0, 1 | 1: `PSLVERR` if `PPROT[1] = 1` (non-secure) |
| `TIMEOUT_CYCLES` | int | 0 | 0 … 2³¹ | 0: disabled; N: `PSLVERR` if no `csr_ack` after N wait cycles |
| `ASYNC_RESET` | bit | 1 | 0, 1 | 1: `PRESETn` asynchronous; 0: synchronous |

An illegal `DATA_WIDTH` or `CSR_ADDR_WIDTH` stops simulation with `$fatal` at time zero.

## 5. Signal interface

### 5.1 Clock and reset

| Signal | Dir | Width | Description |
|---|---|---|---|
| `pclk` | in | 1 | APB clock; all flops are rising-edge triggered |
| `presetn` | in | 1 | Active-low reset; asynchronous or synchronous per `ASYNC_RESET` |

### 5.2 APB4 slave

| Signal | Dir | Width | Description |
|---|---|---|---|
| `psel` | in | 1 | Slave select (from the interconnect address decoder) |
| `penable` | in | 1 | 0: SETUP phase, 1: ACCESS phase |
| `paddr` | in | `APB_ADDR_WIDTH` | Byte address; only `[CSR_ADDR_WIDTH-1:0]` is used |
| `pwrite` | in | 1 | 1: write, 0: read |
| `pwdata` | in | `DATA_WIDTH` | Write data |
| `pstrb` | in | `DATA_WIDTH/8` | Write byte strobes (must be 0 on reads, per APB4) |
| `pprot` | in | 3 | `[0]` privileged, `[1]` non-secure, `[2]` instruction |
| `pready` | out | 1 | Transfer completes in this ACCESS cycle (decoded from state flops) |
| `prdata` | out | `DATA_WIDTH` | Read data, valid when `pready=1` on a successful read (flop output) |
| `pslverr` | out | 1 | Transfer error; only 1 when `pready=1` (AND of two flops) |

### 5.3 CSR master

| Signal | Dir | Width | Description |
|---|---|---|---|
| `csr_req` | out | 1 | Request; held at 1 until `csr_ack` (or timeout) |
| `csr_we` | out | 1 | 1: write, 0: read |
| `csr_addr` | out | `CSR_ADDR_WIDTH` | Byte address (= `paddr[CSR_ADDR_WIDTH-1:0]`) |
| `csr_wdata` | out | `DATA_WIDTH` | Write data |
| `csr_wstrb` | out | `DATA_WIDTH/8` | Byte strobes; always 0 on reads |
| `csr_prot` | out | 3 | `pprot` passed through, for finer-grained checks in the slave |
| `csr_ack` | in | 1 | Slave completes the request (one cycle) |
| `csr_rdata` | in | `DATA_WIDTH` | Read data, sampled when `csr_ack=1` |
| `csr_err` | in | 1 | Slave error, sampled when `csr_ack=1` |

## 6. Functional description

### 6.1 Control FSM

| State | Meaning | `pready` | `csr_req` |
|---|---|---|---|
| `S_IDLE` | Waiting for a SETUP phase | 0 | = `setup & ~local_err` |
| `S_WAIT` | Request outstanding, waiting for the slave | 0 | 1 |
| `S_RESP` | Response captured; last ACCESS cycle | 1 | 0 |

| From | Condition | To | Action |
|---|---|---|---|
| `S_IDLE` | SETUP & local error | `S_RESP` | capture `err=1`, `data=0` (no request issued) |
| `S_IDLE` | SETUP & `csr_ack` | `S_RESP` | capture `csr_err`, masked `csr_rdata` |
| `S_IDLE` | SETUP & `~csr_ack` | `S_WAIT` | – |
| `S_WAIT` | `csr_ack` | `S_RESP` | capture `csr_err`, masked `csr_rdata` |
| `S_WAIT` | timeout | `S_RESP` | capture `err=1`, `data=0`; `csr_req` drops |
| `S_RESP` | `PSEL & PENABLE` | `S_IDLE` | transfer completes |
| any | reset | `S_IDLE` | response cleared |

### 6.2 Request issued in the SETUP phase

The key design choice: the request is issued **during the SETUP phase** (`PSEL=1, PENABLE=0`), one cycle earlier than the usual approach of waiting for ACCESS. If the slave answers in the same cycle, the response is captured in flops at the end of SETUP and presented in the ACCESS phase with `PREADY=1`. The IP therefore has **registered outputs** and **zero wait states** at the same time.

Performing the write during SETUP is legal because an APB master cannot abort a started transfer: every SETUP is followed by ACCESS.

### 6.3 Response capture

- `rsp_data_q ← (PWRITE | csr_err) ? 0 : csr_rdata`, `rsp_err_q ← csr_err`, captured in the `csr_ack = 1` cycle.
- `PRDATA` holds the last read value until the next transfer; it is only meaningful when `PREADY=1`.
- `PSLVERR = (state = S_RESP) & rsp_err_q`, so it is 0 in every other cycle (as recommended by APB4).

### 6.4 Byte strobes (`PSTRB`)

| Condition | `csr_wstrb` |
|---|---|
| Read (`PWRITE=0`) | `'0` |
| Write, `USE_PSTRB=1` | `PSTRB` |
| Write, `USE_PSTRB=0` | `'1` (all byte lanes) |

A write with `PSTRB = 0` is legal: it is forwarded but no byte is modified.

### 6.5 Alignment check

With `ERR_UNALIGNED=1` and `DATA_WIDTH > 8`, `PADDR[log2(DATA_WIDTH/8)-1:0]` must be 0; otherwise the bridge returns `PSLVERR` without issuing a request. With `ERR_UNALIGNED=0` the transfer is forwarded with the original address and the generated register file ignores the low bits (the word containing the address is accessed).

### 6.6 `PPROT` protection

| `PRIV_ONLY` | `SECURE_ONLY` | Rejected when |
|---|---|---|
| 0 | 0 | never |
| 1 | 0 | `PPROT[0] = 0` |
| 0 | 1 | `PPROT[1] = 1` |
| 1 | 1 | `PPROT[0] = 0` **or** `PPROT[1] = 1` |

The check applies to both reads and writes. For finer-grained policies (e.g. protecting only some registers), the slave can use `csr_prot` and return `csr_err`.

### 6.7 Timeout

With `TIMEOUT_CYCLES = N > 0`, a `max(1, ⌈log2 N⌉)`-bit counter counts the cycles spent in `S_WAIT`. The slave has **N + 1 cycles** of `csr_req` (the SETUP cycle + N wait cycles) to return `csr_ack`. After that the bridge drops `csr_req` and returns `PSLVERR` with `PRDATA = 0`; the transfer then lasts exactly **N + 2 cycles**. If `csr_ack` and the timeout coincide, `csr_ack` wins.

After a timeout the slave is considered broken and **must not** return `csr_ack` for the old request once `csr_req` has dropped (see §7).

### 6.8 Reset

| Signal / state | Reset value |
|---|---|
| FSM | `S_IDLE` |
| `pready`, `pslverr` | 0 |
| `prdata` | 0 |
| `csr_req` | 0, **provided `PSEL = 0`** (`csr_req` is a combinational function of `PSEL`/`PENABLE` in `S_IDLE`; the APB master must hold `PSEL` low during reset) |
| Timeout counter | 0 |

With `ASYNC_RESET=1` the outputs return to their reset values **immediately** when `presetn` falls, even with a request outstanding (verified). With `ASYNC_RESET=0` this happens at the next clock edge.

### 6.9 Error handling matrix

| Case | `PSLVERR` | Request reaches slave? | `PRDATA` | Transfer length (cycles) |
|---|---|---|---|---|
| Success | 0 | Yes (one handshake) | data (read) / 0 (write) | 2 + slave latency |
| Unaligned (`ERR_UNALIGNED=1`) | 1 | **No** | 0 | 2 |
| `PPROT` violation | 1 | **No** | 0 | 2 |
| Slave returns `csr_err` | 1 | Yes | 0 | 2 + slave latency |
| Timeout | 1 | Yes (aborted, no handshake) | 0 | `TIMEOUT_CYCLES` + 2 |

APB4 allows the register state to change or not when a write errors. In `apb2csr`, local errors (alignment, `PPROT`) **never** change anything; slave-reported errors depend on the slave. The generated register file does not write to unmapped addresses.

## 7. CSR bus protocol

The CSR bus is a request/acknowledge protocol synchronous to `pclk`. The bridge is the master; the register file (or a custom slave) is the slave.

**Master rules (guaranteed by the bridge):**
1. `csr_req=1` comes with `csr_we`, `csr_addr`, `csr_wdata`, `csr_wstrb`, `csr_prot` **stable** until the `csr_ack=1` cycle.
2. `csr_req` only drops before an acknowledge on timeout or reset.
3. Every forwarded APB transfer produces **exactly one** `csr_req & csr_ack` cycle.
4. `csr_wstrb = 0` when `csr_we = 0`.

**Slave rules (must be followed by slave implementers):**
1. `csr_ack`, `csr_rdata` and `csr_err` are only meaningful while `csr_req=1`; the bridge ignores them otherwise.
2. Return `csr_ack=1` for **exactly one cycle** per request — in the first cycle (`csr_ack` combinational from `csr_req`) or after any delay.
3. Perform side effects (write, read-to-clear, pop) only in the `csr_req & csr_ack` cycle.
4. If `csr_req` drops before the acknowledge (timeout), abort the request and do not acknowledge it.

**Example: one-cycle-latency slave** (registers the response to break a long timing path):

```systemverilog
logic ack_q;
always_ff @(posedge pclk or negedge presetn)
  if (!presetn) ack_q <= 1'b0;
  else          ack_q <= csr_req & ~ack_q;     // ack one cycle after the request
assign csr_ack = ack_q;                        // csr_req is still 1 in this cycle
// csr_rdata / csr_err must be valid in the csr_ack = 1 cycle; side effects on csr_req & csr_ack
```

## 8. Timing

Each column is one clock cycle. A value is the stable value of the signal during that cycle, sampled at the rising edge that ends it.

### 8.1 Zero-wait read (slave acknowledges immediately)

| Cycle | 1 | 2 | 3 |
|---|---|---|---|
| APB phase | SETUP | ACCESS | IDLE |
| `PSEL` / `PENABLE` | 1 / 0 | 1 / 1 | 0 / 0 |
| `PADDR`, `PWRITE` | A, 0 | A, 0 | – |
| `state_q` | IDLE | RESP | IDLE |
| `csr_req` / `csr_ack` | **1 / 1** | 0 / 0 | 0 / 0 |
| `csr_rdata` | D | – | – |
| `PREADY` | 0 | **1** | 0 |
| `PRDATA` | – | **D** | D (held) |
| `PSLVERR` | 0 | 0 | 0 |

The transfer takes 2 cycles; the next transfer may start its SETUP in cycle 3 (back-to-back).

### 8.2 Write, slave latency of 2 cycles

| Cycle | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| APB phase | SETUP | ACCESS | ACCESS | ACCESS |
| `state_q` | IDLE | WAIT | WAIT | RESP |
| `csr_req` | 1 | 1 | 1 | 0 |
| `csr_ack` | 0 | 0 | **1** | 0 |
| `PREADY` | 0 | 0 | 0 | **1** |

In general, a slave latency L (acknowledge in cycle L+1 counting from SETUP) gives a transfer of **L + 2 cycles**.

### 8.3 Timeout (`TIMEOUT_CYCLES = 3`, slave never answers)

| Cycle | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| APB phase | SETUP | ACCESS | ACCESS | ACCESS | ACCESS |
| `state_q` | IDLE | WAIT | WAIT | WAIT | RESP |
| `tmo_cnt_q` | 0 | 0 | 1 | 2 | 3 |
| `timeout` | 0 | 0 | 0 | **1** | 0 |
| `csr_req` | 1 | 1 | 1 | 1 | 0 |
| `PREADY` / `PSLVERR` | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | **1 / 1** |

`csr_req` is high for `TIMEOUT_CYCLES + 1` = 4 cycles; the transfer lasts `TIMEOUT_CYCLES + 2` = 5 cycles.

### 8.4 Local error (unaligned / `PPROT`)

| Cycle | 1 | 2 |
|---|---|---|
| APB phase | SETUP | ACCESS |
| `state_q` | IDLE | RESP |
| `csr_req` | **0** | 0 |
| `PREADY` / `PSLVERR` | 0 / 0 | **1 / 1** |
| `PRDATA` | – | 0 |

## 9. Generated register file

`csrgen.py` generates `<name>_csr_regs` (a CSR bus slave) and `<name>_apb_csr` (the APB4 wrapper).

### 9.1 Interface and decode
- `csr_ack = csr_req` (zero latency), so every APB transfer to the register file takes 2 cycles.
- Word decode: `word_addr = csr_addr[AW-1:log2(DW/8)]`; byte-offset bits are ignored (alignment is checked by the bridge).
- Unmapped address: `csr_err = 1` (`error_on_unmapped: true`) or RAZ/WI (`false`).
- Byte mask: `wmask[i] = csr_wstrb[i/8]`, applied to every writable field.

### 9.2 Access type semantics

Notation: `wr` = software writes this register, `rd` = software reads this register, `d` = `csr_wdata[field]`, `m` = `wmask[field]`, `q` = field flops.

| Access | Update equation (every clock edge) | Software read value |
|---|---|---|
| `RW` | `wr ? (q & ~m) \| (d & m) : (hw_we ? hw_d : q)` | `q` |
| `WO` | `wr ? (q & ~m) \| (d & m) : q` | 0 |
| `W1C` | `(q & ~(d & m & wr)) \| set_i` | `q` |
| `W1S` | `(q & ~clr_i) \| (d & m & wr)` | `q` |
| `W0C` | `(q & ~(~d & m & wr)) \| set_i` | `q` |
| `W0S` | `(q & ~clr_i) \| (~d & m & wr)` | `q` |
| `W0T` | `q ^ (~d & m & wr)` | `q` |
| `RC` | `(q & ~rd) \| set_i` | `q` (value before clearing) |
| `W1P` | `d & m & wr` (one-cycle pulse) | 0 |
| `RO` | – (no flops) | `_i`, or the constant `reset` |

The priority rules are chosen so that **no event is lost**: for `W1C`/`W0C`/`RC` a hardware set beats a software clear; for `W1S`/`W0S` a software set beats a hardware clear; for `RW` + `hw_write` the software write wins.

### 9.3 Write-0 types (W0C, W0S, W0T)

The W0 types are the active-low counterparts of W1C/W1S and react to **0 bits** of the write data:

| Write data bit | `W0C` | `W0S` | `W0T` |
|---|---|---|---|
| 0 (and lane strobed) | clear | set | toggle |
| 1 | no change | no change | no change |
| any (lane not strobed) | no change | no change | no change |

Consequences for software:
- Writing **all ones** to a register is a no-op for all of its W0 fields.
- In a register that mixes W0 fields with other fields, set every W0 bit that should not act to 1 (or exclude its byte lane with `PSTRB`).
- `W0T` has no hardware port; its value is changed only by software and reset.

### 9.4 Access strobes
A register with `"strobe": true` provides `<reg>_wr_o` and `<reg>_rd_o`, each a pulse of exactly one cycle per software write/read. Because the bridge guarantees one handshake per transfer, one APB read produces exactly one `_rd_o` pulse — suitable for FIFO push/pop.

### 9.5 Reset
Every flop resets to the `reset` value from the spec. The reset style (`async`/`sync`) applies **to both** the register file and the bridge inside the wrapper, so the whole IP uses a single reset style on `presetn`.

### 9.6 Ways a register value can change

| Source | Mechanism | Access types affected |
|---|---|---|
| Reset | `presetn` low | every type with flops |
| Software write | APB write with strobed byte lanes | `RW`, `WO`, `W1C`, `W1S`, `W0C`, `W0S`, `W0T`, `W1P` |
| Software read | APB read (side effect) | `RC` |
| Hardware | `_set_i`, `_clr_i`, `_we_i`/`_d_i`, `_i` | `W1C`/`W0C`/`RC`, `W1S`/`W0S`, `RW`+`hw_write`, `RO` |
| Self-clearing | returns to 0 one cycle later | `W1P` |

Nothing changes on: writes to `RO`/`RC` fields, byte lanes with `PSTRB = 0`, transfers rejected by the bridge (unaligned, `PPROT`), and writes to unmapped addresses.

### 9.7 Additional outputs
- `<name>_csr_pkg.sv`: offset, reset, mask, LSB and width constants for testbenches and other RTL.
- `<name>_csr.h`: firmware access macros (`_OFFSET`, `_MASK`, `_SHIFT`, `_GET()`, `_SET()`).
- `<name>_csr.md`: register map documentation, including reserved bit ranges.

## 10. Assertions

Embedded in `apb2csr.sv`, compiled only when `SYNTHESIS` is **not** defined. Every property uses `disable iff (!presetn)`.

| Name | Check |
|---|---|
| `a_apb_penable_psel` | `PENABLE` is only asserted together with `PSEL` |
| `a_apb_setup_access` | SETUP is always followed by ACCESS |
| `a_apb_stable` | `PADDR`, `PWRITE`, `PPROT` (and `PWDATA`, `PSTRB` on writes) are stable during the transfer |
| `a_apb4_pstrb_read` | `PSTRB = 0` on reads (APB4) |
| `a_apb_ctrl_known` | No X/Z on `PSEL`, `PENABLE` |
| `a_apb_addr_known` | No X/Z on `PADDR`, `PWRITE`, `PPROT` while `PSEL=1` |
| `a_apb_wdata_known` | No X/Z on `PWDATA`, `PSTRB` during writes |
| `a_apb_access_after_setup` | No ACCESS phase without a preceding SETUP phase |
| `a_pslverr_pready` | `PSLVERR` only together with `PREADY` |
| `a_csr_req_hold` | `csr_req` is held until acknowledged (except on timeout) |
| (initial) | `DATA_WIDTH` ∈ {8,16,32}; legal `CSR_ADDR_WIDTH` |

In SoC simulation these assertions act as a **free protocol checker** for the APB master/interconnect.

## 11. Performance, resources and integration guidelines

### 11.1 Performance

| Metric | Value |
|---|---|
| Transfer time | 2 cycles + slave latency (2 with the generated register file) |
| Maximum throughput | 1 transfer / 2 cycles (limit of the APB protocol itself) |
| APB input to APB output | always through at least one flop |

### 11.2 Resources (bridge)

| Item | Flip-flops |
|---|---|
| FSM | 2 |
| `rsp_err_q` | 1 |
| `rsp_data_q` | `DATA_WIDTH` |
| Timeout counter | `max(1, ⌈log2 TIMEOUT_CYCLES⌉)` if `TIMEOUT_CYCLES > 0`, else 0 |
| **Total (DW=32, no timeout)** | **35** |

The generated register file uses one flop per bit of every `RW`, `WO`, `W1C`, `W1S`, `W0C`, `W0S`, `W0T`, `RC` and `W1P` field. `RO` fields use no flops.

### 11.3 Critical timing path

In zero-latency mode the longest combinational path is within **one cycle**:
`PADDR`/`PSEL` → `csr_req`/`csr_addr` → slave decode + read mux → `csr_rdata` → mask → `rsp_data_q`.

With the generated register file this is only an address compare and an OR-mux, normally not a concern at APB frequencies. If timing is not met (large map, high frequency), let the slave register its response (latency 1, see §7); the bridge handles the wait state automatically at the cost of one extra cycle per transfer.

### 11.4 Integration guidelines

| Topic | Recommendation |
|---|---|
| Base address | Decode in the APB interconnect (generates `PSEL`). The bridge only uses `PADDR[CSR_ADDR_WIDTH-1:0]`; upper bits are intentionally ignored |
| Window size | 2^`CSR_ADDR_WIDTH` bytes; match it to the address region assigned to the peripheral |
| Clock domains | Bridge and register file run on `pclk`. If the CSR logic is in another clock domain, put a handshake synchronizer (CDC) on the CSR bus and enable `TIMEOUT_CYCLES` |
| Choosing `TIMEOUT_CYCLES` | Larger than the worst-case slave latency (including CDC); 0 for the generated register file |
| Reset | Use one reset style for the whole IP (`ASYNC_RESET` matching `reset_type`; the generated wrapper does this automatically) |
| Interrupts | Combine a `W1C` (or `W0C`) status with an `RW` enable outside: `irq = |(status & enable)` |
| Multiple peripherals | One instance per peripheral; mux `PRDATA`/`PREADY`/`PSLVERR` by `PSEL` in the interconnect |

## 12. Verification

### 12.1 Environment
- **APB4 master BFM** (`tb/apb4_master_if.sv`): back-to-back transfers, `PSTRB=0` on reads, bus scrambled while idle to catch use of stale values.
- **`tb_apb2csr`**: bridge + behavioural CSR slave with random latency, an error address region and a "hang" word for timeout tests; scoreboard against a reference model.
- **`tb_demo_apb_csr`**: directed test of the IP generated from `spec/demo.json`, covering every access type.

### 12.2 Per-transfer checks
Read data against the reference model; expected `PSLVERR`; **exact cycle count** (2 + latency, `TIMEOUT_CYCLES + 2`, 2 for local errors); exactly 0 or 1 CSR handshake; CSR request stability; `csr_wstrb = 0` on reads; no `csr_req` without `PSEL`.

### 12.3 Scenarios
Full address sweep, every `PSTRB` combination, slave error region, unaligned addresses, all 8 `PPROT` values, timeout, ~3000 random transfers with random idle gaps, reset during an outstanding transfer, final consistency read-back. For the generated register file: every access type, byte-lane masking, simultaneous hardware/software updates in the same cycle (priority rules), strobe pulse counts, constants, error responses.

### 12.4 Regression matrix (12 configurations)
DW 32/16/8; zero-wait; latency 12 without timeout; `TIMEOUT_CYCLES=1`; `USE_PSTRB=0`; `ERR_UNALIGNED=0`; `PRIV_ONLY+SECURE_ONLY`; `CSR_ADDR_WIDTH=6`; `ASYNC_RESET=0`; demo IP.

### 12.5 Results

| Item | Result |
|---|---|
| Regression | 36/36 PASS (12 configurations × 3 seeds) |
| Coverage `apb2csr` | Statement 100 %, Branch 97 %, FSM states + transitions 100 % |
| Coverage `demo_csr_regs` | Statement 100 %, Branch 100 % |
| Mutation testing — bridge | 7/7 injected bugs detected (unmasked rdata, `PSTRB` ignored, lost `csr_err`, timeout off-by-one, `csr_req` not held, alignment check removed, latency ignored) |
| Mutation testing — W0 logic | 5/5 injected bugs detected (W0C acting on 1, wrong W0C/W0S priority, W0T ignoring `PSTRB`, W0T setting instead of toggling) |
| Questa 10.7c lint | 0 errors / 0 warnings |
| Verilator 5.020 `-Wall` lint | 0 errors / 0 warnings (1 justified waiver, assertion view only) |

The only uncovered branch is "stay in `S_RESP` without an ACCESS phase", which cannot occur with a compliant APB4 master and is kept as defensive code.

## 13. Limitations and extensions

| Limitation | Possible extension |
|---|---|
| No built-in CDC | Add `apb2csr_cdc` (4-phase handshake synchronizer on the CSR bus) |
| No APB5 support (`PWAKEUP`, `PAUSER`, `PNSE`, parity) | Add an `APB5_EN` parameter |
| Maximum data width 32 bits (per the APB standard) | – |
| Generator lacks register arrays, lock fields, aliases, `W1T`, `WC`/`WS`, `RS` | Extend the schema in `csrgen.py` |
| No UVM RAL model generation | Add a `gen_ral()` emitter based on `uvm_reg` |

## 14. Revision history

| Revision | Changes |
|---|---|
| 1.0 | Initial release: APB4 bridge, `csrgen.py`, Questa flow |
| 1.1 | `ASYNC_RESET` parameter (generated wrapper matches the spec `reset_type`); sink for unused upper `PADDR` bits; generator declares only used signals; Verilator `-Wall` lint added to the flow; `spec/gpio16.json` and the `sync_reset` regression configuration |
| 1.2 | Write-0 access types `W0C`, `W0S`, `W0T` (generator v1.1.0); `ZERO_WR` register in the demo spec with directed tests; documentation translated to English |
