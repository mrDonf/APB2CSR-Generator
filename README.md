# apb2csr — APB4 to CSR bridge IP + register generator

`apb2csr` is a reusable IP for building the control/status register (CSR) block of any peripheral behind an **AMBA APB4** bus. You describe the register map once in a JSON file; the tool generates the RTL, a C header and the documentation.

| Component | Description |
|---|---|
| `rtl/apb2csr.sv` | Parameterizable APB4 slave → CSR bus bridge, project independent |
| `tools/csrgen.py` | Generator: JSON spec → register file RTL + APB4 wrapper + SV package + C header + documentation |
| `tb/`, `sim/run.py` | Self-checking testbenches; QuestaSim flow (compile/sim/coverage) + Verilator (lint) |
| [`docs/apb2csr_ip_spec.md`](docs/apb2csr_ip_spec.md) | **IP specification**: features, parameters, interfaces, timing, error handling, assertions |

Compliant with the *AMBA APB Protocol Specification v2.0 (ARM IHI 0024C) — APB4*.

---

## Contents

1. [Requirements](#1-requirements)
2. [Directory structure](#2-directory-structure)
3. [Quick start](#3-quick-start)
4. [Generation guide](#4-generation-guide)
   - [4.1 Write the spec](#41-step-1--write-the-register-spec)
   - [4.2 Validate](#42-step-2--validate-the-spec)
   - [4.3 Generate](#43-step-3--generate)
   - [4.4 Lint and verify](#44-step-4--lint-and-verify)
   - [4.5 Integrate into the SoC](#45-step-5--integrate-into-the-soc)
   - [4.6 Changing the register map](#46-changing-the-register-map)
5. [Using `apb2csr` without the generator](#5-using-apb2csr-without-the-generator)
6. [`sim/run.py` command reference](#6-simrunpy-command-reference)
7. [Verification results](#7-verification-results)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Requirements

| Tool | Tested version | Used for |
|---|---|---|
| Python | 3.8+ (tested with 3.13) | `csrgen.py`, `run.py`. No third-party packages needed (`pyyaml` only for YAML specs) |
| QuestaSim | 10.7c | Compilation, simulation, coverage, lint (`vlog -lint`, `vopt`) |
| Verilator | 5.020 | `-Wall` lint. On Windows either native (`verilator_bin`) or **through WSL** (detected automatically) |

`vlog`, `vsim`, `vopt` and `vcover` must be on the `PATH`.

## 2. Directory structure

```
apb2csr/
├── rtl/apb2csr.sv                # Bridge IP
├── tools/csrgen.py               # Register generator
├── spec/                         # Register specs (generator input)
│   ├── demo.json                 #   32-bit, async reset, every access type
│   └── gpio16.json               #   16-bit, sync reset, RAZ/WI
├── generated/<name>/             # Generator output (DO NOT edit by hand)
├── docs/apb2csr_ip_spec.md       # IP specification
├── lint/verilator_waivers.vlt    # Verilator waivers (assertion view only)
├── tb/                           # APB4 master BFM + testbenches
└── sim/run.py                    # Flow: gen / lint / sim / regress / all
```

## 3. Quick start

```bash
python sim/run.py gen        # spec/*.json  -> generated/*
python sim/run.py lint       # Questa + Verilator lint
python sim/run.py regress    # 12 configurations, self-checking
# or everything in one go (with coverage):
python sim/run.py all
```

---

## 4. Generation guide

Overall flow:

```
 spec/my_ip.json ──► csrgen.py --check ──► csrgen.py ──► generated/my_ip/*  ──► run.py lint ──► integrate
   (you write)         (validate)          (generate)     (RTL, .h, .md)        (Questa+Verilator)
```

### 4.1 Step 1 — Write the register spec

Create `spec/<ip_name>.json`. A complete example for a simple UART:

```json
{
  "name": "uart",
  "description": "Simple UART controller",
  "data_width": 32,
  "addr_width": 8,
  "error_on_unmapped": true,
  "reset_type": "async",
  "registers": [
    { "name": "CTRL", "offset": "0x00", "description": "Control",
      "fields": [
        { "name": "EN",   "bits": "0",    "access": "RW",  "reset": 0,      "description": "UART enable" },
        { "name": "BAUD", "bits": "15:4", "access": "RW",  "reset": "0x1B", "description": "Baud divider" },
        { "name": "FLUSH","bits": "31",   "access": "W1P",                  "description": "Flush FIFOs (pulse)" }
      ]},
    { "name": "STATUS", "offset": "0x04",
      "fields": [
        { "name": "TX_FULL",  "bits": "0", "access": "RO" },
        { "name": "RX_EMPTY", "bits": "1", "access": "RO" }
      ]},
    { "name": "INT_STAT", "offset": "0x08",
      "fields": [ { "name": "RX", "bits": "0", "access": "W1C", "description": "Byte received" } ]},
    { "name": "INT_EN", "offset": "0x0C",
      "fields": [ { "name": "RX", "bits": "0", "access": "RW" } ]},
    { "name": "TXDATA", "offset": "0x10", "strobe": true,
      "fields": [ { "name": "DATA", "bits": "7:0", "access": "WO", "description": "Write pushes TX FIFO" } ]},
    { "name": "RXDATA", "offset": "0x14", "strobe": true,
      "fields": [ { "name": "DATA", "bits": "7:0", "access": "RO", "description": "Read pops RX FIFO" } ]},
    { "name": "ID", "offset": "0xFC",
      "fields": [ { "name": "VALUE", "bits": "31:0", "access": "RO", "const": true, "reset": "0x55410100" } ]}
  ]
}
```

#### Block-level keys

| Key | Required | Default | Values | Meaning |
|---|---|---|---|---|
| `name` | ✔ | – | identifier | Block name; prefix of every file, module and macro |
| `description` | | `""` | string | Copied into RTL comments and documentation |
| `data_width` | | `32` | `8`, `16`, `32` | APB / CSR data bus width |
| `addr_width` | | minimum required | int | Byte-address width of the block (address window = 2^addr_width bytes) |
| `error_on_unmapped` | | `true` | bool | `true`: access to an address with no register → `PSLVERR`; `false`: read as zero, write ignored (RAZ/WI) |
| `reset_type` | | `"async"` | `"async"`, `"sync"` | Reset style of the register file; the bridge in the wrapper gets a matching `ASYNC_RESET` |
| `registers` | ✔ | – | list | Register list |

#### Register keys

| Key | Required | Default | Meaning |
|---|---|---|---|
| `name` | ✔ | – | Register name (upper case in package/header, lower case in port names) |
| `offset` | ✔ | – | Byte offset, aligned to `data_width/8` |
| `description` / `desc` | | `""` | Description |
| `strobe` | | `false` | Adds `<reg>_wr_o` / `<reg>_rd_o`: one-cycle pulse on every software write/read of the register |
| `fields` | ✔ | – | Field list (at least one) |

#### Field keys

| Key | Required | Default | Meaning |
|---|---|---|---|
| `name` | ✔ | – | Field name |
| `bits` | ✔\* | – | `"msb:lsb"`, `"n"` or integer `n` |
| `lsb` + `width` | ✔\* | width = 1 | Alternative to `bits` |
| `access` | | `"RW"` | One of the access types below |
| `reset` | | `0` | Reset value (`"0x.."`, `"0b.."`, decimal; `_` separators allowed) |
| `description` / `desc` | | `""` | Description |
| `hw_write` | | `false` | `RW` only: adds a hardware write port (`_we_i`, `_d_i`) |
| `const` | | `false` | `RO` only: field is the constant `reset`, no port (for ID/VERSION) |

\* use `bits` **or** `lsb`/`width`.

#### Access types and generated hardware ports

Port names are `<reg>_<field>_<suffix>` in lower case, e.g. `CTRL.BAUD` → `ctrl_baud_o`.

| Access | SW read | SW write | Hardware ports | SW and HW in the same cycle |
|---|---|---|---|---|
| `RW` | value | write (per byte strobe) | `_o`; + `_we_i`, `_d_i` if `hw_write` | SW wins |
| `RO` | `_i` | ignored | `_i` (none if `const`) | – |
| `WO` | 0 | write | `_o` | – |
| `W1C` | value | 1 → clear bit | `_o`, `_set_i` | HW set wins (no lost event) |
| `W1S` | value | 1 → set bit | `_o`, `_clr_i` | SW set wins (no lost command) |
| `W0C` | value | **0** → clear bit | `_o`, `_set_i` | HW set wins |
| `W0S` | value | **0** → set bit | `_o`, `_clr_i` | SW set wins |
| `W0T` | value | **0** → toggle bit | `_o` | – |
| `RC` | value, then cleared | ignored | `_o`, `_set_i` | HW set wins |
| `W1P` | 0 | 1 → one-cycle pulse | `_o` (registered pulse) | – |

Every write honours `PSTRB`: byte lanes with a strobe of 0 are never affected, including for `W1C`/`W1S`/`W0C`/`W0S`/`W0T`/`W1P`.

> **Note on the W0 types.** Write-0 fields react to the 0 bits of the write data. When a register mixes W0 fields with other fields, write **1** to every W0 bit you do not want to act on (writing all ones is a no-op for W0C/W0S/W0T), or use `PSTRB` to exclude the byte lanes.

### 4.2 Step 2 — Validate the spec

```bash
python tools/csrgen.py spec/uart.json --check
# csrgen: uart: 7 registers, 10 fields, DW=32, AW=8
# csrgen: spec OK
```

The generator rejects invalid specs with a precise message. Checked rules:

| Rule | Example message |
|---|---|
| Overlapping fields | `field A.Y: bits [4:4] overlap another field` |
| Unaligned offset | `register A: offset 0x2 not aligned to 4 bytes` |
| Duplicate offset | `register B: offset 0x0 already used by A` |
| Reset value too wide | `field A.X: reset 0x1f does not fit in 4 bit(s)` |
| Bit outside the data width | `field A.X: bit 32 outside data width 32` |
| Unknown access type | `field A.X: access 'XX' not in (...)` |
| Misspelled key | `unknown key(s) ['acces']; allowed: [...]` |
| Generated port name collision | `port name collision: a_b_c_o (A vs A_B)` |
| `addr_width` too small | `spec.addr_width=4 too small (need >= 7)` |
| Invalid name / SystemVerilog keyword | `invalid identifier`, `reserved SystemVerilog keyword` |
| `hw_write` outside RW, `const` outside RO, `W1P` with reset ≠ 0 | matching message |

### 4.3 Step 3 — Generate

```bash
python tools/csrgen.py spec/uart.json -o generated/uart
# or regenerate every spec/*.json:
python sim/run.py gen
```

Output in `generated/uart/`:

| File | Content |
|---|---|
| `uart_csr_pkg.sv` | Package `uart_csr_pkg`: `UART_<REG>_OFFSET`, `UART_<REG>_RESET`, `UART_<REG>_<FIELD>_LSB/_WIDTH/_MASK`, `UART_DATA_WIDTH`, `UART_ADDR_WIDTH` |
| `uart_csr_regs.sv` | Module `uart_csr_regs`: register file on the CSR bus (decode, byte strobes, access logic, read mux, `csr_err`) |
| `uart_apb_csr.sv` | Module `uart_apb_csr`: **APB4 top** = `apb2csr` + `uart_csr_regs`. This is the module you instantiate |
| `uart_csr.h` | C header: `UART_REG(base, off)`, `_OFFSET`, `_RESET`, `_SHIFT`, `_MASK`, `_GET(v)`, `_SET(v)` |
| `uart_csr.md` | Register map documentation (summary table + per-register bit tables) |

Example of the generated RTL for a `W1C` field:

```systemverilog
logic  int_stat_rx_q;  // INT_STAT.RX [0] W1C
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) int_stat_rx_q <= 1'h0;
  else int_stat_rx_q <= (int_stat_rx_q & ~(csr_wdata[0] & wmask[0] & int_stat_wr)) | int_stat_rx_set_i;
end
assign int_stat_rx_o = int_stat_rx_q;
```

and for a `W0T` field (4 bits):

```systemverilog
else zero_wr_tog_q <= zero_wr_tog_q ^ (~csr_wdata[19:16] & wmask[19:16] & {4{zero_wr_wr}});
```

Properties of the generated RTL:
- The register file always returns `csr_ack = csr_req` (zero latency), so every APB transfer takes 2 cycles.
- Only the signals that are actually used are declared, so the output is clean under `verilator -Wall`; unused bus inputs are collected in `unused_*` signals.
- Flat, readable code with no macros or includes; compatible with common synthesis tools.

### 4.4 Step 4 — Lint and verify

```bash
python sim/run.py lint --strict
```

`run.py` lints **every** block in `generated/`:
- **Questa**: `vlog -lint -pedanticerrors` + elaboration (`vopt`) of every generated top.
- **Verilator** `--lint-only -Wall`: width mismatch/truncation, latches, unused signals, mixed sync/async reset, etc.

Expected result: `[lint] PASS: 0 error(s), 0 warning(s)`.

You should also write a small test for your IP using `tb/tb_demo_apb_csr.sv` as a template. It uses `apb4_master_if` (`write`/`read` tasks) and the constants from the generated package, so the test does not need to change when offsets move.

### 4.5 Step 5 — Integrate into the SoC

**File list** (compile order: package first):
```
rtl/apb2csr.sv
generated/uart/uart_csr_pkg.sv
generated/uart/uart_csr_regs.sv
generated/uart/uart_apb_csr.sv
```

**Instantiation:**
```systemverilog
uart_apb_csr #(
  .APB_ADDR_WIDTH (32),     // PADDR width of the interconnect
  .USE_PSTRB      (1'b1),   // APB4
  .ERR_UNALIGNED  (1'b1),
  .PRIV_ONLY      (1'b0),   // 1: privileged accesses only
  .SECURE_ONLY    (1'b0)    // 1: secure accesses only
) u_uart_csr (
  .pclk     (pclk),
  .presetn  (presetn),
  .psel     (psel_uart),    // from the APB interconnect address decoder
  .penable  (penable),
  .paddr    (paddr),        // only paddr[UART_ADDR_WIDTH-1:0] is used
  .pwrite   (pwrite),
  .pwdata   (pwdata),
  .pstrb    (pstrb),
  .pprot    (pprot),
  .pready   (pready_uart),
  .prdata   (prdata_uart),
  .pslverr  (pslverr_uart),
  // hardware interface
  .ctrl_en_o          (uart_en),
  .ctrl_baud_o        (baud_div),
  .ctrl_flush_o       (fifo_flush),
  .status_tx_full_i   (tx_full),
  .status_rx_empty_i  (rx_empty),
  .int_stat_rx_o      (rx_irq_stat),
  .int_stat_rx_set_i  (rx_byte_done),
  .int_en_rx_o        (rx_irq_en),
  .txdata_data_o      (tx_data),
  .txdata_wr_o        (tx_push),       // strobe: writing TXDATA pushes the FIFO
  .txdata_rd_o        (),
  .rxdata_data_i      (rx_fifo_head),
  .rxdata_wr_o        (),
  .rxdata_rd_o        (rx_pop)         // strobe: reading RXDATA pops the FIFO
);

assign uart_irq = rx_irq_stat & rx_irq_en;
```

**Firmware:**
```c
#include "uart_csr.h"
#define UART_BASE 0x40002000u

static uint8_t  rx_buf[64];
static unsigned rx_cnt;

void uart_init(void) {
    UART_REG(UART_BASE, UART_CTRL_OFFSET) = UART_CTRL_EN_SET(1) | UART_CTRL_BAUD_SET(27);
    UART_REG(UART_BASE, UART_INT_EN_OFFSET) = UART_INT_EN_RX_MASK;
}

void uart_irq_handler(void) {
    uint32_t st = UART_REG(UART_BASE, UART_INT_STAT_OFFSET);
    if (UART_INT_STAT_RX_GET(st)) {
        rx_buf[rx_cnt++ % 64u] = (uint8_t)UART_REG(UART_BASE, UART_RXDATA_OFFSET); /* pop */
        UART_REG(UART_BASE, UART_INT_STAT_OFFSET) = UART_INT_STAT_RX_MASK;          /* W1C */
    }
}
```

### 4.6 Changing the register map

1. Edit only `spec/<ip>.json`; **never** edit files in `generated/` (each has a `DO NOT EDIT` banner).
2. Run `python sim/run.py gen`, then `python sim/run.py lint`.
3. Commit both the spec and the generated output so reviewers see the RTL diff.

---

## 5. Using `apb2csr` without the generator

The bridge can drive a hand-written register file or a slave with latency (SRAM, a block in another clock domain behind a CDC):

```systemverilog
apb2csr #(
  .DATA_WIDTH     (32),
  .CSR_ADDR_WIDTH (12),
  .TIMEOUT_CYCLES (64)        // > worst-case slave latency
) u_bridge ( .pclk, .presetn, .psel, .penable, .paddr, .pwrite, .pwdata, .pstrb, .pprot,
             .pready, .prdata, .pslverr,
             .csr_req, .csr_we, .csr_addr, .csr_wdata, .csr_wstrb, .csr_prot,
             .csr_ack, .csr_rdata, .csr_err );
```

The slave only has to follow the CSR bus rules: respond while `csr_req` = 1 with a one-cycle `csr_ack` together with `csr_rdata`/`csr_err`. See [IP specification, section 7](docs/apb2csr_ip_spec.md#7-csr-bus-protocol).

---

## 6. `sim/run.py` command reference

| Command | Action |
|---|---|
| `gen [--spec FILE]` | Regenerate `generated/*` from `spec/*.json` (or a single file) |
| `lint [--tool all\|questa\|verilator] [--strict]` | Lint. `--strict`: warnings count as failures |
| `sim [--tb TB] [-G N=V]... [--seed S] [--gui] [--cov]` | Run one test. `TB` = `tb_apb2csr` or `tb_demo_apb_csr`; `-G` overrides a parameter |
| `regress [--seeds N] [--seed S] [--cov]` | 12 configurations × N seeds |
| `all` | `gen` + `lint` + `regress --cov` |

Examples:
```bash
python sim/run.py sim -G DATA_WIDTH=16 -G MAX_LATENCY=0 --seed 123
python sim/run.py sim -G ASYNC_RESET=0 --gui
python sim/run.py regress --seeds 5 --cov
```

Outputs are written to `sim/out/`: per-test logs, lint logs (`lint_*.log`), `merged.ucdb`, `coverage_summary.txt`, `coverage_details.txt`, `coverage_html/index.html`.

**What the lint step runs:**

| Tool | On | Configuration |
|---|---|---|
| Questa `vlog -lint -pedanticerrors` | `apb2csr` + every generated block | `+define+SYNTHESIS` |
| Questa `vopt` (elaboration) | `apb2csr` × 6 parameter sets, every generated top | catches port width mismatches, bad ranges |
| Verilator `-Wall`, synthesis view | `apb2csr` × 6 parameter sets, every generated top | `-DSYNTHESIS`, **no waivers** |
| Verilator `-Wall`, assertion view | `apb2csr` (async + sync reset) | `--assert` + `lint/verilator_waivers.vlt` |

---

## 7. Verification results

| Item | Result |
|---|---|
| Questa lint (vlog + 8 elaborations) | 0 errors, 0 warnings |
| Verilator 5.020 `-Wall` lint (10 runs) | 0 errors, 0 warnings (1 justified waiver, assertion view only) |
| Regression (12 configurations × 3 seeds) | 36/36 PASS |
| Code coverage `apb2csr` | Statement 100 %, Branch 97 %, FSM states/transitions 100 % |
| Code coverage `demo_csr_regs` | Statement 100 %, Branch 100 % |
| Mutation testing — bridge (7 injected bugs) | 7/7 detected |
| Mutation testing — W0C/W0S/W0T logic (5 injected bugs) | 5/5 detected |

Verification methodology: [IP specification, section 12](docs/apb2csr_ip_spec.md#12-verification).

## 8. Troubleshooting

| Symptom | Fix |
|---|---|
| `[lint:verilator] Verilator not found` | Install Verilator on the `PATH` (Linux) or inside WSL: `sudo apt install verilator` |
| Several WSL distributions installed | `set APB2CSR_WSL_DISTRO=Ubuntu` (PowerShell: `$env:APB2CSR_WSL_DISTRO="Ubuntu"`) |
| `'vlog' not found in PATH` | Add the QuestaSim `bin` directory (e.g. `C:\questasim64_10.7c\win64`) to the `PATH` |
| YAML spec fails to load | `pip install pyyaml`, or use JSON |
| Syntax error in a `.vlt` waiver file | Never start a comment with the word `verilator`: Verilator parses that line as a pragma |
| A W0 field changed unexpectedly | A 0 bit was written to it; write 1 to W0 bits that should not act, or mask the lane with `PSTRB` |
