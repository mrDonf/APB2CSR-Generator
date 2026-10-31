#!/usr/bin/env python3
"""
csrgen.py - CSR register block generator for the apb2csr IP.

Reads a register specification (JSON, or YAML when PyYAML is installed) and
generates:
    <name>_csr_pkg.sv   SystemVerilog package: offsets, reset values, field masks
    <name>_csr_regs.sv  Register file on the generic CSR bus (csr_req/csr_ack)
    <name>_apb_csr.sv   APB slave top = apb2csr bridge + register file
    <name>_csr.h        C header for firmware / drivers
    <name>_csr.md       Register map documentation

Usage:
    python tools/csrgen.py spec/demo.json -o generated/demo
    python tools/csrgen.py spec/demo.json --check        # validate only

Supported field access types:
    RW   read/write                     hw: <reg>_<fld>_o  [+ _we_i/_d_i if "hw_write"]
    RO   read-only, value from hardware hw: <reg>_<fld>_i  (or constant if "const")
    WO   write-only (reads return 0)    hw: <reg>_<fld>_o
    W1C  write 1 to clear, hw sets      hw: <reg>_<fld>_o, <reg>_<fld>_set_i
    W1S  write 1 to set, hw clears      hw: <reg>_<fld>_o, <reg>_<fld>_clr_i
    RC   clear on read, hw sets         hw: <reg>_<fld>_o, <reg>_<fld>_set_i
    W1P  write 1 -> 1-cycle pulse       hw: <reg>_<fld>_o  (reads return 0)
Register option "strobe": true adds <reg>_wr_o / <reg>_rd_o access pulses.
"""

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional

TOOL_VERSION = "1.0.0"

ACCESS_TYPES = ("RW", "RO", "WO", "W1C", "W1S", "RC", "W1P")

SV_KEYWORDS = {
    "always", "and", "assign", "begin", "bit", "buf", "byte", "case", "class",
    "const", "default", "do", "else", "end", "endcase", "endmodule", "enum",
    "for", "function", "if", "initial", "inout", "input", "int", "integer",
    "logic", "module", "nand", "nor", "not", "or", "output", "package",
    "parameter", "reg", "return", "signed", "string", "struct", "task",
    "type", "union", "unsigned", "wire", "while", "xnor", "xor",
}

IDENT_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")


class SpecError(Exception):
    pass


# =============================================================================
# Data model
# =============================================================================
@dataclass
class Field:
    name: str
    msb: int
    lsb: int
    access: str
    reset: int = 0
    desc: str = ""
    hw_write: bool = False
    const: bool = False

    @property
    def width(self) -> int:
        return self.msb - self.lsb + 1

    @property
    def mask(self) -> int:
        return ((1 << self.width) - 1) << self.lsb

    @property
    def has_storage(self) -> bool:
        return self.access in ("RW", "WO", "W1C", "W1S", "RC", "W1P")

    @property
    def sw_readable(self) -> bool:
        return self.access in ("RW", "RO", "W1C", "W1S", "RC")

    @property
    def sw_writable(self) -> bool:
        return self.access in ("RW", "WO", "W1C", "W1S", "W1P")

    @property
    def read_reset(self) -> int:
        """Value read by software after reset (hardware inputs assumed 0)."""
        if self.access == "RO":
            return self.reset if self.const else 0
        if self.access in ("WO", "W1P"):
            return 0
        return self.reset


@dataclass
class Register:
    name: str
    offset: int
    desc: str = ""
    strobe: bool = False
    fields: List[Field] = field(default_factory=list)

    @property
    def read_reset(self) -> int:
        v = 0
        for f in self.fields:
            v |= (f.read_reset << f.lsb)
        return v

    @property
    def needs_wr(self) -> bool:
        return self.strobe or any(f.sw_writable for f in self.fields)

    @property
    def needs_rd(self) -> bool:
        return self.strobe or any(f.access == "RC" for f in self.fields)


@dataclass
class Block:
    name: str
    desc: str
    data_width: int
    addr_width: int
    error_on_unmapped: bool
    reset_type: str
    registers: List[Register]
    source: str = ""

    @property
    def strb_width(self) -> int:
        return self.data_width // 8

    @property
    def addr_lsb(self) -> int:
        return (self.strb_width - 1).bit_length()


# =============================================================================
# Spec parsing / validation
# =============================================================================
def parse_int(value, what: str) -> int:
    if isinstance(value, bool):
        raise SpecError(f"{what}: boolean is not a valid integer")
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value.replace("_", ""), 0)
        except ValueError:
            pass
    raise SpecError(f"{what}: cannot parse integer from {value!r}")


def parse_bits(spec: dict, what: str):
    if "bits" in spec:
        b = spec["bits"]
        if isinstance(b, int):
            return b, b
        m = re.fullmatch(r"\s*(\d+)\s*(?::\s*(\d+)\s*)?", str(b))
        if not m:
            raise SpecError(f"{what}: bad 'bits' value {b!r} (use \"msb:lsb\" or \"n\")")
        msb = int(m.group(1))
        lsb = int(m.group(2)) if m.group(2) is not None else msb
        return msb, lsb
    if "lsb" in spec:
        lsb = parse_int(spec["lsb"], f"{what}.lsb")
        width = parse_int(spec.get("width", 1), f"{what}.width")
        return lsb + width - 1, lsb
    raise SpecError(f"{what}: missing 'bits' (or 'lsb'/'width')")


def check_ident(name, what: str) -> str:
    if not isinstance(name, str) or not IDENT_RE.match(name):
        raise SpecError(f"{what}: invalid identifier {name!r}")
    if name.lower() in SV_KEYWORDS:
        raise SpecError(f"{what}: {name!r} is a reserved SystemVerilog keyword")
    return name


def check_keys(d: dict, allowed: set, what: str):
    unknown = set(d) - allowed
    if unknown:
        raise SpecError(f"{what}: unknown key(s) {sorted(unknown)}; allowed: {sorted(allowed)}")


def load_spec(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    if path.suffix.lower() in (".yaml", ".yml"):
        try:
            import yaml  # type: ignore
        except ImportError:
            raise SpecError("YAML spec requires PyYAML (pip install pyyaml); or use JSON")
        return yaml.safe_load(text)
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        raise SpecError(f"{path}: JSON error: {e}")


def build_block(raw: dict, source: str) -> Block:
    if not isinstance(raw, dict):
        raise SpecError("top level of spec must be an object")
    check_keys(raw, {"name", "description", "data_width", "addr_width",
                     "error_on_unmapped", "reset_type", "registers"}, "spec")

    name = check_ident(raw.get("name"), "spec.name").lower()
    dw = parse_int(raw.get("data_width", 32), "spec.data_width")
    if dw not in (8, 16, 32):
        raise SpecError(f"spec.data_width must be 8, 16 or 32 (got {dw})")
    reset_type = raw.get("reset_type", "async")
    if reset_type not in ("async", "sync"):
        raise SpecError("spec.reset_type must be 'async' or 'sync'")

    regs_raw = raw.get("registers")
    if not isinstance(regs_raw, list) or not regs_raw:
        raise SpecError("spec.registers must be a non-empty list")

    blk = Block(
        name=name,
        desc=str(raw.get("description", "")),
        data_width=dw,
        addr_width=0,
        error_on_unmapped=bool(raw.get("error_on_unmapped", True)),
        reset_type=reset_type,
        registers=[],
        source=source,
    )
    bpw = blk.strb_width

    reg_names, offsets = set(), {}
    for ri, r in enumerate(regs_raw):
        rw = f"registers[{ri}]"
        if not isinstance(r, dict):
            raise SpecError(f"{rw}: must be an object")
        check_keys(r, {"name", "offset", "description", "desc", "strobe", "fields"}, rw)
        rname = check_ident(r.get("name"), f"{rw}.name").upper()
        rw = f"register {rname}"
        if rname in reg_names:
            raise SpecError(f"{rw}: duplicate register name")
        reg_names.add(rname)

        off = parse_int(r.get("offset"), f"{rw}.offset")
        if off < 0 or off % bpw:
            raise SpecError(f"{rw}: offset 0x{off:x} not aligned to {bpw} bytes")
        if off in offsets:
            raise SpecError(f"{rw}: offset 0x{off:x} already used by {offsets[off]}")
        offsets[off] = rname

        reg = Register(name=rname, offset=off,
                       desc=str(r.get("description", r.get("desc", ""))),
                       strobe=bool(r.get("strobe", False)))

        fields_raw = r.get("fields")
        if not isinstance(fields_raw, list) or not fields_raw:
            raise SpecError(f"{rw}: 'fields' must be a non-empty list")
        used_bits = 0
        fnames = set()
        for fi, f in enumerate(fields_raw):
            fw = f"{rw}.fields[{fi}]"
            if not isinstance(f, dict):
                raise SpecError(f"{fw}: must be an object")
            check_keys(f, {"name", "bits", "lsb", "width", "access", "reset",
                           "description", "desc", "hw_write", "const"}, fw)
            fname = check_ident(f.get("name"), f"{fw}.name").upper()
            fw = f"field {rname}.{fname}"
            if fname in fnames:
                raise SpecError(f"{fw}: duplicate field name")
            fnames.add(fname)

            msb, lsb = parse_bits(f, fw)
            if lsb > msb:
                raise SpecError(f"{fw}: lsb ({lsb}) > msb ({msb})")
            if msb >= dw:
                raise SpecError(f"{fw}: bit {msb} outside data width {dw}")

            access = str(f.get("access", "RW")).upper()
            if access not in ACCESS_TYPES:
                raise SpecError(f"{fw}: access {access!r} not in {ACCESS_TYPES}")

            fld = Field(name=fname, msb=msb, lsb=lsb, access=access,
                        reset=parse_int(f.get("reset", 0), f"{fw}.reset"),
                        desc=str(f.get("description", f.get("desc", ""))),
                        hw_write=bool(f.get("hw_write", False)),
                        const=bool(f.get("const", False)))

            if fld.reset < 0 or fld.reset >> fld.width:
                raise SpecError(f"{fw}: reset 0x{fld.reset:x} does not fit in {fld.width} bit(s)")
            if fld.hw_write and access != "RW":
                raise SpecError(f"{fw}: 'hw_write' is only allowed for RW fields")
            if fld.const and access != "RO":
                raise SpecError(f"{fw}: 'const' is only allowed for RO fields")
            if access == "W1P" and fld.reset:
                raise SpecError(f"{fw}: W1P fields always reset to 0")
            if used_bits & fld.mask:
                raise SpecError(f"{fw}: bits [{msb}:{lsb}] overlap another field")
            used_bits |= fld.mask
            reg.fields.append(fld)

        reg.fields.sort(key=lambda x: x.lsb)
        blk.registers.append(reg)

    blk.registers.sort(key=lambda x: x.offset)

    # Address width: explicit or minimum needed
    max_off = max(r.offset for r in blk.registers)
    min_aw = max(max_off.bit_length(), blk.addr_lsb + 1)
    if "addr_width" in raw:
        aw = parse_int(raw["addr_width"], "spec.addr_width")
        if aw < min_aw:
            raise SpecError(f"spec.addr_width={aw} too small (need >= {min_aw})")
    else:
        aw = min_aw
    blk.addr_width = aw

    # Generated port names must be unique
    ports = {}
    for reg in blk.registers:
        for pname in hw_port_names(reg):
            if pname in ports:
                raise SpecError(f"port name collision: {pname} ({reg.name} vs {ports[pname]})")
            ports[pname] = reg.name
    return blk


# =============================================================================
# Helpers
# =============================================================================
def sig(reg: Register, fld: Optional[Field] = None) -> str:
    return (f"{reg.name}_{fld.name}" if fld else reg.name).lower()


def rng(msb: int, lsb: int) -> str:
    return f"[{msb}]" if msb == lsb else f"[{msb}:{lsb}]"


def decl(width: int) -> str:
    return "" if width == 1 else f"[{width - 1}:0]"


def lit(width: int, value: int) -> str:
    return f"{width}'h{value:0{(width + 3) // 4}X}"


def hw_ports(reg: Register):
    """Yield (direction, width, name, comment) for the hardware interface."""
    for f in reg.fields:
        s, w = sig(reg, f), f.width
        if f.access == "RO":
            if not f.const:
                yield ("input", w, f"{s}_i", f"{reg.name}.{f.name} RO value")
            continue
        yield ("output", w, f"{s}_o", f"{reg.name}.{f.name} {f.access}"
               + (" pulse" if f.access == "W1P" else ""))
        if f.access == "RW" and f.hw_write:
            yield ("input", 1, f"{s}_we_i", f"{reg.name}.{f.name} hardware write enable")
            yield ("input", w, f"{s}_d_i", f"{reg.name}.{f.name} hardware write data")
        elif f.access in ("W1C", "RC"):
            yield ("input", w, f"{s}_set_i", f"{reg.name}.{f.name} hardware set")
        elif f.access == "W1S":
            yield ("input", w, f"{s}_clr_i", f"{reg.name}.{f.name} hardware clear")
    if reg.strobe:
        yield ("output", 1, f"{sig(reg)}_wr_o", f"{reg.name} software write pulse")
        yield ("output", 1, f"{sig(reg)}_rd_o", f"{reg.name} software read pulse")


def hw_port_names(reg: Register):
    return [p[2] for p in hw_ports(reg)]


def header(blk: Block, comment: str = "//") -> str:
    return (f"{comment} {'=' * 76}\n"
            f"{comment} Generated by csrgen.py v{TOOL_VERSION} from {blk.source}\n"
            f"{comment} DO NOT EDIT - regenerate from the register specification.\n"
            f"{comment} {'=' * 76}\n")


def port_lines(ports, indent="  "):
    """Format port declarations with aligned columns, comma-separated."""
    rows = []
    for direction, width, name, comment in ports:
        rows.append((f"{direction:<6} logic {decl(width):<7}", name, comment))
    out = []
    for i, (pre, name, comment) in enumerate(rows):
        comma = "," if i < len(rows) - 1 else ""
        out.append(f"{indent}{pre} {name}{comma}" + (f"  // {comment}" if comment else ""))
    return out


# =============================================================================
# Generators
# =============================================================================
def gen_pkg(blk: Block) -> str:
    N, dw, aw = blk.name.upper(), blk.data_width, blk.addr_width
    L = [header(blk), f"package {blk.name}_csr_pkg;", ""]
    L.append(f"  localparam int unsigned {N}_DATA_WIDTH = {dw};")
    L.append(f"  localparam int unsigned {N}_ADDR_WIDTH = {aw};")
    L.append(f"  localparam int unsigned {N}_NUM_REGS   = {len(blk.registers)};")
    L.append("")
    for r in blk.registers:
        R = f"{N}_{r.name}"
        L.append(f"  // {r.name}" + (f" : {r.desc}" if r.desc else ""))
        L.append(f"  localparam logic [{aw - 1}:0] {R}_OFFSET = {lit(aw, r.offset)};")
        L.append(f"  localparam logic [{dw - 1}:0] {R}_RESET  = {lit(dw, r.read_reset)};")
        for f in r.fields:
            F = f"{R}_{f.name}"
            L.append(f"  localparam int unsigned   {F}_LSB   = {f.lsb};")
            L.append(f"  localparam int unsigned   {F}_WIDTH = {f.width};")
            L.append(f"  localparam logic [{dw - 1}:0] {F}_MASK  = {lit(dw, f.mask)};")
        L.append("")
    L.append(f"endpackage : {blk.name}_csr_pkg")
    return "\n".join(L) + "\n"


def gen_regs(blk: Block) -> str:
    dw, aw, sw, lsb = blk.data_width, blk.addr_width, blk.strb_width, blk.addr_lsb
    waw = aw - lsb
    mod = f"{blk.name}_csr_regs"
    if blk.reset_type == "async":
        ff = "always_ff @(posedge clk or negedge rst_n) begin"
    else:
        ff = "always_ff @(posedge clk) begin"

    bus_ports = [
        ("input", 1, "clk", "clock"),
        ("input", 1, "rst_n", f"{blk.reset_type}hronous reset, active low"),
        ("input", 1, "csr_req", "CSR bus (from apb2csr)"),
        ("input", 1, "csr_we", ""),
        ("input", aw, "csr_addr", "byte address"),
        ("input", dw, "csr_wdata", ""),
        ("input", sw, "csr_wstrb", ""),
        ("output", 1, "csr_ack", ""),
        ("output", dw, "csr_rdata", ""),
        ("output", 1, "csr_err", ""),
    ]
    hw = [p for r in blk.registers for p in hw_ports(r)]

    L = [header(blk)]
    if blk.desc:
        L.append(f"// {blk.desc}")
    L.append("// Register file on the generic CSR bus. Zero-latency: csr_ack = csr_req.")
    L.append("")
    L.append(f"module {mod} (")
    L.extend(port_lines(bus_ports + hw))
    L.append(");")
    L.append("")

    # ---- decode
    L.append("  // ---------------------------------------------------------------------------")
    L.append("  // Address decode")
    L.append("  // ---------------------------------------------------------------------------")
    # Only declare what is used, so the output is clean under verilator -Wall
    use_wr = any(r.needs_wr for r in blk.registers)
    use_rd = any(r.needs_rd for r in blk.registers)
    use_wmask = any(f.sw_writable for r in blk.registers for f in r.fields)
    L.append(f"  logic {decl(waw)} word_addr;")
    L.append("  logic        hit;")
    L.append(f"  logic {decl(dw)} rdata;")
    L.append("")
    L.append(f"  assign word_addr = csr_addr[{aw - 1}:{lsb}];")
    if use_wmask:
        L.append(f"  logic {decl(dw)} wmask;")
        if sw == 1:
            L.append("  assign wmask = {8{csr_wstrb}};")
        else:
            lanes = ", ".join(f"{{8{{csr_wstrb[{b}]}}}}" for b in reversed(range(sw)))
            L.append(f"  assign wmask = {{{lanes}}};")
    if use_wr:
        L.append("  logic sw_wr;")
        L.append("  assign sw_wr = csr_req &  csr_we;")
    if use_rd:
        L.append("  logic sw_rd;")
        L.append("  assign sw_rd = csr_req & ~csr_we;")
    unused = []
    if not use_wmask:
        unused += ["csr_wdata", "csr_wstrb"]
    if not (use_wr or use_rd):
        unused += ["csr_we"]
    if unused:
        L.append("  // Bus inputs not needed by this register map")
        L.append("  logic unused_bus;")
        L.append(f"  assign unused_bus = ^{{{', '.join(unused)}}};")
    L.append("")
    for r in blk.registers:
        s = sig(r)
        idx = lit(waw, r.offset >> lsb)
        L.append(f"  logic {s}_hit;  // 0x{r.offset:0{(aw + 3) // 4}X}")
        L.append(f"  assign {s}_hit = (word_addr == {idx});")
        if r.needs_wr:
            L.append(f"  logic {s}_wr;")
            L.append(f"  assign {s}_wr = sw_wr & {s}_hit;")
        if r.needs_rd:
            L.append(f"  logic {s}_rd;")
            L.append(f"  assign {s}_rd = sw_rd & {s}_hit;")
    L.append("")

    # ---- storage
    L.append("  // ---------------------------------------------------------------------------")
    L.append("  // Registers")
    L.append("  // ---------------------------------------------------------------------------")
    for r in blk.registers:
        L.append(f"  // {r.name} @ 0x{r.offset:X}" + (f" : {r.desc}" if r.desc else ""))
        for f in r.fields:
            s, w, br = sig(r, f), f.width, rng(f.msb, f.lsb)
            q = f"{s}_q"
            wr = f"{sig(r)}_wr"
            rd = f"{sig(r)}_rd"
            wd = f"csr_wdata{br}"
            wm = f"wmask{br}"
            rv = lit(w, f.reset)
            rep = (lambda x: x) if w == 1 else (lambda x: f"{{{w}{{{x}}}}}")
            if not f.has_storage:
                continue
            L.append(f"  logic {decl(w)} {q};  // {r.name}.{f.name} {br} {f.access}")
            L.append(f"  {ff}")
            L.append(f"    if (!rst_n) {q} <= {rv};")
            if f.access in ("RW", "WO"):
                L.append(f"    else if ({wr}) {q} <= ({q} & ~{wm}) | ({wd} & {wm});")
                if f.hw_write:
                    L.append(f"    else if ({s}_we_i) {q} <= {s}_d_i;")
            elif f.access == "W1C":
                L.append(f"    else {q} <= ({q} & ~({wd} & {wm} & {rep(wr)})) | {s}_set_i;")
            elif f.access == "W1S":
                L.append(f"    else {q} <= ({q} & ~{s}_clr_i) | ({wd} & {wm} & {rep(wr)});")
            elif f.access == "RC":
                L.append(f"    else {q} <= ({q} & ~{rep(rd)}) | {s}_set_i;")
            elif f.access == "W1P":
                L.append(f"    else {q} <= {wd} & {wm} & {rep(wr)};")
            L.append("  end")
            L.append(f"  assign {s}_o = {q};")
            L.append("")
        if r.strobe:
            L.append(f"  assign {sig(r)}_wr_o = {sig(r)}_wr;")
            L.append(f"  assign {sig(r)}_rd_o = {sig(r)}_rd;")
            L.append("")

    # ---- read mux
    L.append("  // ---------------------------------------------------------------------------")
    L.append("  // Read data mux")
    L.append("  // ---------------------------------------------------------------------------")
    L.append("  always_comb begin")
    L.append("    rdata = '0;")
    L.append("    hit   = 1'b0;")
    L.append("    unique case (1'b1)")
    for r in blk.registers:
        L.append(f"      {sig(r)}_hit: begin")
        L.append("        hit = 1'b1;")
        for f in r.fields:
            if not f.sw_readable:
                continue
            br = rng(f.msb, f.lsb)
            if f.access == "RO":
                src = lit(f.width, f.reset) if f.const else f"{sig(r, f)}_i"
            else:
                src = f"{sig(r, f)}_q"
            L.append(f"        rdata{br} = {src};")
        L.append("      end")
    L.append("      default: ;")
    L.append("    endcase")
    L.append("  end")
    L.append("")
    L.append("  assign csr_ack   = csr_req;")
    L.append("  assign csr_rdata = rdata;")
    if blk.error_on_unmapped:
        L.append("  assign csr_err   = csr_req & ~hit;  // unmapped address")
    else:
        L.append("  assign csr_err   = 1'b0;")
        L.append("  logic unused_hit;")
        L.append("  assign unused_hit = hit;")
    if lsb > 0:
        L.append("")
        L.append("  // Byte offset bits are ignored (alignment is checked by apb2csr)")
        L.append(f"  logic {decl(lsb)} unused_addr_lsb;")
        L.append(f"  assign unused_addr_lsb = csr_addr[{lsb - 1}:0];")
    L.append("")
    L.append(f"endmodule : {mod}")
    return "\n".join(L) + "\n"


def gen_top(blk: Block) -> str:
    dw, aw, sw = blk.data_width, blk.addr_width, blk.strb_width
    mod = f"{blk.name}_apb_csr"
    hw = [p for r in blk.registers for p in hw_ports(r)]

    L = [header(blk)]
    if blk.desc:
        L.append(f"// {blk.desc}")
    L.append("// AMBA APB4 slave top: apb2csr bridge + generated register file.")
    L.append("")
    L.append(f"module {mod} #(")
    L.append("  parameter int unsigned APB_ADDR_WIDTH = 32,")
    L.append("  parameter bit          USE_PSTRB      = 1'b1,")
    L.append("  parameter bit          ERR_UNALIGNED  = 1'b1,")
    L.append("  parameter bit          PRIV_ONLY      = 1'b0,")
    L.append("  parameter bit          SECURE_ONLY    = 1'b0")
    L.append(") (")
    apb = [
        ("input", 1, "pclk", ""),
        ("input", 1, "presetn", ""),
        ("input", 1, "psel", "APB slave"),
        ("input", 1, "penable", ""),
        ("input", "APB_ADDR_WIDTH", "paddr", ""),
        ("input", 1, "pwrite", ""),
        ("input", dw, "pwdata", ""),
        ("input", sw, "pstrb", ""),
        ("input", 3, "pprot", ""),
        ("output", 1, "pready", ""),
        ("output", dw, "prdata", ""),
        ("output", 1, "pslverr", ""),
    ]
    rows = []
    for d, w, n, c in apb + hw:
        wdecl = "[APB_ADDR_WIDTH-1:0]" if w == "APB_ADDR_WIDTH" else decl(w)
        rows.append((d, wdecl, n, c))
    for i, (d, wdecl, n, c) in enumerate(rows):
        comma = "," if i < len(rows) - 1 else ""
        L.append(f"  {d:<6} logic {wdecl:<20} {n}{comma}" + (f"  // {c}" if c else ""))
    L.append(");")
    L.append("")
    L.append(f"  logic        csr_req, csr_we, csr_ack, csr_err;")
    L.append(f"  logic {decl(aw)} csr_addr;")
    L.append(f"  logic {decl(dw)} csr_wdata, csr_rdata;")
    L.append(f"  logic {decl(sw)} csr_wstrb;")
    L.append("  logic [2:0]  csr_prot;")
    L.append("")
    L.append("  apb2csr #(")
    L.append("    .APB_ADDR_WIDTH (APB_ADDR_WIDTH),")
    L.append(f"    .DATA_WIDTH     ({dw}),")
    L.append(f"    .CSR_ADDR_WIDTH ({aw}),")
    L.append("    .USE_PSTRB      (USE_PSTRB),")
    L.append("    .ERR_UNALIGNED  (ERR_UNALIGNED),")
    L.append("    .PRIV_ONLY      (PRIV_ONLY),")
    L.append("    .SECURE_ONLY    (SECURE_ONLY),")
    L.append("    .TIMEOUT_CYCLES (0),  // register file always acks immediately")
    L.append(f"    .ASYNC_RESET    (1'b{1 if blk.reset_type == 'async' else 0})  "
             f"// matches reset_type \"{blk.reset_type}\" of the register file")
    L.append("  ) u_apb2csr (")
    conns = ["pclk", "presetn", "psel", "penable", "paddr", "pwrite", "pwdata", "pstrb",
             "pprot", "pready", "prdata", "pslverr", "csr_req", "csr_we", "csr_addr",
             "csr_wdata", "csr_wstrb", "csr_prot", "csr_ack", "csr_rdata", "csr_err"]
    for i, c in enumerate(conns):
        L.append(f"    .{c:<10} ({c})" + ("," if i < len(conns) - 1 else ""))
    L.append("  );")
    L.append("")
    L.append("  // CSR protection attributes are not used by the generated register file")
    L.append("  logic [2:0] unused_csr_prot;")
    L.append("  assign unused_csr_prot = csr_prot;")
    L.append("")
    L.append(f"  {blk.name}_csr_regs u_regs (")
    conns = [("clk", "pclk"), ("rst_n", "presetn")] + [(c, c) for c in (
        "csr_req", "csr_we", "csr_addr", "csr_wdata", "csr_wstrb",
        "csr_ack", "csr_rdata", "csr_err")] + [(p[2], p[2]) for p in hw]
    width = max(len(c[0]) for c in conns)
    for i, (p, s) in enumerate(conns):
        L.append(f"    .{p:<{width}} ({s})" + ("," if i < len(conns) - 1 else ""))
    L.append("  );")
    L.append("")
    L.append(f"endmodule : {mod}")
    return "\n".join(L) + "\n"


def gen_c_header(blk: Block) -> str:
    N = blk.name.upper()
    guard = f"{N}_CSR_H"
    ctype = {8: "uint8_t", 16: "uint16_t", 32: "uint32_t"}[blk.data_width]
    L = [header(blk, "//"), f"#ifndef {guard}", f"#define {guard}", "", "#include <stdint.h>", ""]
    if blk.desc:
        L.append(f"/* {blk.desc} */")
    L.append(f"#define {N}_DATA_WIDTH  {blk.data_width}u")
    L.append(f"#define {N}_ADDR_WIDTH  {blk.addr_width}u")
    L.append("")
    L.append(f"#define {N}_REG(base, off)  (*(volatile {ctype} *)((uintptr_t)(base) + (off)))")
    L.append("")
    for r in blk.registers:
        R = f"{N}_{r.name}"
        L.append(f"/* {r.name}" + (f" - {r.desc}" if r.desc else "") + " */")
        L.append(f"#define {R}_OFFSET  0x{r.offset:04X}u")
        L.append(f"#define {R}_RESET   0x{r.read_reset:0{blk.data_width // 4}X}u")
        for f in r.fields:
            F = f"{R}_{f.name}"
            L.append(f"#define {F}_SHIFT  {f.lsb}u")
            L.append(f"#define {F}_WIDTH  {f.width}u")
            L.append(f"#define {F}_MASK   0x{f.mask:0{blk.data_width // 4}X}u  /* {f.access} */")
            L.append(f"#define {F}_GET(v) (((v) & {F}_MASK) >> {F}_SHIFT)")
            L.append(f"#define {F}_SET(v) (((uint32_t)(v) << {F}_SHIFT) & {F}_MASK)")
        L.append("")
    L.append(f"#endif /* {guard} */")
    return "\n".join(L) + "\n"


ACCESS_DESC = {
    "RW":  "Read/write",
    "RO":  "Read-only (hardware value)",
    "WO":  "Write-only, reads return 0",
    "W1C": "Write 1 to clear, set by hardware",
    "W1S": "Write 1 to set, cleared by hardware",
    "RC":  "Cleared on read, set by hardware",
    "W1P": "Write 1 generates a single-cycle pulse, reads return 0",
}


def gen_markdown(blk: Block) -> str:
    dw = blk.data_width
    hexw = dw // 4
    L = [f"# {blk.name.upper()} register map", ""]
    L.append(f"_Generated by csrgen.py v{TOOL_VERSION} from `{blk.source}`. Do not edit._")
    L.append("")
    if blk.desc:
        L += [blk.desc, ""]
    L.append(f"- Data width: **{dw} bit**, address width: **{blk.addr_width} bit**")
    L.append(f"- Unmapped access: **{'PSLVERR' if blk.error_on_unmapped else 'RAZ/WI'}**")
    L.append(f"- Reset: **{blk.reset_type}**, active low")
    L.append("")
    L.append("## Summary")
    L.append("")
    L.append("| Offset | Name | Reset | Description |")
    L.append("|--------|------|-------|-------------|")
    for r in blk.registers:
        L.append(f"| 0x{r.offset:03X} | [{r.name}](#{r.name.lower()}) | "
                 f"0x{r.read_reset:0{hexw}X} | {r.desc} |")
    L.append("")
    L.append("## Registers")
    for r in blk.registers:
        L.append("")
        L.append(f"### {r.name}")
        L.append("")
        L.append(f"Offset `0x{r.offset:03X}`, reset `0x{r.read_reset:0{hexw}X}`"
                 + (" - access strobes `_wr_o` / `_rd_o` available" if r.strobe else ""))
        if r.desc:
            L += ["", r.desc]
        L.append("")
        L.append("| Bits | Field | Access | Reset | Description |")
        L.append("|------|-------|--------|-------|-------------|")
        expected = 0
        rows = []
        for f in r.fields:
            if f.lsb > expected:
                rows.append((f.lsb - 1, expected, "-", "-", "-", "Reserved, reads 0"))
            rows.append((f.msb, f.lsb, f.name, f.access + (" (const)" if f.const else ""),
                         f"0x{f.reset:X}" if (f.access != "RO" or f.const) else "hw", f.desc))
            expected = f.msb + 1
        if expected < dw:
            rows.append((dw - 1, expected, "-", "-", "-", "Reserved, reads 0"))
        for msb, lsb, n, a, rv, d in reversed(rows):
            b = f"{msb}" if msb == lsb else f"{msb}:{lsb}"
            L.append(f"| {b} | {n} | {a} | {rv} | {d} |")
    L.append("")
    L.append("## Access types")
    L.append("")
    L.append("| Type | Behaviour |")
    L.append("|------|-----------|")
    for a, d in ACCESS_DESC.items():
        L.append(f"| {a} | {d} |")
    return "\n".join(L) + "\n"


# =============================================================================
# Main
# =============================================================================
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Generate CSR register block for apb2csr")
    ap.add_argument("spec", type=Path, help="register specification (.json / .yaml)")
    ap.add_argument("-o", "--out", type=Path, help="output directory (default: generated/<name>)")
    ap.add_argument("--check", action="store_true", help="validate the spec only")
    args = ap.parse_args(argv)

    try:
        blk = build_block(load_spec(args.spec), args.spec.name)
    except (SpecError, OSError) as e:
        print(f"csrgen: ERROR: {e}", file=sys.stderr)
        return 1

    nflds = sum(len(r.fields) for r in blk.registers)
    print(f"csrgen: {blk.name}: {len(blk.registers)} registers, {nflds} fields, "
          f"DW={blk.data_width}, AW={blk.addr_width}")
    if args.check:
        print("csrgen: spec OK")
        return 0

    out = args.out or Path("generated") / blk.name
    out.mkdir(parents=True, exist_ok=True)
    outputs = {
        f"{blk.name}_csr_pkg.sv": gen_pkg(blk),
        f"{blk.name}_csr_regs.sv": gen_regs(blk),
        f"{blk.name}_apb_csr.sv": gen_top(blk),
        f"{blk.name}_csr.h": gen_c_header(blk),
        f"{blk.name}_csr.md": gen_markdown(blk),
    }
    for fname, text in outputs.items():
        (out / fname).write_text(text, encoding="utf-8", newline="\n")
        print(f"csrgen:   wrote {out / fname}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
