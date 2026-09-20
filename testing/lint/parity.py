#!/usr/bin/env python3
"""Parity harness: diff krikri-lint against real ansible-lint on a corpus.

Runs both tools with parseable output over the same targets, extracts
(rule-id, line, column) triples per file, and reports:

  - matching triples                 (parity hit)
  - krikri-only triples              (krikri fires where upstream doesn't)
  - upstream-only triples            (missing rule or behavioral divergence)
  - upstream triples whose rule id is not implemented here at all
    (expected gaps; shown separately, not counted as divergences)

Exit code 0 when every upstream-only triple is an unimplemented rule id,
1 when there are real divergences, 2 on harness usage errors.

Usage:
  testing/lint/parity.py [targets ...]          (default: testing/)
Options:
  --krikri PATH   krikri-lint binary (default bin/krikri-lint)
  --json PATH     also write the raw diff as JSON
"""

import argparse
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

# ansible-lint -p line: path:line:col: rule-id[qualifier]: message;
# some matches (e.g. name[missing]) print without a column.
ANSIBLE_RE = re.compile(r"^(?P<path>[^:]+):(?P<line>\d+)(?::(?P<col>\d+))?: (?P<rule>\S+?): ")
# krikri-lint -p line: path:line:col rule-id severity message
KRIKRI_RE = re.compile(r"^(?P<path>[^:]+):(?P<line>\d+):(?P<col>\d+) (?P<rule>\S+) (?P<sev>\w+) ")


def parse_ansible(text: str):
    out = []
    for line in text.splitlines():
        m = ANSIBLE_RE.match(line)
        if not m:
            continue
        # rule id like "name[casing][/]" - keep the id, drop the qualifier
        rule = re.match(r"[a-z0-9-]+(?:\[[^\]]+\])?", m["rule"]).group(0)
        out.append((m["path"], int(m["line"]), int(m["col"] or 0), rule))
    return out


def parse_krikri(text: str):
    out = []
    for line in text.splitlines():
        m = KRIKRI_RE.match(line)
        if m:
            out.append((m["path"], int(m["line"]), int(m["col"]), m["rule"]))
    return out


def run(cmd):
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode not in (0, 2):
        print(f"harness: {cmd[0]} exited {proc.returncode}", file=sys.stderr)
        print(proc.stderr[-2000:], file=sys.stderr)
        sys.exit(2)
    return proc.stdout


def implemented_rules(binary: str):
    out = run([binary, "--list-rules"])
    ids = {line.split()[0] for line in out.splitlines() if line.strip()}
    # rule families (name, jinja, fqcn) emit sub-rule ids
    return ids | {f"{i.split('[')[0]}[" for i in ids if "[" in i}


def is_implemented(known: set, rule_id: str) -> bool:
    if rule_id in known:
        return True
    return "[" in rule_id and f"{rule_id.split('[')[0]}[" in known


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("targets", nargs="*", default=["testing"])
    parser.add_argument("--krikri", default=str(REPO / "bin" / "krikri-lint"))
    parser.add_argument("--ansible-lint", default="ansible-lint")
    parser.add_argument("--json", dest="json_out")
    args = parser.parse_args()

    targets = [str(Path(t).resolve()) for t in args.targets]
    ours = set(parse_krikri(run([args.krikri, "-p", "--nocolor", *targets])))
    theirs = set(parse_ansible(run([args.ansible_lint, "--nocolor", "-p", *targets])))
    known = implemented_rules(args.krikri)

    # normalize to repo-relative paths
    def rel(triple):
        path, line, col, rule = triple
        p = str(Path(path).resolve().relative_to(REPO)) if path.startswith(REPO.as_posix()) else path
        return (p, line, col, rule)

    ours = {rel(t) for t in ours}
    theirs = {rel(t) for t in theirs}

    matched = ours & theirs
    krikri_only = ours - theirs
    upstream_only = theirs - ours
    gaps = {t for t in upstream_only if not is_implemented(known, t[3])}
    real_gaps = upstream_only - gaps

    print(f"matched: {len(matched)}  krikri-only: {len(krikri_only)}  "
          f"upstream-only: {len(real_gaps)}  unimplemented-upstream: {len(gaps)}")

    by_file = defaultdict(dict)
    for t in matched:
        by_file[t[0]].setdefault("matched", []).append(t[1:])
    for t in sorted(krikri_only):
        by_file[t[0]].setdefault("krikri_only", []).append(t[1:])
    for t in sorted(real_gaps):
        by_file[t[0]].setdefault("upstream_only", []).append(t[1:])
    for t in sorted(gaps):
        by_file[t[0]].setdefault("unimplemented", []).append(t[1:])

    for path in sorted(by_file):
        print(f"\n{path}")
        for kind in ("matched", "krikri_only", "upstream_only", "unimplemented"):
            items = by_file[path].get(kind) or []
            if items:
                print(f"  {kind}:")
                for line, col, rule in items:
                    print(f"    {line}:{col} {rule}")

    if args.json_out:
        Path(args.json_out).write_text(json.dumps({
            "matched": sorted(map(str, matched)),
            "krikri_only": sorted(map(str, krikri_only)),
            "upstream_only": sorted(map(str, real_gaps)),
            "unimplemented_upstream": sorted(map(str, gaps)),
        }, indent=2))

    sys.exit(1 if real_gaps or krikri_only else 0)


if __name__ == "__main__":
    main()
