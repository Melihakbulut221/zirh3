#!/usr/bin/env python3
# =============================================================================
# ZIRH - the traceability gate (PROGRAM.md H49)
#
#   python3 scripts/trace_check.py
#
# Enforces requirements.yaml in CI:
#   FAIL  a requirement references a test file that does not exist
#   FAIL  a requirement has no tests at all
#   WARN  a test module in test/ that no requirement claims (drift the
#         other way - coverage exists but the matrix does not know it)
#
# No YAML library dependency: the file's shape is fixed and the parser
# is deliberately dumb, so the gate runs on a bare python3 anywhere.
# =============================================================================

import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
text = (root / "requirements.yaml").read_text()

reqs = []
cur = None
in_tests = False
for line in text.splitlines():
    m = re.match(r"\s*- id: (\S+)", line)
    if m:
        cur = {"id": m.group(1), "tests": []}
        reqs.append(cur)
        in_tests = False
        continue
    if cur is None:
        continue
    if re.match(r"\s*tests:\s*$", line):
        in_tests = True
        continue
    if in_tests:
        t = re.match(r"\s*- (\S+)\s*$", line)
        if t:
            cur["tests"].append(t.group(1))
        else:
            in_tests = False

fail = 0
claimed = set()
for r in reqs:
    if not r["tests"]:
        print(f"FAIL {r['id']}: requirement without a test")
        fail += 1
    for t in r["tests"]:
        claimed.add(t)
        if not (root / t).exists():
            print(f"FAIL {r['id']}: missing test file {t}")
            fail += 1

orphans = []
for p in sorted((root / "test").glob("test_*.py")):
    rel = f"test/{p.name}"
    if rel not in claimed:
        orphans.append(rel)
for rel in orphans:
    print(f"WARN orphan test module (no requirement claims it): {rel}")

print(f"trace: {len(reqs)} requirements, {len(claimed)} test refs, "
      f"{len(orphans)} orphans, {fail} failures")
sys.exit(1 if fail else 0)
