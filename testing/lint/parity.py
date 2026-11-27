#!/usr/bin/env python3
"""Parity harness: diff krikri-lint against ansible-lint on a corpus.

Runs both tools with parseable output over the same targets, extracts
(rule-id, line, column) triples per file, and reports:

  - matching triples                 (parity hit)
  - krikri-only triples              (krikri fires where upstream doesn't)
  - upstream-only triples            (missing rule or behavioral divergence)
  - upstream triples whose rule id is not implemented here at all
    (expected gaps; shown separately, not counted as divergences)

Targets are linted under the nearest .ansible-lint above each one (passed
as -c), so a case dir can carry its own config - a `kinds:` entry, say.

Exit code 0 when every upstream-only triple is an unimplemented rule id,
1 when there are real divergences, 2 on harness usage errors.

Usage:
  testing/lint/parity.py [targets ...]          (default: testing/)
Options:
  --krikri PATH   krikri-lint binary (default bin/krikri-lint)
  --json PATH     also write the raw diff as JSON
  -v, --verbose   also list every triple under its file

By default each file gets one summary line (matches, diverges,
unimplemented); --json is the machine-readable form.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

# ansible-lint's opt-in rules are inert unless --enable-list names them, so a
# run that never passes the flag compares zero triples for every one of them
# and looks clean (issue #1926). Upstream's option is a plain append with no
# comma splitting, while krikri-lint accepts a repeated flag too, so one argv
# fragment serves both. Keep in sync with upstream's `opt-in` tagged rules.
OPT_IN_RULES = (
    "empty-string-compare",
    "galaxy-version-incorrect",
    "no-log-password",
    "no-prompting",
    "no-same-owner",
    "only-builtins",
)
ENABLE_OPT_IN = [arg for rule in OPT_IN_RULES for arg in ("--enable-list", rule)]

GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
RESET = "\033[0m"


def paint(text, code):
    """Color only a real console; krikri-loop logs the child's output plain."""
    if sys.stdout.isatty() or os.environ.get("KRIKRI_FORCE_COLOR"):
        return f"{code}{text}{RESET}"
    return text


def count_label(count, noun, code):
    label = f"{count} {noun}"
    return paint(label, code) if count else label

# ansible-lint -p line: path:line:col: rule-id[qualifier]: message;
# some matches (e.g. name[missing]) print without a column.
# krikri-lint -p emits the same line shape, so both are parsed the same way.
ANSIBLE_RE = re.compile(r"^(?P<path>[^:]+):(?P<line>\d+)(?::(?P<col>\d+))?: (?P<rule>\S+?): ")


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
    return parse_ansible(text)


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


def config_for(target: Path) -> Path | None:
    """Nearest .ansible-lint above a target, like project discovery."""
    start = target if target.is_dir() else target.parent
    for directory in (start, *start.parents):
        candidate = directory / ".ansible-lint"
        if candidate.is_file():
            return candidate
    return None


def config_groups(targets: list[str]) -> dict[Path | None, list[str]]:
    """Group targets by their config file so each linter runs once each.

    A case that needs its own `.ansible-lint` (e.g. a `kinds:` entry that
    makes a non-.yml file a playbook) can then be linted directly; targets
    with no config above them keep the linter's own discovery.
    """
    groups: dict[Path | None, list[str]] = defaultdict(list)
    for target in targets:
        groups[config_for(Path(target))].append(target)
    return groups


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("targets", nargs="*", default=["testing"])
    parser.add_argument("--krikri", default=str(REPO / "bin" / "krikri-lint"))
    parser.add_argument("--ansible-lint", default="ansible-lint")
    parser.add_argument("--json", dest="json_out")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="also list every triple under its file")
    args = parser.parse_args()

    targets = [str(Path(t).resolve()) for t in args.targets]
    ours: set = set()
    theirs: set = set()
    for config, group in config_groups(targets).items():
        flags = ["-c", str(config)] if config else []
        ours |= set(parse_krikri(
            run([args.krikri, "-p", "--nocolor", *ENABLE_OPT_IN, *flags, *group])))
        theirs |= set(parse_ansible(
            run([args.ansible_lint, "--nocolor", "-p", *ENABLE_OPT_IN, *flags, *group])))
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
        kinds = by_file[path]
        matched_n = len(kinds.get("matched") or [])
        diverged_n = len(kinds.get("krikri_only") or []) + len(kinds.get("upstream_only") or [])
        unimplemented_n = len(kinds.get("unimplemented") or [])
        print(f"{path}: {count_label(matched_n, 'matches', GREEN)}, "
              f"{count_label(diverged_n, 'diverges', RED)}, "
              f"{count_label(unimplemented_n, 'unimplemented', YELLOW)}")

    if args.verbose:
        for path in sorted(by_file):
            print(f"\n{path}")
            for kind in ("matched", "krikri_only", "upstream_only", "unimplemented"):
                items = by_file[path].get(kind) or []
                if items:
                    print(f"  {kind}:")
                    for line, col, rule in items:
                        print(f"    {line}:{col} {rule}")

    print(f"PARITY| files={len(by_file)} matched={len(matched)} krikri_only={len(krikri_only)} "
          f"upstream_only={len(real_gaps)} unimplemented={len(gaps)}")

    if args.json_out:
        # Structured, one record per triple: krikri-role-triager --lint-parity
        # files one issue per (kind, rule) group and krikri-fix-issues verifies
        # the group is gone, so both need the fields, not a repr of a tuple.
        triples = []
        for kind, items in (("matched", matched), ("krikri_only", krikri_only),
                            ("upstream_only", real_gaps), ("unimplemented", gaps)):
            for path, line, col, rule in sorted(items):
                triples.append({"kind": kind, "path": path, "line": line,
                                "column": col, "rule": rule})
        Path(args.json_out).write_text(json.dumps({
            "targets": targets,
            "counts": {"matched": len(matched), "krikri_only": len(krikri_only),
                       "upstream_only": len(real_gaps), "unimplemented": len(gaps)},
            "triples": triples,
        }, indent=2))

    sys.exit(1 if real_gaps or krikri_only else 0)


if __name__ == "__main__":
    main()
