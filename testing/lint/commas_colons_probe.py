#!/usr/bin/env python3
"""Compare krikri-lint's yaml[commas]/yaml[colons] against yamllint directly.

The parity harness only sees ansible-lint's output, which hides most
cosmetic problems whenever a file fails to load. This probe runs both
engines over the same files and diffs every (line, rule, message)
triple, so tokenizer divergences surface even on files ansible-lint
aborts on.
"""

import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, "/usr/lib/python3/dist-packages")
from yamllint.linter import run  # noqa: E402
from ansiblelint.yaml_utils import load_yamllint_config  # noqa: E402

RULES = ("commas", "colons")


def yamllint_triples(path):
    try:
        text = Path(path).read_text()
    except OSError:
        return set()
    out = set()
    try:
        problems = list(run(text, load_yamllint_config(), filepath=str(path)))
    except Exception:
        return out
    for p in problems:
        if p.rule in RULES:
            # ansible-lint capitalizes yamllint's descriptions before
            # printing them, so compare case-insensitively.
            out.add((p.line, p.rule, p.desc.lower()))
    return out


def krikri_triples(binary, paths):
    proc = subprocess.run(
        [binary, "-p", "--nocolor", *paths], capture_output=True, text=True, timeout=300
    )
    out = set()
    pattern = re.compile(r"^\S+?:(\d+):(\d+) (\S+) \S+ (.*)$")
    for line in proc.stdout.splitlines():
        m = pattern.match(line)
        if not m or m.group(3) not in (f"yaml[{r}]" for r in RULES):
            continue
        out.add((int(m.group(1)), m.group(3)[5:-1], m.group(4).lower()))
    return out


def main():
    binary = sys.argv[1] if len(sys.argv) > 1 else "bin/krikri-lint"
    roots = [Path("testing")]
    if len(sys.argv) > 2:
        roots += [Path(a) for a in sys.argv[2:]]
    paths = [str(p) for r in roots for p in r.rglob("*.y*ml")]
    bad = 0
    hits = 0
    for path in paths:
        theirs = yamllint_triples(path)
        ours = krikri_triples(binary, [path])
        if not theirs and not ours:
            continue
        hits += 1
        missing = theirs - ours
        extra = ours - theirs
        if missing or extra:
            bad += 1
            print(path)
            for t in sorted(missing):
                print("  upstream-only:", t)
            for t in sorted(extra):
                print("  krikri-only:   ", t)
    print(f"files with hits on either side: {hits}  diverging: {bad}")


if __name__ == "__main__":
    main()