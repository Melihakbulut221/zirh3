#!/usr/bin/env python3
# =============================================================================
# tmr-guard - independent proof that your TMR survived synthesis
#
#   python3 scripts/tmr_guard.py <manifest.json|.yaml> [--json report.json]
#                                [--prove-checker]
#
# THE PROBLEM (measured on this very repository): three identical
# registers driven by identical logic are, to an optimizer, one
# register. Yosys collapses them, the resulting netlist simulates
# IDENTICALLY, and the hardening is simply gone - 79 flops became 26 in
# the recorded experiment. Insertion tools verify their own output;
# nothing independent checks the netlist you actually ship.
#
# THE TOOL: a manifest declares, per block, the replica module pattern
# and the instance and flip-flop counts that must survive a
# flatten-and-optimize synthesis pass. tmr-guard synthesizes each block
# with Yosys (no PDK, no liberty - replica merging happens in the
# early opt passes, so the check runs in seconds) and verifies both
# numbers. Two verification directions matter:
#
#   POSITIVE  - declared replicas survive with exactly the expected
#               instance and FF counts;
#   NEGATIVE  - --prove-checker strips the protection attributes from a
#               copy of the sources and asserts the check then FAILS.
#               A checker that cannot catch the collapse it exists for
#               is worse than no checker.
#
# Counting semantics handled for you (both were paid for in the field):
#   * Yosys `select -count t:NAME` counts cells per paramod DEFINITION,
#     not per instantiation - two same-width registers share one
#     definition. tmr-guard counts definitions; declare expectations
#     accordingly (the report says which widths it found).
#   * FF totals are summed from `stat -top` over every $_*DFF*_ variant
#     after memory_map + techmap, which is the honest post-optimization
#     number.
#
# Manifest (JSON, or YAML when PyYAML is installed):
#   {
#     "src_dir": "src",
#     "defines": ["ZIRH_SIM_ENV"],
#     "replica_pattern": "zirh_tmr_ff",
#     "protection_attribute": "keep_hierarchy",
#     "checks": [
#       {"name": "hk", "top": "zirh_hk",
#        "sources": ["zirh_tmr_lib.v", "zirh_hk.v"],
#        "expect_instances": 25, "expect_ffs": 706}
#     ]
#   }
#
# Exit code 0 = every check passed (and, under --prove-checker, every
# stripped copy failed as it must). Nonzero otherwise. --json emits a
# machine-readable report for CI and for attestation records.
# =============================================================================

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

YOSYS_SCRIPT = (
    "{reads} hierarchy -check -top {top}; "
    "synth -top {top} -flatten -run begin:fine; "
    "opt -full; memory_map; techmap; opt -full; "
    "select -count t:*{pattern}*; stat -top {top};"
)


def load_manifest(path):
    text = Path(path).read_text()
    if path.endswith((".yaml", ".yml")):
        try:
            import yaml
        except ImportError:
            sys.exit("YAML manifest needs PyYAML (pip install pyyaml), "
                     "or use JSON")
        return yaml.safe_load(text)
    return json.loads(text)


def run_yosys(top, sources, pattern, defines):
    dflags = " ".join(f"-D{d}" for d in defines)
    reads = " ".join(f"read_verilog -sv {dflags} {s};" for s in sources)
    script = YOSYS_SCRIPT.format(reads=reads, top=top, pattern=pattern)
    proc = subprocess.run(["yosys", "-p", script],
                         capture_output=True, text=True)
    return proc


def parse_counts(out):
    instances = None
    m = re.findall(r"^(\d+) objects\.$", out, re.M)
    if m:
        instances = int(m[-1])
    ffs = 0
    stat_tail = out.rsplit("=== ", 1)[-1]
    for cell, n in re.findall(r"\$_(\S*DFF\S*?)_\s+(\d+)", stat_tail):
        ffs += int(n)
    return instances, ffs


def one_check(chk, cfg, src_dir):
    sources = [str(src_dir / s) for s in chk["sources"]]
    pattern = chk.get("replica_pattern",
                      cfg.get("replica_pattern", "tmr"))
    proc = run_yosys(chk["top"], sources, pattern,
                     cfg.get("defines", []))
    result = {"name": chk["name"], "top": chk["top"]}
    if proc.returncode != 0:
        result.update(status="error",
                      detail=proc.stdout.splitlines()[-5:])
        return result
    instances, ffs = parse_counts(proc.stdout)
    result.update(found_instances=instances, found_ffs=ffs,
                  expect_instances=chk["expect_instances"],
                  expect_ffs=chk["expect_ffs"])
    ok_i = instances == chk["expect_instances"]
    ok_f = ffs == chk["expect_ffs"]
    result["status"] = "pass" if (ok_i and ok_f) else "fail"
    if not ok_i:
        result["verdict"] = ("replicas MERGED - the hardening is gone"
                             if instances < chk["expect_instances"]
                             else "more replicas than declared")
    elif not ok_f:
        result["verdict"] = "flip-flop count moved - re-baseline or regress"
    return result


def strip_protection(src_dir, attribute, tmp):
    """Copy sources with the protection attribute removed - the collapse
    the checker must catch."""
    for f in src_dir.rglob("*.v"):
        rel = f.relative_to(src_dir)
        dst = tmp / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(re.sub(r"\(\*\s*" + re.escape(attribute) + r"\s*\*\)",
                              "", f.read_text()))
    for f in src_dir.rglob("*.vh"):
        rel = f.relative_to(src_dir)
        dst = tmp / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(f, dst)
    return tmp


def main():
    ap = argparse.ArgumentParser(
        description="independent TMR synthesis-survival verifier")
    ap.add_argument("manifest")
    ap.add_argument("--json", help="write machine-readable report here")
    ap.add_argument("--prove-checker", action="store_true",
                    help="also strip protection attributes and require "
                         "the checks to FAIL on the stripped copy")
    args = ap.parse_args()

    cfg = load_manifest(args.manifest)
    base = Path(args.manifest).resolve().parent
    src_dir = (base / cfg.get("src_dir", ".")).resolve()

    report = {"manifest": args.manifest, "checks": [], "negative": []}
    failures = 0

    for chk in cfg["checks"]:
        r = one_check(chk, cfg, src_dir)
        report["checks"].append(r)
        mark = "ok  " if r["status"] == "pass" else "FAIL"
        print(f"  {mark}  {r['name']:<14} instances "
              f"{r.get('found_instances')}/{r.get('expect_instances')} "
              f"ffs {r.get('found_ffs')}/{r.get('expect_ffs')}"
              + (f"  <- {r['verdict']}" if "verdict" in r else ""))
        failures += r["status"] != "pass"

    if args.prove_checker:
        attribute = cfg.get("protection_attribute", "keep_hierarchy")
        with tempfile.TemporaryDirectory() as td:
            stripped = strip_protection(src_dir, attribute, Path(td))
            for chk in cfg["checks"]:
                r = one_check(chk, cfg, stripped)
                caught = r["status"] != "pass"
                report["negative"].append(
                    {"name": chk["name"], "caught_collapse": caught})
                mark = "ok  " if caught else "FAIL"
                print(f"  {mark}  {chk['name']:<14} stripped copy "
                      + ("correctly FAILED" if caught
                         else "PASSED - the checker is blind"))
                failures += not caught

    verdict = "PASS" if failures == 0 else f"FAIL ({failures})"
    report["verdict"] = verdict
    print(f"tmr-guard: {verdict}")
    if args.json:
        Path(args.json).write_text(json.dumps(report, indent=2))
    sys.exit(0 if failures == 0 else 1)


if __name__ == "__main__":
    main()
