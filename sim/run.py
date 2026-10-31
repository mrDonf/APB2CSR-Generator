#!/usr/bin/env python3
"""
run.py - QuestaSim + Verilator flow for the apb2csr IP (Windows / Linux).

    python sim/run.py gen                  # generate register block(s) from spec/*.json
    python sim/run.py lint                 # Questa lint + Verilator -Wall lint
    python sim/run.py lint --tool verilator  (or --tool questa)
    python sim/run.py sim [options]        # compile + run one test
    python sim/run.py regress [--cov]      # parameter matrix regression (+ code coverage)
    python sim/run.py all                  # gen + lint + regress --cov

sim options:
    --tb tb_apb2csr | tb_demo_apb_csr      testbench top (default tb_apb2csr)
    -G NAME=VALUE                          override a testbench parameter (repeatable)
    --seed N                               random seed (default: random)
    --gui                                  open the Questa GUI with waves
    --cov                                  collect code coverage

Verilator is taken from PATH; on Windows without a native build it is run
inside WSL (default distro, or set APB2CSR_WSL_DISTRO).

Outputs go to sim/out/ (libraries, logs, UCDB, coverage reports).
"""

import argparse
import os
import random
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "sim" / "out"
SPEC_DIR = ROOT / "spec"
GEN_DIR = ROOT / "generated"

RTL = [ROOT / "rtl" / "apb2csr.sv"]
TB_COMMON = [ROOT / "tb" / "apb4_master_if.sv"]
TESTBENCHES = {
    "tb_apb2csr": [ROOT / "tb" / "tb_apb2csr.sv"],
    "tb_demo_apb_csr": [ROOT / "tb" / "tb_demo_apb_csr.sv"],
}

# Regression matrix: (testbench, name, {parameter: value})
REGRESSION = [
    ("tb_apb2csr", "default_dw32",     {}),
    ("tb_apb2csr", "zero_wait",        {"MAX_LATENCY": 0}),
    ("tb_apb2csr", "long_latency",     {"MAX_LATENCY": 12, "TIMEOUT_CYCLES": 0}),
    ("tb_apb2csr", "timeout_1",        {"MAX_LATENCY": 1, "TIMEOUT_CYCLES": 1}),
    ("tb_apb2csr", "dw16",             {"DATA_WIDTH": 16}),
    ("tb_apb2csr", "dw8",              {"DATA_WIDTH": 8, "CSR_ADDR_WIDTH": 8}),
    ("tb_apb2csr", "pstrb_off_apb3",   {"USE_PSTRB": 0}),
    ("tb_apb2csr", "no_unaligned_err", {"ERR_UNALIGNED": 0}),
    ("tb_apb2csr", "priv_secure",      {"PRIV_ONLY": 1, "SECURE_ONLY": 1}),
    ("tb_apb2csr", "small_addr",       {"CSR_ADDR_WIDTH": 6}),
    ("tb_apb2csr", "sync_reset",       {"ASYNC_RESET": 0, "MAX_LATENCY": 3}),
    ("tb_demo_apb_csr", "demo_ip",     {}),
]

# Elaboration matrix for lint: apb2csr parameter sets
LINT_ELAB = [
    {},
    {"DATA_WIDTH": 8, "CSR_ADDR_WIDTH": 4},
    {"DATA_WIDTH": 16, "TIMEOUT_CYCLES": 1},
    {"DATA_WIDTH": 32, "TIMEOUT_CYCLES": 255, "USE_PSTRB": 0, "ERR_UNALIGNED": 0},
    {"APB_ADDR_WIDTH": 16, "CSR_ADDR_WIDTH": 16, "PRIV_ONLY": 1, "SECURE_ONLY": 1},
    {"ASYNC_RESET": 0, "TIMEOUT_CYCLES": 8},
]

VLT_WAIVERS = ROOT / "lint" / "verilator_waivers.vlt"
BIT_PARAMS = {"USE_PSTRB", "ERR_UNALIGNED", "PRIV_ONLY", "SECURE_ONLY", "ASYNC_RESET"}


def vl_gopts(params: dict):
    """Verilator -G options; 1-bit parameters get sized literals (avoids WIDTHTRUNC)."""
    return [f"-G{k}=1'b{v}" if k in BIT_PARAMS else f"-G{k}={v}" for k, v in params.items()]

MSG_RE = re.compile(r"\*\* (Error|Fatal|Warning)")


# =============================================================================
# Helpers
# =============================================================================
def tool(name: str) -> str:
    path = shutil.which(name)
    if not path:
        sys.exit(f"run.py: '{name}' not found in PATH (QuestaSim bin directory required)")
    return path


def run(cmd, log: Path = None, cwd: Path = OUT, quiet: bool = False) -> str:
    """Run a command, tee output to a log file, return the output text."""
    cmd = [str(c) for c in cmd]
    proc = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, errors="replace")
    text = proc.stdout
    if log:
        log.write_text(text, encoding="utf-8")
    if not quiet:
        for line in text.splitlines():
            if MSG_RE.search(line):
                print("    " + line.strip())
    return text


def count_msgs(text: str):
    errs = len(re.findall(r"\*\* (?:Error|Fatal)", text))
    warns = len(re.findall(r"\*\* Warning", text))
    return errs, warns


def generated_rtl():
    files = []
    for d in sorted(GEN_DIR.glob("*")):
        if d.is_dir():
            files += sorted(d.glob("*_csr_pkg.sv"))
            files += sorted(d.glob("*_csr_regs.sv"))
            files += sorted(d.glob("*_apb_csr.sv"))
    return files


def ensure_lib(lib: Path):
    if not lib.exists():
        run([tool("vlib"), lib.name], cwd=lib.parent, quiet=True)


# =============================================================================
# Steps
# =============================================================================
def do_gen(args) -> bool:
    specs = [Path(args.spec)] if getattr(args, "spec", None) else sorted(SPEC_DIR.glob("*.json"))
    ok = True
    for spec in specs:
        name = spec.stem
        rc = subprocess.run([sys.executable, str(ROOT / "tools" / "csrgen.py"), str(spec),
                             "-o", str(GEN_DIR / name)]).returncode
        ok &= (rc == 0)
    return ok


def param_desc(params: dict) -> str:
    return ", ".join(f"{k}={v}" for k, v in params.items()) or "defaults"


def generated_tops():
    """Yield (top_module, [files]) for every generated register block."""
    for d in sorted(GEN_DIR.glob("*")):
        tops = sorted(d.glob("*_apb_csr.sv")) if d.is_dir() else []
        for top in tops:
            name = top.stem[:-len("_apb_csr")]
            yield top.stem, [d / f"{name}_csr_pkg.sv", d / f"{name}_csr_regs.sv", top]


def lint_questa():
    """vlog -lint -pedanticerrors + vopt elaboration matrix. Returns (errors, warnings)."""
    lib = OUT / "work_lint"
    if lib.exists():
        shutil.rmtree(lib)
    ensure_lib(lib)
    files = RTL + generated_rtl()
    print(f"[lint:questa] vlog -lint -pedanticerrors ({len(files)} RTL files, +define+SYNTHESIS)")
    text = run([tool("vlog"), "-sv", "-lint", "-pedanticerrors", "+define+SYNTHESIS",
                "-work", lib.name] + files, log=OUT / "lint_vlog.log")
    total_e, total_w = count_msgs(text)
    print(f"[lint:questa]   vlog: {total_e} error(s), {total_w} warning(s)")

    # Elaborate with several parameter sets: catches width mismatches / bad ranges
    for i, params in enumerate(LINT_ELAB):
        gopts = [f"-G{k}={v}" for k, v in params.items()]
        text = run([tool("vopt"), "-work", lib.name, "apb2csr", "-o", f"apb2csr_opt{i}"] + gopts,
                   log=OUT / f"lint_vopt{i}.log")
        e, w = count_msgs(text)
        print(f"[lint:questa]   vopt apb2csr ({param_desc(params)}): {e} error(s), {w} warning(s)")
        total_e, total_w = total_e + e, total_w + w
    for top, _ in generated_tops():
        text = run([tool("vopt"), "-work", lib.name, top, "-o", f"{top}_opt"],
                   log=OUT / f"lint_vopt_{top}.log")
        e, w = count_msgs(text)
        print(f"[lint:questa]   vopt {top}: {e} error(s), {w} warning(s)")
        total_e, total_w = total_e + e, total_w + w
    return total_e, total_w


def to_wsl_path(p) -> str:
    p = Path(p).resolve()
    drive = p.drive.rstrip(":").lower()
    return f"/mnt/{drive}{p.as_posix()[len(p.drive):]}"


def find_verilator():
    """Return (command prefix, path mapper, version) or None if Verilator is unavailable."""
    if os.name != "nt":
        exe = shutil.which("verilator")
        candidates = [([exe], str)] if exe else []
    else:
        exe = shutil.which("verilator_bin")
        candidates = [([exe], str)] if exe else []
        wsl = shutil.which("wsl")
        if wsl:
            distro = os.environ.get("APB2CSR_WSL_DISTRO")
            prefix = [wsl] + (["-d", distro] if distro else []) + ["--exec", "verilator"]
            candidates.append((prefix, to_wsl_path))
    for prefix, mapper in candidates:
        try:
            r = subprocess.run(prefix + ["--version"], stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, errors="replace", timeout=180)
        except (OSError, subprocess.TimeoutExpired):
            continue
        if r.returncode == 0 and "Verilator" in r.stdout:
            return prefix, mapper, r.stdout.strip().splitlines()[0]
    return None


def lint_verilator():
    """verilator --lint-only -Wall, synthesis view + assertion view. Returns (errors, warnings)."""
    found = find_verilator()
    if not found:
        return None
    prefix, mp, version = found
    via = " (via WSL)" if "wsl" in Path(prefix[0]).name.lower() else ""
    print(f"[lint:verilator] {version}{via}")

    jobs = []   # (label, log name, args, files)
    for i, params in enumerate(LINT_ELAB):
        jobs.append((f"apb2csr synth ({param_desc(params)})", f"vl_apb2csr_synth{i}",
                     ["-DSYNTHESIS", "--top-module", "apb2csr"] + vl_gopts(params), RTL))
    for i, params in enumerate([{}, {"ASYNC_RESET": 0}]):
        jobs.append((f"apb2csr +SVA  ({param_desc(params)})", f"vl_apb2csr_sva{i}",
                     ["--assert", mp(VLT_WAIVERS), "--top-module", "apb2csr"] + vl_gopts(params),
                     RTL))
    for top, files in generated_tops():
        jobs.append((f"{top} synth", f"vl_{top}", ["-DSYNTHESIS", "--top-module", top],
                     RTL + files))

    total_e = total_w = 0
    for label, logname, opts, files in jobs:
        cmd = prefix + ["--lint-only", "-Wall"] + opts + [mp(f) for f in files]
        text = run(cmd, log=OUT / f"lint_{logname}.log", quiet=True)
        msgs = [l for l in text.splitlines()
                if l.startswith(("%Warning", "%Error")) and "Exiting due to" not in l]
        e = sum(l.startswith("%Error") for l in msgs)
        w = sum(l.startswith("%Warning") for l in msgs)
        print(f"[lint:verilator]   {label}: {e} error(s), {w} warning(s)")
        for l in msgs:
            print("      " + l.replace(mp(ROOT) + "/", ""))
        total_e, total_w = total_e + e, total_w + w
    return total_e, total_w


def do_lint(args) -> bool:
    OUT.mkdir(parents=True, exist_ok=True)
    which = getattr(args, "tool", "all")
    total_e = total_w = 0
    if which in ("all", "questa"):
        e, w = lint_questa()
        total_e, total_w = total_e + e, total_w + w
    if which in ("all", "verilator"):
        res = lint_verilator()
        if res is None:
            print("[lint:verilator] Verilator not found (PATH or WSL) - skipped")
            if which == "verilator":
                return False
        else:
            total_e, total_w = total_e + res[0], total_w + res[1]

    ok = total_e == 0 and (total_w == 0 or not args.strict)
    print(f"[lint] {'PASS' if ok else 'FAIL'}: {total_e} error(s), {total_w} warning(s)"
          f"  (logs: {OUT})")
    return ok


def compile_all(cov: bool) -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    lib = OUT / ("work_cov" if cov else "work")
    ensure_lib(lib)
    rtl = RTL + generated_rtl()
    tb = TB_COMMON + [f for fl in TESTBENCHES.values() for f in fl]
    cov_opt = ["+cover=bcesf"] if cov else []
    t1 = run([tool("vlog"), "-sv", "-work", lib.name] + cov_opt + rtl, log=OUT / "compile_rtl.log")
    t2 = run([tool("vlog"), "-sv", "-work", lib.name] + tb, log=OUT / "compile_tb.log")
    e1, _ = count_msgs(t1)
    e2, _ = count_msgs(t2)
    if e1 or e2:
        sys.exit(f"run.py: compilation failed, see {OUT / 'compile_rtl.log'} / compile_tb.log")
    return lib


def run_test(lib: Path, tb: str, name: str, params: dict, seed: int, cov: bool, gui: bool):
    log = OUT / f"{name}.log"
    gopts = [f"-G{k}={v}" for k, v in params.items()]
    cmd = [tool("vsim"), "-lib", lib.name, tb, "-sv_seed", str(seed), "-l", log.name] + gopts
    if gui:
        cmd += ["-gui", "-voptargs=+acc", "-do", "add wave -r /*; run -all"]
        subprocess.run([str(c) for c in cmd], cwd=OUT)
        return True, 0.0
    do = "run -all; quit -f"
    if cov:
        cmd += ["-coverage"]
        do = f"coverage save -onexit {name}.ucdb; run -all; quit -f"
    cmd = cmd[:1] + ["-c"] + cmd[1:] + ["-do", do]
    t0 = time.time()
    run(cmd, quiet=True)
    dt = time.time() - t0
    text = log.read_text(encoding="utf-8", errors="replace") if log.exists() else ""
    errs, _ = count_msgs(text)
    passed = "TEST PASSED" in text and errs == 0
    return passed, dt


def do_sim(args) -> bool:
    lib = compile_all(args.cov)
    params = dict(g.split("=", 1) for g in (args.G or []))
    seed = args.seed if args.seed is not None else random.randint(1, 2**31 - 1)
    name = args.tb + ("" if not params else "_" + "_".join(f"{k}{v}" for k, v in params.items()))
    passed, dt = run_test(lib, args.tb, name, params, seed, args.cov, args.gui)
    if args.gui:
        return True
    print(f"[sim] {name} seed={seed}: {'PASS' if passed else 'FAIL'} ({dt:.1f}s)  log: {OUT / (name + '.log')}")
    if args.cov:
        coverage_report([OUT / f"{name}.ucdb"])
    return passed


def coverage_report(ucdbs):
    ucdbs = [u for u in ucdbs if u.exists()]
    if not ucdbs:
        print("[cov] no UCDB files produced")
        return
    merged = OUT / "merged.ucdb"
    run([tool("vcover"), "merge", merged.name] + [u.name for u in ucdbs], quiet=True)
    rpt = OUT / "coverage_summary.txt"
    text = run([tool("vcover"), "report", "-code", "bcesf", "-bydu", merged.name],
               log=rpt, quiet=True)
    run([tool("vcover"), "report", "-code", "bcesf", "-details", "-output",
         "coverage_details.txt", merged.name], quiet=True)
    run([tool("vcover"), "report", "-html", "-htmldir", "coverage_html", "-code", "bcesf",
         "-details", merged.name], quiet=True)
    print(f"[cov] merged {len(ucdbs)} UCDB -> {merged}")
    for line in text.splitlines():
        if re.search(r"(Design Unit:|Stmts|Branches|FEC|FSMs|States|Transitions|Total Coverage)", line):
            print("    " + line.strip())
    print(f"[cov] reports: {rpt}, {OUT / 'coverage_details.txt'}, {OUT / 'coverage_html' / 'index.html'}")


def do_regress(args) -> bool:
    lib = compile_all(args.cov)
    results = []
    print(f"[regress] {len(REGRESSION)} configurations x {args.seeds} seed(s)")
    for tb, name, params in REGRESSION:
        for s in range(args.seeds):
            seed = random.randint(1, 2**31 - 1) if args.seed is None else args.seed + s
            tname = name if args.seeds == 1 else f"{name}_s{s}"
            passed, dt = run_test(lib, tb, tname, params, seed, args.cov, False)
            results.append((tname, tb, seed, passed, dt))
            print(f"  {'PASS' if passed else 'FAIL'}  {tname:<22} {tb:<16} seed={seed:<11} {dt:5.1f}s")
    npass = sum(r[3] for r in results)
    print(f"[regress] {npass}/{len(results)} passed")
    if args.cov:
        coverage_report([OUT / f"{r[0]}.ucdb" for r in results])
    return npass == len(results)


def main() -> int:
    ap = argparse.ArgumentParser(description="QuestaSim flow for apb2csr")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("gen", help="generate register blocks from spec/*.json")
    p.add_argument("--spec", help="single spec file (default: all spec/*.json)")

    p = sub.add_parser("lint", help="Questa (vlog/vopt) + Verilator lint")
    p.add_argument("--tool", choices=["all", "questa", "verilator"], default="all")
    p.add_argument("--strict", action="store_true", help="fail on warnings too")

    p = sub.add_parser("sim", help="compile and run one test")
    p.add_argument("--tb", default="tb_apb2csr", choices=sorted(TESTBENCHES))
    p.add_argument("-G", action="append", metavar="NAME=VALUE", help="parameter override")
    p.add_argument("--seed", type=int)
    p.add_argument("--gui", action="store_true")
    p.add_argument("--cov", action="store_true")

    p = sub.add_parser("regress", help="run the regression matrix")
    p.add_argument("--seeds", type=int, default=1, help="seeds per configuration")
    p.add_argument("--seed", type=int, help="base seed (default: random)")
    p.add_argument("--cov", action="store_true")

    p = sub.add_parser("all", help="gen + lint + regress --cov")
    p.add_argument("--strict", action="store_true")

    args = ap.parse_args()
    if args.cmd == "gen":
        ok = do_gen(args)
    elif args.cmd == "lint":
        ok = do_lint(args)
    elif args.cmd == "sim":
        ok = do_sim(args)
    elif args.cmd == "regress":
        ok = do_regress(args)
    else:
        args.spec, args.seeds, args.seed, args.cov = None, 1, None, True
        ok = do_gen(args) and do_lint(args) and do_regress(args)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
