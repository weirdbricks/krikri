#!/usr/bin/env python3
"""Diff krikri-lint against ansible-lint over a playbook corpus.

Both tools' -p output is normalized down to (path, line, rule-id)
triples so the comparison is about findings, not formatting: krikri
prints a severity field and an explicit column where upstream prints a
"[/]" qualifier instead, and upstream writes the task name after the
line for task-oriented rules.

Usage:
  testing/lint/corpus_diff.py [root ...]   (default: ./testing)
"""

import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

OURS_RE = re.compile(r"^(?P<path>[^:]+):(?P<line>\d+):(?P<col>\d+) (?P<rule>\S+) ")
THEIRS_RE = re.compile(r"^(?P<path>[^:]+):(?P<line>\d+)(?::(?P<col>\d+))?: (?P<rule>\S+?)(?:\[\w+\])?:\s")


def parse(text, pattern):
    out = set()
    for line in text.splitlines():
        m = pattern.match(line)
        if m:
            rule = m["rule"].split("[")[0]
            sub = m["rule"].split("[")[1][:-1] if "[" in m["rule"] else ""
            ident = f"{rule}[{sub}]" if sub else rule
            # Both tools echo back the path as given; normalize
            # absoluteness so an absolute invocation on one side and a
            # relative one on the other still line up.
            out.add((key(m["path"]), int(m["line"]), ident))
    return out


def run(cmd, cwd=None):
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=600, cwd=cwd)
    return proc.stdout


def key(path):
    """Absolute path -> a path both tools agree on. Both echo the path
    they were given; running both from the corpus root with relative
    paths makes those agree without absolute/relative mismatch."""
    return str(Path(path))


def main():
    binary = str(Path(sys.argv[1]).resolve())
    roots = [Path(a) for a in sys.argv[2:]] or [Path("testing")]
    # Run both tools from the corpus root with relative paths, so the
    # path each echoes back is identical between them.
    corpus = Path(os.path.commonpath([str(r.resolve()) for r in roots]))
    paths = sorted(
        str(p.resolve().relative_to(corpus))
        for r in roots
        for p in r.rglob("*.yml")
    )

    ours, theirs = defaultdict(set), defaultdict(set)
    for path in paths:
        ours[path] = parse(run([binary, "-p", "--nocolor", path], corpus), OURS_RE)
        theirs[path] = parse(
            run(["ansible-lint", "--nocolor", "-p", path], corpus), THEIRS_RE
        )

    totals = defaultdict(int)
    per_file = defaultdict(lambda: (set(), set()))
    for path in paths:
        for name, line, ident in ours[path]:
            per_file[name][0].add((line, ident))
        for name, line, ident in theirs[path]:
            per_file[name][1].add((line, ident))

    print(f"{'file':60} {'krikri':>7} {'upstream':>9}  missing / extra")
    # Key on the path each tool *reported*, not the one it was handed:
    # ansible-lint follows import_tasks/include_tasks and attributes a
    # finding to the file that actually contains it.
    for name in sorted(per_file):
        ours_f, theirs_f = per_file[name]
        missing = theirs_f - ours_f
        extra = ours_f - theirs_f
        if not missing and not extra:
            totals["identical"] += 1
            continue
        totals["differing"] += 1
        print(f"{name[-60:]:60} {len(ours_f):>7} {len(theirs_f):>9}  "
              f"{len(missing)} / {len(extra)}")
        for t in sorted(missing):
            print(f"    upstream-only  {t[0]}:{t[1]}")
        for t in sorted(extra):
            print(f"    krikri-only    {t[0]}:{t[1]}")
    print()
    print(f"files with findings: {len(per_file)}  identical: {totals['identical']}  "
          f"differing: {totals['differing']}")


if __name__ == "__main__":
    main()