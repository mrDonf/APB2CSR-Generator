# apb2csr — APB4 to CSR bridge IP + register generator

`apb2csr` là bộ IP tái sử dụng để tạo khối thanh ghi điều khiển/trạng thái (CSR) có giao tiếp **AMBA APB4** cho bất kỳ peripheral nào. Bạn chỉ cần mô tả register map trong một file JSON, tool sẽ sinh ra RTL, header C và tài liệu.

| Thành phần | Mô tả |
|---|---|
| `rtl/apb2csr.sv` | Bridge APB4 slave → CSR bus, có tham số, không phụ thuộc dự án |
| `tools/csrgen.py` | Generator: spec JSON → register file RTL + wrapper APB4 + SV package + C header + tài liệu |
| `tb/`, `sim/run.py` | Testbench tự kiểm tra; flow QuestaSim (compile/sim/coverage) + Verilator (lint) |
| [`docs/apb2csr_ip_spec.md`](docs/apb2csr_ip_spec.md) | **Đặc tả IP**: tính năng, tham số, giao tiếp, timing, xử lý lỗi, assertions |

Tuân thủ *AMBA APB Protocol Specification v2.0 (ARM IHI 0024C) — APB4*.

---

## Mục lục

1. [Yêu cầu môi trường](#1-yêu-cầu-môi-trường)
2. [Cấu trúc thư mục](#2-cấu-trúc-thư-mục)
3. [Quick start](#3-quick-start)
4. [Hướng dẫn generate chi tiết](#4-hướng-dẫn-generate-chi-tiết)
   - [4.1 Viết spec](#41-bước-1--viết-register-spec)
   - [4.2 Validate](#42-bước-2--validate-spec)
   - [4.3 Generate](#43-bước-3--generate)
   - [4.4 Lint và verify](#44-bước-4--lint-và-verify)
   - [4.5 Tích hợp vào SoC](#45-bước-5--tích-hợp-vào-soc)
   - [4.6 Thay đổi register map](#46-thay-đổi-register-map)
5. [Dùng `apb2csr` không qua generator](#5-dùng-apb2csr-không-qua-generator)
6. [Tham chiếu lệnh `sim/run.py`](#6-tham-chiếu-lệnh-simrunpy)
7. [Kết quả verification](#7-kết-quả-verification)
8. [Xử lý sự cố](#8-xử-lý-sự-cố)

---

## 1. Yêu cầu môi trường

| Công cụ | Phiên bản đã kiểm tra | Dùng cho |
|---|---|---|
| Python | 3.8+ (đã chạy 3.13) | `csrgen.py`, `run.py`. Không cần thư viện ngoài (YAML cần `pyyaml`, không bắt buộc) |
| QuestaSim | 10.7c | Compile, simulation, coverage, lint (`vlog -lint`, `vopt`) |
| Verilator | 5.020 | Lint `-Wall`. Trên Windows có thể chạy native (`verilator_bin`) hoặc **qua WSL** (tự động phát hiện) |

`vlog`, `vsim`, `vopt`, `vcover` phải nằm trong `PATH`.

## 2. Cấu trúc thư mục

```
apb2csr/
├── rtl/apb2csr.sv                # Bridge IP
├── tools/csrgen.py               # Register generator
├── spec/                         # Register spec (đầu vào của generator)
│   ├── demo.json                 #   32-bit, async reset, đủ mọi access type
│   └── gpio16.json               #   16-bit, sync reset, RAZ/WI
├── generated/<name>/             # Output của generator (KHÔNG sửa tay)
├── docs/apb2csr_ip_spec.md       # Đặc tả IP
├── lint/verilator_waivers.vlt    # Waiver Verilator (chỉ cho chế độ có SVA)
├── tb/                           # APB4 master BFM + testbench
└── sim/run.py                    # Flow: gen / lint / sim / regress / all
```

## 3. Quick start

```bash
python sim/run.py gen        # spec/*.json  -> generated/*
python sim/run.py lint       # Questa + Verilator lint
python sim/run.py regress    # 12 cấu hình, self-checking
# hoặc tất cả trong một lệnh (kèm coverage):
python sim/run.py all
```

---

## 4. Hướng dẫn generate chi tiết

Quy trình tổng quát:

```
 spec/my_ip.json ──► csrgen.py --check ──► csrgen.py ──► generated/my_ip/*  ──► run.py lint ──► tích hợp
   (bạn viết)         (validate)          (generate)     (RTL, .h, .md)        (Questa+Verilator)
```

### 4.1 Bước 1 — Viết register spec

Tạo file `spec/<tên_ip>.json`. Ví dụ đầy đủ cho một UART đơn giản:

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

#### Khóa cấp block (top-level)

| Khóa | Bắt buộc | Mặc định | Giá trị | Ý nghĩa |
|---|---|---|---|---|
| `name` | ✔ | – | identifier | Tên block; là tiền tố của mọi file, module, macro |
| `description` | | `""` | string | Đưa vào comment RTL và tài liệu |
| `data_width` | | `32` | `8`, `16`, `32` | Độ rộng bus dữ liệu APB / CSR |
| `addr_width` | | tối thiểu cần thiết | int | Độ rộng địa chỉ byte của block (kích thước cửa sổ địa chỉ = 2^addr_width byte) |
| `error_on_unmapped` | | `true` | bool | `true`: truy cập địa chỉ không có thanh ghi → `PSLVERR`; `false`: đọc ra 0, ghi bị bỏ qua (RAZ/WI) |
| `reset_type` | | `"async"` | `"async"`, `"sync"` | Kiểu reset của register file; bridge trong wrapper được đặt `ASYNC_RESET` cho khớp |
| `registers` | ✔ | – | list | Danh sách thanh ghi |

#### Khóa của thanh ghi

| Khóa | Bắt buộc | Mặc định | Ý nghĩa |
|---|---|---|---|
| `name` | ✔ | – | Tên thanh ghi (được viết hoa trong package/header, viết thường trong tên cổng) |
| `offset` | ✔ | – | Offset byte, phải align theo `data_width/8` |
| `description` / `desc` | | `""` | Mô tả |
| `strobe` | | `false` | Sinh thêm `<reg>_wr_o` / `<reg>_rd_o`: xung 1 chu kỳ mỗi lần SW ghi/đọc thanh ghi |
| `fields` | ✔ | – | Danh sách field (ít nhất 1) |

#### Khóa của field

| Khóa | Bắt buộc | Mặc định | Ý nghĩa |
|---|---|---|---|
| `name` | ✔ | – | Tên field |
| `bits` | ✔\* | – | `"msb:lsb"`, `"n"` hoặc số nguyên `n` |
| `lsb` + `width` | ✔\* | width = 1 | Cách viết thay cho `bits` |
| `access` | | `"RW"` | `RW`, `RO`, `WO`, `W1C`, `W1S`, `RC`, `W1P` |
| `reset` | | `0` | Giá trị reset (`"0x.."`, `"0b.."`, số thập phân; cho phép `_`) |
| `description` / `desc` | | `""` | Mô tả |
| `hw_write` | | `false` | Chỉ cho `RW`: thêm cổng để hardware ghi vào field (`_we_i`, `_d_i`) |
| `const` | | `false` | Chỉ cho `RO`: field là hằng số = `reset`, không sinh cổng (dùng cho ID/VERSION) |

\* dùng `bits` **hoặc** `lsb`/`width`.

#### Các kiểu access và cổng hardware được sinh ra

Tên cổng: `<reg>_<field>_<hậu tố>`, viết thường. Ví dụ `CTRL.BAUD` → `ctrl_baud_o`.

| Access | SW đọc | SW ghi | Cổng hardware | Khi SW và HW tác động cùng chu kỳ |
|---|---|---|---|---|
| `RW` | giá trị | ghi (theo byte strobe) | `_o`; + `_we_i`, `_d_i` nếu `hw_write` | SW thắng |
| `RO` | `_i` | bỏ qua | `_i` (không có nếu `const`) | – |
| `WO` | 0 | ghi | `_o` | – |
| `W1C` | giá trị | bit = 1 → xóa | `_o`, `_set_i` | HW set thắng (không mất sự kiện) |
| `W1S` | giá trị | bit = 1 → set | `_o`, `_clr_i` | SW set thắng (không mất lệnh) |
| `RC` | giá trị, sau đó tự xóa | bỏ qua | `_o`, `_set_i` | HW set thắng |
| `W1P` | 0 | bit = 1 → xung 1 chu kỳ | `_o` (xung, ra từ flip-flop) | – |

Mọi thao tác ghi đều tôn trọng `PSTRB`: byte lane có strobe = 0 không bị ảnh hưởng, kể cả với `W1C`/`W1S`/`W1P`.

### 4.2 Bước 2 — Validate spec

```bash
python tools/csrgen.py spec/uart.json --check
# csrgen: uart: 7 registers, 10 fields, DW=32, AW=8
# csrgen: spec OK
```

Generator từ chối spec sai và báo lỗi rõ vị trí. Các luật được kiểm tra:

| Luật | Ví dụ thông báo |
|---|---|
| Field chồng bit | `field A.Y: bits [4:4] overlap another field` |
| Offset không align | `register A: offset 0x2 not aligned to 4 bytes` |
| Offset trùng | `register B: offset 0x0 already used by A` |
| Reset vượt độ rộng | `field A.X: reset 0x1f does not fit in 4 bit(s)` |
| Bit ngoài data width | `field A.X: bit 32 outside data width 32` |
| Access không hợp lệ | `field A.X: access 'XX' not in (...)` |
| Gõ sai tên khóa | `unknown key(s) ['acces']; allowed: [...]` |
| Trùng tên cổng sinh ra | `port name collision: a_b_c_o (A vs A_B)` |
| `addr_width` quá nhỏ | `spec.addr_width=4 too small (need >= 7)` |
| Tên không hợp lệ / trùng keyword SV | `invalid identifier`, `reserved SystemVerilog keyword` |
| `hw_write` ngoài RW, `const` ngoài RO, `W1P` có reset ≠ 0 | thông báo tương ứng |

### 4.3 Bước 3 — Generate

```bash
python tools/csrgen.py spec/uart.json -o generated/uart
# hoặc sinh lại tất cả spec/*.json:
python sim/run.py gen
```

Output trong `generated/uart/`:

| File | Nội dung |
|---|---|
| `uart_csr_pkg.sv` | Package `uart_csr_pkg`: `UART_<REG>_OFFSET`, `UART_<REG>_RESET`, `UART_<REG>_<FIELD>_LSB/_WIDTH/_MASK`, `UART_DATA_WIDTH`, `UART_ADDR_WIDTH` |
| `uart_csr_regs.sv` | Module `uart_csr_regs`: register file trên CSR bus (decode, byte strobe, logic access, read mux, `csr_err`) |
| `uart_apb_csr.sv` | Module `uart_apb_csr`: **top APB4** = `apb2csr` + `uart_csr_regs`. Đây là module bạn instantiate |
| `uart_csr.h` | Header C: `UART_REG(base, off)`, `_OFFSET`, `_RESET`, `_SHIFT`, `_MASK`, `_GET(v)`, `_SET(v)` |
| `uart_csr.md` | Tài liệu register map (bảng tổng hợp + bảng bit từng thanh ghi) |

Ví dụ RTL sinh ra cho một field `W1C`:

```systemverilog
logic  int_stat_rx_q;  // INT_STAT.RX [0] W1C
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) int_stat_rx_q <= 1'h0;
  else int_stat_rx_q <= (int_stat_rx_q & ~(csr_wdata[0] & wmask[0] & int_stat_wr)) | int_stat_rx_set_i;
end
assign int_stat_rx_o = int_stat_rx_q;
```

Đặc điểm của RTL sinh ra:
- Register file luôn trả `csr_ack = csr_req` (zero latency), nên mỗi transfer APB chỉ mất 2 chu kỳ.
- Chỉ khai báo tín hiệu thực sự cần dùng, nên sạch dưới `verilator -Wall`. Các input không dùng được gom vào tín hiệu `unused_*`.
- Code phẳng, dễ đọc, không dùng macro hay include, tương thích các tool synthesis phổ biến.

### 4.4 Bước 4 — Lint và verify

```bash
python sim/run.py lint --strict
```

`run.py` tự lint **mọi** block trong `generated/`, gồm:
- **Questa**: `vlog -lint -pedanticerrors` + elaborate (`vopt`) từng top được sinh ra.
- **Verilator** `--lint-only -Wall`: phát hiện width mismatch/truncation, latch, signal không dùng, trộn sync/async reset, v.v.

Kết quả mong đợi là `[lint] PASS: 0 error(s), 0 warning(s)`.

Nên viết thêm một test nhỏ cho IP của bạn, lấy `tb/tb_demo_apb_csr.sv` làm mẫu. Testbench đó dùng `apb4_master_if` (task `write`/`read`) và các hằng số trong package sinh ra, nên khi offset thay đổi bạn không phải sửa test.

### 4.5 Bước 5 — Tích hợp vào SoC

**Filelist** (thứ tự compile: package trước):
```
rtl/apb2csr.sv
generated/uart/uart_csr_pkg.sv
generated/uart/uart_csr_regs.sv
generated/uart/uart_apb_csr.sv
```

**Instantiate:**
```systemverilog
uart_apb_csr #(
  .APB_ADDR_WIDTH (32),     // độ rộng PADDR của interconnect
  .USE_PSTRB      (1'b1),   // APB4
  .ERR_UNALIGNED  (1'b1),
  .PRIV_ONLY      (1'b0),   // 1: chỉ cho phép truy cập privileged
  .SECURE_ONLY    (1'b0)    // 1: chỉ cho phép truy cập secure
) u_uart_csr (
  .pclk     (pclk),
  .presetn  (presetn),
  .psel     (psel_uart),    // từ address decoder của APB interconnect
  .penable  (penable),
  .paddr    (paddr),        // chỉ dùng paddr[UART_ADDR_WIDTH-1:0]
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
  .txdata_wr_o        (tx_push),       // strobe: ghi TXDATA = push FIFO
  .txdata_rd_o        (),
  .rxdata_data_i      (rx_fifo_head),
  .rxdata_wr_o        (),
  .rxdata_rd_o        (rx_pop)         // strobe: đọc RXDATA = pop FIFO
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

### 4.6 Thay đổi register map

1. Chỉ sửa `spec/<ip>.json`, **không** sửa file trong `generated/` (mọi file đều có dòng `DO NOT EDIT`).
2. Chạy `python sim/run.py gen` rồi `python sim/run.py lint`.
3. Commit cả spec lẫn output được sinh ra, để reviewer thấy được diff RTL.

---

## 5. Dùng `apb2csr` không qua generator

Bridge có thể nối với register file viết tay hoặc slave có latency (SRAM, khối ở clock domain khác qua CDC):

```systemverilog
apb2csr #(
  .DATA_WIDTH     (32),
  .CSR_ADDR_WIDTH (12),
  .TIMEOUT_CYCLES (64)        // > latency lớn nhất của slave
) u_bridge ( .pclk, .presetn, .psel, .penable, .paddr, .pwrite, .pwdata, .pstrb, .pprot,
             .pready, .prdata, .pslverr,
             .csr_req, .csr_we, .csr_addr, .csr_wdata, .csr_wstrb, .csr_prot,
             .csr_ack, .csr_rdata, .csr_err );
```

Slave chỉ cần tuân theo quy tắc của CSR bus: giữ trả lời cho tới khi `csr_req`=1, rồi trả `csr_ack` một chu kỳ kèm `csr_rdata`/`csr_err`. Chi tiết xem [đặc tả IP, mục 7](docs/apb2csr_ip_spec.md#7-csr-bus-protocol).

---

## 6. Tham chiếu lệnh `sim/run.py`

| Lệnh | Tác dụng |
|---|---|
| `gen [--spec FILE]` | Sinh lại `generated/*` từ `spec/*.json` (hoặc chỉ một file) |
| `lint [--tool all\|questa\|verilator] [--strict]` | Lint. `--strict`: coi warning là lỗi |
| `sim [--tb TB] [-G N=V]... [--seed S] [--gui] [--cov]` | Chạy một test. `TB` = `tb_apb2csr` hoặc `tb_demo_apb_csr`; `-G` override tham số |
| `regress [--seeds N] [--seed S] [--cov]` | Ma trận 12 cấu hình × N seed |
| `all` | `gen` + `lint` + `regress --cov` |

Ví dụ:
```bash
python sim/run.py sim -G DATA_WIDTH=16 -G MAX_LATENCY=0 --seed 123
python sim/run.py sim -G ASYNC_RESET=0 --gui
python sim/run.py regress --seeds 5 --cov
```

Output nằm trong `sim/out/`: log từng test, log lint (`lint_*.log`), `merged.ucdb`, `coverage_summary.txt`, `coverage_details.txt`, `coverage_html/index.html`.

**Lint gồm những gì:**

| Tool | Chạy trên | Cấu hình |
|---|---|---|
| Questa `vlog -lint -pedanticerrors` | `apb2csr` + mọi block sinh ra | `+define+SYNTHESIS` |
| Questa `vopt` (elaborate) | `apb2csr` × 6 bộ tham số, mọi top sinh ra | bắt lệch độ rộng cổng, range sai |
| Verilator `-Wall`, synthesis view | `apb2csr` × 6 bộ tham số, mọi top sinh ra | `-DSYNTHESIS`, **không waiver** |
| Verilator `-Wall`, assertion view | `apb2csr` (async + sync reset) | `--assert` + `lint/verilator_waivers.vlt` |

---

## 7. Kết quả verification

| Hạng mục | Kết quả |
|---|---|
| Lint Questa (vlog + 8 elaboration) | 0 error, 0 warning |
| Lint Verilator 5.020 `-Wall` (10 lần chạy) | 0 error, 0 warning (1 waiver có lý do, chỉ ở assertion view) |
| Regression (12 cấu hình × 3 seed) | 36/36 PASS |
| Code coverage `apb2csr` | Statement 100 %, Branch 97 %, FSM state/transition 100 % |
| Code coverage `demo_csr_regs` | Statement 100 %, Branch 100 % |
| Mutation test (7 lỗi cài cố ý vào bridge) | 7/7 bị phát hiện |

Chi tiết phương pháp verification: [đặc tả IP, mục 12](docs/apb2csr_ip_spec.md#12-verification).

## 8. Xử lý sự cố

| Triệu chứng | Cách xử lý |
|---|---|
| `[lint:verilator] Verilator not found` | Cài Verilator vào `PATH` (Linux), hoặc cài trong WSL: `sudo apt install verilator` |
| Có nhiều WSL distro | `set APB2CSR_WSL_DISTRO=Ubuntu` (PowerShell: `$env:APB2CSR_WSL_DISTRO="Ubuntu"`) |
| `'vlog' not found in PATH` | Thêm thư mục `bin` của QuestaSim (vd. `C:\questasim64_10.7c\win64`) vào `PATH` |
| Spec YAML báo lỗi | `pip install pyyaml`, hoặc dùng JSON |
| Comment trong file `.vlt` gây lỗi cú pháp | Không bắt đầu comment bằng từ `verilator`: Verilator hiểu dòng đó là pragma |
