# apb2csr — Đặc tả IP (IP Specification)

| | |
|---|---|
| **IP** | `apb2csr` — AMBA APB4 slave to CSR bus bridge (+ generated register file) |
| **Phiên bản** | 1.1 |
| **Chuẩn bus** | AMBA APB Protocol Specification v2.0 (ARM IHI 0024C), APB4 |
| **RTL** | `rtl/apb2csr.sv` (SystemVerilog-2012, synthesizable, 1 module) |
| **Generator** | `tools/csrgen.py` v1.0.0 |

Tài liệu này mô tả **tính năng và hành vi** của IP. Hướng dẫn sinh register block và tích hợp nằm trong [README](../README.md).

---

## Mục lục

1. [Tổng quan](#1-tổng-quan)
2. [Tính năng](#2-tính-năng)
3. [Sơ đồ khối](#3-sơ-đồ-khối)
4. [Tham số](#4-tham-số)
5. [Giao tiếp tín hiệu](#5-giao-tiếp-tín-hiệu)
6. [Mô tả chức năng](#6-mô-tả-chức-năng)
7. [CSR bus protocol](#7-csr-bus-protocol)
8. [Timing](#8-timing)
9. [Register file sinh ra](#9-register-file-sinh-ra)
10. [Assertions](#10-assertions)
11. [Hiệu năng, tài nguyên và hướng dẫn tích hợp](#11-hiệu-năng-tài-nguyên-và-hướng-dẫn-tích-hợp)
12. [Verification](#12-verification)
13. [Giới hạn và hướng mở rộng](#13-giới-hạn-và-hướng-mở-rộng)
14. [Lịch sử phiên bản](#14-lịch-sử-phiên-bản)

---

## 1. Tổng quan

Peripheral nào trong SoC cũng cần một khối thanh ghi điều khiển/trạng thái (CSR) để CPU cấu hình và đọc trạng thái qua bus APB. `apb2csr` tách phần này làm hai lớp:

1. **`apb2csr` (bridge)**: lo toàn bộ giao thức APB4 (SETUP/ACCESS phase, wait state, `PSLVERR`, `PSTRB`, `PPROT`) và chuyển mỗi transfer thành một request đơn giản trên **CSR bus** nội bộ kiểu valid/ready.
2. **Register file**: chỉ cần hiểu CSR bus. Có thể được **sinh tự động** bởi `csrgen.py` từ spec JSON, hoặc viết tay.

Nhờ tách lớp, logic giao thức APB4 chỉ viết và verify **một lần**, còn mỗi dự án chỉ cần thay register map.

## 2. Tính năng

**Giao thức**
- APB4 slave đầy đủ: `PSEL`, `PENABLE`, `PADDR`, `PWRITE`, `PWDATA`, `PSTRB`, `PPROT`, `PREADY`, `PRDATA`, `PSLVERR`.
- Hỗ trợ data width 8, 16, 32 bit. Độ rộng `PADDR` và cửa sổ địa chỉ CSR có thể tham số hóa.
- Chế độ tương thích APB3 (`USE_PSTRB = 0`: bỏ qua `PSTRB`, ghi tất cả byte lane).

**Hiệu năng**
- **Zero wait state**: mỗi transfer 2 chu kỳ (mức tối thiểu của APB) khi slave trả lời ngay.
- **Output APB chỉ phụ thuộc vào flip-flop nội bộ**: `PRDATA` ra trực tiếp từ flop, còn `PREADY`/`PSLVERR` là giải mã của các flop trạng thái. Không có đường tổ hợp từ input APB sang output APB, nên timing closure ở interconnect dễ hơn.
- Hỗ trợ slave nhiều chu kỳ (wait state không giới hạn), cho phép transfer back-to-back.

**An toàn và bảo vệ**
- `PSLVERR` khi địa chỉ không align (tùy chọn).
- `PSLVERR` khi truy cập unprivileged (`PPROT[0]=0`) hoặc non-secure (`PPROT[1]=1`) (tùy chọn).
- Timeout cho slave bị treo: bus APB luôn được giải phóng (tùy chọn).
- Transfer bị từ chối tại bridge **không bao giờ** tới register file, nên không có side effect.
- `PRDATA = 0` cho mọi transfer lỗi và mọi transfer ghi, không làm lộ dữ liệu.

**Thiết kế cho tái sử dụng**
- Reset bất đồng bộ hoặc đồng bộ (`ASYNC_RESET`), tích cực mức thấp.
- Đúng một handshake CSR cho mỗi transfer được chuyển xuống, nên an toàn với thanh ghi có side effect khi đọc/ghi (read-to-clear, FIFO pop/push).
- SVA kiểm tra giao thức APB4 và CSR được nhúng sẵn (tự loại bỏ khi định nghĩa `SYNTHESIS`).
- Sạch lint dưới Questa (`-lint -pedanticerrors`) và Verilator (`-Wall`) trên toàn bộ ma trận tham số.

**Register generator (`csrgen.py`)**
- 7 kiểu access: `RW`, `RO`, `WO`, `W1C`, `W1S`, `RC`, `W1P`, cùng hằng số (`const`), hardware ghi (`hw_write`), strobe truy cập.
- Sinh RTL, wrapper APB4, SV package, C header, tài liệu Markdown từ cùng một nguồn.
- Validate spec chặt chẽ (chồng bit, trùng offset, reset tràn, gõ sai khóa, …).

## 3. Sơ đồ khối

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

Đường request (`csr_addr`, `csr_we`, `csr_wdata`, `csr_wstrb`, `csr_prot`) đi thẳng từ APB, không qua flop. Điều này an toàn vì APB4 bảo đảm các tín hiệu này ổn định từ SETUP cho tới khi transfer kết thúc. Đường response thì luôn được chốt vào thanh ghi.

## 4. Tham số

| Tham số | Kiểu | Mặc định | Giá trị hợp lệ | Mô tả |
|---|---|---|---|---|
| `APB_ADDR_WIDTH` | int | 32 | ≥ `CSR_ADDR_WIDTH` | Độ rộng `PADDR` |
| `DATA_WIDTH` | int | 32 | 8, 16, 32 | Độ rộng `PWDATA`/`PRDATA` và CSR data |
| `CSR_ADDR_WIDTH` | int | 12 | > log2(`DATA_WIDTH`/8), ≤ `APB_ADDR_WIDTH` | Độ rộng địa chỉ byte phía CSR = `PADDR[CSR_ADDR_WIDTH-1:0]` |
| `USE_PSTRB` | bit | 1 | 0, 1 | 1: APB4, `csr_wstrb = PSTRB`; 0: `csr_wstrb` = toàn 1 khi ghi |
| `ERR_UNALIGNED` | bit | 1 | 0, 1 | 1: `PSLVERR` nếu `PADDR[log2(DW/8)-1:0] ≠ 0`; 0: chuyển xuống, slave bỏ qua bit thấp |
| `PRIV_ONLY` | bit | 0 | 0, 1 | 1: `PSLVERR` nếu `PPROT[0] = 0` (unprivileged) |
| `SECURE_ONLY` | bit | 0 | 0, 1 | 1: `PSLVERR` nếu `PPROT[1] = 1` (non-secure) |
| `TIMEOUT_CYCLES` | int | 0 | 0 … 2³¹ | 0: tắt; N: `PSLVERR` nếu không có `csr_ack` sau N chu kỳ chờ |
| `ASYNC_RESET` | bit | 1 | 0, 1 | 1: `PRESETn` bất đồng bộ; 0: đồng bộ |

Nếu `DATA_WIDTH` hoặc `CSR_ADDR_WIDTH` nằm ngoài khoảng hợp lệ, mô phỏng sẽ dừng bằng `$fatal` ngay lúc khởi tạo.

## 5. Giao tiếp tín hiệu

### 5.1 Clock và reset

| Tín hiệu | Hướng | Độ rộng | Mô tả |
|---|---|---|---|
| `pclk` | in | 1 | Clock APB. Mọi flop chạy ở cạnh lên |
| `presetn` | in | 1 | Reset tích cực mức thấp; kiểu bất đồng bộ hay đồng bộ do `ASYNC_RESET` quyết định |

### 5.2 APB4 slave

| Tín hiệu | Hướng | Độ rộng | Mô tả |
|---|---|---|---|
| `psel` | in | 1 | Slave được chọn (từ address decoder của interconnect) |
| `penable` | in | 1 | 0: SETUP phase, 1: ACCESS phase |
| `paddr` | in | `APB_ADDR_WIDTH` | Địa chỉ byte. Chỉ `[CSR_ADDR_WIDTH-1:0]` được dùng |
| `pwrite` | in | 1 | 1: ghi, 0: đọc |
| `pwdata` | in | `DATA_WIDTH` | Dữ liệu ghi |
| `pstrb` | in | `DATA_WIDTH/8` | Byte strobe ghi (phải = 0 khi đọc, theo APB4) |
| `pprot` | in | 3 | `[0]` privileged, `[1]` non-secure, `[2]` instruction |
| `pready` | out | 1 | Transfer hoàn tất ở chu kỳ ACCESS này (giải mã từ flop trạng thái) |
| `prdata` | out | `DATA_WIDTH` | Dữ liệu đọc, hợp lệ khi `pready=1` và đọc thành công (output flop) |
| `pslverr` | out | 1 | Lỗi transfer; chỉ = 1 khi `pready=1` (AND của 2 flop) |

### 5.3 CSR master

| Tín hiệu | Hướng | Độ rộng | Mô tả |
|---|---|---|---|
| `csr_req` | out | 1 | Có request; giữ = 1 cho tới khi `csr_ack` (hoặc timeout) |
| `csr_we` | out | 1 | 1: ghi, 0: đọc |
| `csr_addr` | out | `CSR_ADDR_WIDTH` | Địa chỉ byte (= `paddr[CSR_ADDR_WIDTH-1:0]`) |
| `csr_wdata` | out | `DATA_WIDTH` | Dữ liệu ghi |
| `csr_wstrb` | out | `DATA_WIDTH/8` | Byte strobe; luôn = 0 khi đọc |
| `csr_prot` | out | 3 | `pprot` chuyển tiếp, để slave tự kiểm tra quyền chi tiết hơn nếu cần |
| `csr_ack` | in | 1 | Slave hoàn tất request (1 chu kỳ) |
| `csr_rdata` | in | `DATA_WIDTH` | Dữ liệu đọc, lấy mẫu khi `csr_ack=1` |
| `csr_err` | in | 1 | Slave báo lỗi, lấy mẫu khi `csr_ack=1` |

## 6. Mô tả chức năng

### 6.1 FSM điều khiển

| Trạng thái | Ý nghĩa | `pready` | `csr_req` |
|---|---|---|---|
| `S_IDLE` | Chờ SETUP phase | 0 | = `setup & ~local_err` |
| `S_WAIT` | Request đang chờ slave trả lời | 0 | 1 |
| `S_RESP` | Response đã chốt; chu kỳ ACCESS cuối | 1 | 0 |

| Từ | Điều kiện | Tới | Hành động |
|---|---|---|---|
| `S_IDLE` | SETUP & lỗi cục bộ | `S_RESP` | chốt `err=1`, `data=0` (không gửi request) |
| `S_IDLE` | SETUP & `csr_ack` | `S_RESP` | chốt `csr_err`, `csr_rdata` (đã mask) |
| `S_IDLE` | SETUP & `~csr_ack` | `S_WAIT` | – |
| `S_WAIT` | `csr_ack` | `S_RESP` | chốt `csr_err`, `csr_rdata` (đã mask) |
| `S_WAIT` | timeout | `S_RESP` | chốt `err=1`, `data=0`; `csr_req` hạ |
| `S_RESP` | `PSEL & PENABLE` | `S_IDLE` | transfer kết thúc |
| bất kỳ | reset | `S_IDLE` | xóa response |

### 6.2 Phát request trong SETUP phase

Điểm mấu chốt: request được phát **ngay trong SETUP phase** (`PSEL=1, PENABLE=0`), sớm hơn một chu kỳ so với cách làm thông thường (chờ ACCESS). Nếu slave trả lời cùng chu kỳ, response được chốt vào flop ở cạnh clock cuối SETUP và xuất hiện ở ACCESS phase với `PREADY=1`. Nhờ vậy IP vừa có **output registered** vừa đạt **zero wait state**.

Thực hiện thao tác ghi trong SETUP phase là hợp lệ, vì APB không cho master hủy transfer đã bắt đầu: mỗi SETUP chắc chắn được theo sau bởi ACCESS.

### 6.3 Nhận response

- `rsp_data_q ← (PWRITE | csr_err) ? 0 : csr_rdata`, `rsp_err_q ← csr_err`, chốt ở chu kỳ `csr_ack = 1`.
- `PRDATA` giữ giá trị của lần đọc gần nhất cho tới transfer kế tiếp. Giá trị chỉ có nghĩa khi `PREADY=1`.
- `PSLVERR = (state = S_RESP) & rsp_err_q`, nên bằng 0 ở mọi chu kỳ khác (APB4 khuyến nghị).

### 6.4 Byte strobe (`PSTRB`)

| Điều kiện | `csr_wstrb` |
|---|---|
| Đọc (`PWRITE=0`) | `'0` |
| Ghi, `USE_PSTRB=1` | `PSTRB` |
| Ghi, `USE_PSTRB=0` | `'1` (mọi byte lane) |

Ghi với `PSTRB = 0` là hợp lệ: transfer vẫn được chuyển xuống nhưng không byte nào bị thay đổi.

### 6.5 Kiểm tra alignment

Khi `ERR_UNALIGNED=1` và `DATA_WIDTH > 8`, các bit `PADDR[log2(DATA_WIDTH/8)-1:0]` phải bằng 0, nếu không bridge trả `PSLVERR` mà không gửi request. Khi `ERR_UNALIGNED=0`, transfer được chuyển xuống nguyên địa chỉ và register file sinh ra bỏ qua các bit thấp (truy cập word chứa địa chỉ đó).

### 6.6 Bảo vệ theo `PPROT`

| `PRIV_ONLY` | `SECURE_ONLY` | Bị từ chối khi |
|---|---|---|
| 0 | 0 | không bao giờ |
| 1 | 0 | `PPROT[0] = 0` |
| 0 | 1 | `PPROT[1] = 1` |
| 1 | 1 | `PPROT[0] = 0` **hoặc** `PPROT[1] = 1` |

Kiểm tra áp dụng cho cả đọc lẫn ghi. Nếu cần chính sách chi tiết hơn (ví dụ chỉ bảo vệ một vài thanh ghi), slave có thể dùng `csr_prot` và trả `csr_err`.

### 6.7 Timeout

Khi `TIMEOUT_CYCLES = N > 0`, một bộ đếm `max(1, ⌈log2 N⌉)` bit đếm số chu kỳ ở `S_WAIT`. Slave có tổng cộng **N + 1 chu kỳ** `csr_req` (chu kỳ SETUP + N chu kỳ chờ) để trả `csr_ack`. Hết thời hạn, bridge hạ `csr_req`, trả `PSLVERR` và `PRDATA = 0`. Transfer lúc đó dài đúng **N + 2 chu kỳ**. `csr_ack` có ưu tiên cao hơn timeout nếu cả hai cùng xảy ra.

Sau timeout, slave bị coi là hỏng. Slave **không được** trả `csr_ack` cho request cũ khi `csr_req` đã hạ (xem §7).

### 6.8 Reset

| Tín hiệu / trạng thái | Giá trị khi reset |
|---|---|
| FSM | `S_IDLE` |
| `pready`, `pslverr` | 0 |
| `prdata` | 0 |
| `csr_req` | 0, **với điều kiện `PSEL = 0`** (`csr_req` là tổ hợp của `PSEL`/`PENABLE` ở `S_IDLE`; APB master phải giữ `PSEL` thấp khi reset) |
| Bộ đếm timeout | 0 |

Khi `ASYNC_RESET=1`, output về giá trị reset **ngay lập tức** khi `presetn` xuống thấp, kể cả lúc đang có request (đã verify). Khi `ASYNC_RESET=0`, việc này xảy ra ở cạnh clock kế tiếp.

### 6.9 Ma trận xử lý lỗi

| Tình huống | `PSLVERR` | Request tới slave? | `PRDATA` | Số chu kỳ transfer |
|---|---|---|---|---|
| Thành công | 0 | Có (1 handshake) | dữ liệu (đọc) / 0 (ghi) | 2 + latency slave |
| Không align (`ERR_UNALIGNED=1`) | 1 | **Không** | 0 | 2 |
| Vi phạm `PPROT` | 1 | **Không** | 0 | 2 |
| Slave trả `csr_err` | 1 | Có | 0 | 2 + latency slave |
| Timeout | 1 | Có (bị hủy, không handshake) | 0 | `TIMEOUT_CYCLES` + 2 |

Theo APB4, khi ghi bị lỗi thì trạng thái thanh ghi có thể đã thay đổi hoặc không. Với `apb2csr`: lỗi cục bộ (alignment, `PPROT`) **chắc chắn không** thay đổi gì; lỗi do slave báo tùy thuộc vào slave. Register file sinh ra không ghi vào địa chỉ không được map.

## 7. CSR bus protocol

CSR bus là giao thức request/acknowledge đồng bộ với `pclk`. Bridge là master; register file (hoặc slave tự viết) là slave.

**Quy tắc cho master (bridge đảm bảo):**
1. `csr_req=1` đi kèm `csr_we`, `csr_addr`, `csr_wdata`, `csr_wstrb`, `csr_prot` **ổn định** cho tới chu kỳ `csr_ack=1`.
2. `csr_req` chỉ hạ trước khi có ack trong hai trường hợp: timeout hoặc reset.
3. Mỗi transfer APB được chuyển xuống tạo ra **đúng một** chu kỳ `csr_req & csr_ack`.
4. `csr_wstrb = 0` khi `csr_we = 0`.

**Quy tắc cho slave (người viết slave phải tuân thủ):**
1. `csr_ack`, `csr_rdata`, `csr_err` chỉ có nghĩa khi `csr_req=1`; bridge bỏ qua chúng khi `csr_req=0`.
2. Trả `csr_ack=1` **đúng một chu kỳ** cho mỗi request. Có thể trả ngay chu kỳ đầu (`csr_ack` tổ hợp từ `csr_req`) hoặc trễ bất kỳ.
3. Side effect (ghi, read-to-clear, pop) chỉ thực hiện ở chu kỳ `csr_req & csr_ack`.
4. Nếu `csr_req` hạ trước khi có ack (timeout), hãy hủy request và không ack nữa.

**Ví dụ slave latency 1 chu kỳ** (đăng ký response để cắt đường timing dài):

```systemverilog
logic ack_q;
always_ff @(posedge pclk or negedge presetn)
  if (!presetn) ack_q <= 1'b0;
  else          ack_q <= csr_req & ~ack_q;     // ack 1 chu kỳ sau request
assign csr_ack = ack_q;                        // csr_req vẫn đang = 1 ở chu kỳ này
// csr_rdata / csr_err phải hợp lệ ở chu kỳ csr_ack = 1; side effect thực hiện khi csr_req & csr_ack
```

## 8. Timing

Mỗi cột là một chu kỳ clock. Giá trị trong cột là giá trị ổn định của tín hiệu trong chu kỳ đó, được lấy mẫu ở cạnh lên cuối chu kỳ.

### 8.1 Đọc zero wait state (slave ack ngay)

| Chu kỳ | 1 | 2 | 3 |
|---|---|---|---|
| APB phase | SETUP | ACCESS | IDLE |
| `PSEL` / `PENABLE` | 1 / 0 | 1 / 1 | 0 / 0 |
| `PADDR`, `PWRITE` | A, 0 | A, 0 | – |
| `state_q` | IDLE | RESP | IDLE |
| `csr_req` / `csr_ack` | **1 / 1** | 0 / 0 | 0 / 0 |
| `csr_rdata` | D | – | – |
| `PREADY` | 0 | **1** | 0 |
| `PRDATA` | – | **D** | D (giữ) |
| `PSLVERR` | 0 | 0 | 0 |

Transfer dài 2 chu kỳ. Transfer kế tiếp có thể bắt đầu SETUP ngay ở chu kỳ 3 (back-to-back).

### 8.2 Ghi, slave latency 2 chu kỳ

| Chu kỳ | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| APB phase | SETUP | ACCESS | ACCESS | ACCESS |
| `state_q` | IDLE | WAIT | WAIT | RESP |
| `csr_req` | 1 | 1 | 1 | 0 |
| `csr_ack` | 0 | 0 | **1** | 0 |
| `PREADY` | 0 | 0 | 0 | **1** |

Tổng quát: slave latency L (ack ở chu kỳ thứ L+1 kể từ SETUP) cho transfer dài **L + 2 chu kỳ**.

### 8.3 Timeout (`TIMEOUT_CYCLES = 3`, slave không trả lời)

| Chu kỳ | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| APB phase | SETUP | ACCESS | ACCESS | ACCESS | ACCESS |
| `state_q` | IDLE | WAIT | WAIT | WAIT | RESP |
| `tmo_cnt_q` | 0 | 0 | 1 | 2 | 3 |
| `timeout` | 0 | 0 | 0 | **1** | 0 |
| `csr_req` | 1 | 1 | 1 | 1 | 0 |
| `PREADY` / `PSLVERR` | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | **1 / 1** |

`csr_req` ở mức 1 trong `TIMEOUT_CYCLES + 1` = 4 chu kỳ. Transfer dài `TIMEOUT_CYCLES + 2` = 5 chu kỳ.

### 8.4 Lỗi cục bộ (không align / `PPROT`)

| Chu kỳ | 1 | 2 |
|---|---|---|
| APB phase | SETUP | ACCESS |
| `state_q` | IDLE | RESP |
| `csr_req` | **0** | 0 |
| `PREADY` / `PSLVERR` | 0 / 0 | **1 / 1** |
| `PRDATA` | – | 0 |

## 9. Register file sinh ra

`csrgen.py` sinh module `<name>_csr_regs` (slave trên CSR bus) và `<name>_apb_csr` (wrapper APB4). Các tính năng:

### 9.1 Giao tiếp và decode
- `csr_ack = csr_req` (zero latency), nên mọi transfer APB tới register file đều dài 2 chu kỳ.
- Decode theo word: `word_addr = csr_addr[AW-1:log2(DW/8)]`. Các bit byte offset bị bỏ qua (alignment đã do bridge kiểm tra).
- Địa chỉ không map: `csr_err = 1` (`error_on_unmapped: true`) hoặc RAZ/WI (`false`).
- Byte mask: `wmask[i] = csr_wstrb[i/8]`, áp dụng cho mọi field ghi được.

### 9.2 Ngữ nghĩa từng kiểu access

Ký hiệu: `wr` = SW ghi thanh ghi này, `rd` = SW đọc thanh ghi này, `d` = `csr_wdata[field]`, `m` = `wmask[field]`.

| Access | Phương trình cập nhật (mỗi cạnh clock) | Giá trị SW đọc |
|---|---|---|
| `RW` | `wr ? (q & ~m) \| (d & m) : (hw_we ? hw_d : q)` | `q` |
| `WO` | `wr ? (q & ~m) \| (d & m) : q` | 0 |
| `W1C` | `(q & ~(d & m & wr)) \| set_i` | `q` |
| `W1S` | `(q & ~clr_i) \| (d & m & wr)` | `q` |
| `RC` | `(q & ~rd) \| set_i` | `q` (trước khi xóa) |
| `W1P` | `d & m & wr` (xung 1 chu kỳ) | 0 |
| `RO` | – (không có flop) | `_i` hoặc hằng số `reset` |

Quy tắc ưu tiên được chọn để **không mất sự kiện**: với `W1C`/`RC`, hardware set thắng software clear; với `W1S`, software set thắng hardware clear; với `RW` + `hw_write`, software thắng.

### 9.3 Strobe truy cập
Thanh ghi có `"strobe": true` xuất `<reg>_wr_o` và `<reg>_rd_o`, mỗi cái là xung đúng 1 chu kỳ cho mỗi lần SW ghi/đọc. Bridge bảo đảm một handshake cho mỗi transfer, nên một lần đọc APB tạo đúng một xung `_rd_o`. Hai strobe này dùng để push/pop FIFO.

### 9.4 Reset
Mọi flop reset về giá trị `reset` trong spec. Kiểu reset (`async`/`sync`) áp dụng **đồng thời** cho register file và bridge trong wrapper, nhờ vậy cả IP chỉ có một kiểu reset trên `presetn`.

### 9.5 Đầu ra phụ
- `<name>_csr_pkg.sv`: hằng số offset, reset, mask, LSB, width để testbench và RTL khác dùng.
- `<name>_csr.h`: macro truy cập cho firmware (`_OFFSET`, `_MASK`, `_SHIFT`, `_GET()`, `_SET()`).
- `<name>_csr.md`: tài liệu register map, có liệt kê cả vùng bit reserved.

## 10. Assertions

Nhúng trong `apb2csr.sv`, chỉ được biên dịch khi **không** định nghĩa `SYNTHESIS`. Mọi assertion đều có `disable iff (!presetn)`.

| Tên | Kiểm tra |
|---|---|
| `a_apb_penable_psel` | `PENABLE` chỉ được bật khi có `PSEL` |
| `a_apb_setup_access` | Sau SETUP luôn là ACCESS |
| `a_apb_stable` | `PADDR`, `PWRITE`, `PPROT` (và `PWDATA`, `PSTRB` khi ghi) ổn định suốt transfer |
| `a_apb4_pstrb_read` | `PSTRB = 0` khi đọc (APB4) |
| `a_apb_ctrl_known` | Không có X/Z trên `PSEL`, `PENABLE` |
| `a_apb_addr_known` | Không có X/Z trên `PADDR`, `PWRITE`, `PPROT` khi `PSEL=1` |
| `a_apb_wdata_known` | Không có X/Z trên `PWDATA`, `PSTRB` khi ghi |
| `a_apb_access_after_setup` | Không có ACCESS phase nào thiếu SETUP phase trước đó |
| `a_pslverr_pready` | `PSLVERR` chỉ đi cùng `PREADY` |
| `a_csr_req_hold` | `csr_req` được giữ cho tới khi có ack (trừ timeout) |
| (initial) | `DATA_WIDTH` ∈ {8,16,32}; `CSR_ADDR_WIDTH` hợp lệ |

Các assertion này hoạt động như một **protocol checker miễn phí** cho APB master/interconnect trong mô phỏng SoC.

## 11. Hiệu năng, tài nguyên và hướng dẫn tích hợp

### 11.1 Hiệu năng

| Chỉ số | Giá trị |
|---|---|
| Thời gian transfer | 2 chu kỳ + latency slave (2 với register file sinh ra) |
| Throughput tối đa | 1 transfer / 2 chu kỳ (giới hạn của chính giao thức APB) |
| Latency từ input APB tới output APB | luôn qua ít nhất 1 flop |

### 11.2 Tài nguyên (bridge)

| Thành phần | Số flip-flop |
|---|---|
| FSM | 2 |
| `rsp_err_q` | 1 |
| `rsp_data_q` | `DATA_WIDTH` |
| Bộ đếm timeout | `max(1, ⌈log2 TIMEOUT_CYCLES⌉)` nếu `TIMEOUT_CYCLES > 0`, ngược lại 0 |
| **Tổng (DW=32, không timeout)** | **35** |

Register file sinh ra dùng 1 flop cho mỗi bit của field `RW`, `WO`, `W1C`, `W1S`, `RC`, `W1P`. Field `RO` không tốn flop.

### 11.3 Đường timing quan trọng

Ở chế độ zero latency, đường tổ hợp dài nhất nằm trong **một chu kỳ**:
`PADDR`/`PSEL` → `csr_req`/`csr_addr` → decode + read mux của slave → `csr_rdata` → mask → `rsp_data_q`.

Với register file sinh ra, đường này chỉ gồm so sánh địa chỉ và một mux OR, thường không đáng lo ở tần số APB. Nếu không đạt timing (register map lớn, tần số cao), hãy cho slave đăng ký response (latency 1, xem §7). Bridge xử lý wait state một cách tự động, đổi lại mỗi transfer dài thêm 1 chu kỳ.

### 11.4 Hướng dẫn tích hợp

| Chủ đề | Khuyến nghị |
|---|---|
| Base address | Decode trong APB interconnect (sinh `PSEL`). Bridge chỉ dùng `PADDR[CSR_ADDR_WIDTH-1:0]`; các bit cao được cố ý bỏ qua |
| Kích thước cửa sổ | 2^`CSR_ADDR_WIDTH` byte, nên cho khớp với vùng địa chỉ cấp cho peripheral |
| Clock domain | Bridge và register file chạy cùng `pclk`. Nếu logic CSR ở clock khác, đặt bộ đồng bộ handshake (CDC) trên CSR bus và bật `TIMEOUT_CYCLES` |
| Chọn `TIMEOUT_CYCLES` | Lớn hơn latency tối đa của slave (gồm cả CDC). Với register file sinh ra thì đặt 0 |
| Reset | Dùng cùng một kiểu reset cho cả IP (`ASYNC_RESET` khớp `reset_type`; wrapper sinh ra tự làm việc này) |
| Ngắt | Ghép `W1C` status với `RW` enable bên ngoài: `irq = |(status & enable)` |
| Nhiều peripheral | Mỗi peripheral một instance; mux `PRDATA`/`PREADY`/`PSLVERR` theo `PSEL` ở interconnect |

## 12. Verification

### 12.1 Môi trường
- **APB4 master BFM** (`tb/apb4_master_if.sv`): transfer back-to-back, `PSTRB=0` khi đọc, xáo trộn bus khi idle để phát hiện việc dùng giá trị cũ.
- **`tb_apb2csr`**: bridge + CSR slave hành vi có latency ngẫu nhiên, vùng địa chỉ trả lỗi và một word "treo" để test timeout. Scoreboard so sánh với reference model.
- **`tb_demo_apb_csr`**: test có hướng cho IP sinh ra từ `spec/demo.json`, phủ mọi kiểu access.

### 12.2 Kiểm tra trên mỗi transfer
Dữ liệu đọc so với reference model; `PSLVERR` mong đợi; **số chu kỳ chính xác** (2 + latency, `TIMEOUT_CYCLES + 2`, 2 với lỗi cục bộ); đúng 0 hoặc 1 handshake CSR; độ ổn định của CSR request; `csr_wstrb = 0` khi đọc; không có `csr_req` khi không có `PSEL`.

### 12.3 Kịch bản
Quét toàn bộ địa chỉ, mọi tổ hợp `PSTRB`, vùng lỗi của slave, địa chỉ không align, cả 8 giá trị `PPROT`, timeout, ~3000 transfer ngẫu nhiên có khoảng nghỉ ngẫu nhiên, reset giữa transfer đang chờ, đọc lại toàn bộ để kiểm tra nhất quán.

### 12.4 Ma trận regression (12 cấu hình)
DW 32/16/8; zero-wait; latency 12 không timeout; `TIMEOUT_CYCLES=1`; `USE_PSTRB=0`; `ERR_UNALIGNED=0`; `PRIV_ONLY+SECURE_ONLY`; `CSR_ADDR_WIDTH=6`; `ASYNC_RESET=0`; IP demo.

### 12.5 Kết quả

| Hạng mục | Kết quả |
|---|---|
| Regression | 36/36 PASS (12 cấu hình × 3 seed) |
| Coverage `apb2csr` | Statement 100 %, Branch 97 %, FSM state + transition 100 % |
| Coverage `demo_csr_regs` | Statement 100 %, Branch 100 % |
| Mutation test | 7/7 lỗi cài cố ý bị phát hiện (rdata không mask, bỏ qua `PSTRB`, mất `csr_err`, timeout lệch 1, `csr_req` không giữ, mất kiểm tra alignment, bỏ qua latency) |
| Lint Questa 10.7c | 0 error / 0 warning |
| Lint Verilator 5.020 `-Wall` | 0 error / 0 warning (1 waiver có lý do, chỉ ở chế độ có SVA) |

Nhánh duy nhất chưa được phủ là "giữ `S_RESP` khi không có ACCESS phase". Nhánh này không thể xảy ra với master APB4 hợp lệ và được giữ lại làm code phòng vệ.

## 13. Giới hạn và hướng mở rộng

| Giới hạn | Hướng mở rộng |
|---|---|
| Chưa có CDC tích hợp | Thêm `apb2csr_cdc` (handshake synchronizer 4-phase trên CSR bus) |
| Không hỗ trợ APB5 (`PWAKEUP`, `PAUSER`, `PNSE`, parity) | Thêm tham số `APB5_EN` |
| Data width tối đa 32 bit (đúng chuẩn APB) | – |
| Generator chưa hỗ trợ register array, field có khóa (lock), alias | Mở rộng schema trong `csrgen.py` |
| Chưa sinh UVM RAL model | Thêm `gen_ral()` dùng `uvm_reg` |

## 14. Lịch sử phiên bản

| Phiên bản | Thay đổi |
|---|---|
| 1.0 | Bản đầu: bridge APB4, `csrgen.py`, flow Questa |
| 1.1 | Thêm tham số `ASYNC_RESET` (wrapper sinh ra khớp với `reset_type` của spec); sink cho bit cao `PADDR` không dùng; generator chỉ khai báo tín hiệu cần dùng; thêm lint Verilator `-Wall` vào flow; thêm `spec/gpio16.json` và cấu hình regression `sync_reset` |
