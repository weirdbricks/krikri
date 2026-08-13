#!/usr/bin/env python3
"""
Step 1 of CRINJA.md's differential-test-harness plan.

Scrapes every `{{ ... }}` output expression and every `{% if ... %}` /
`{% elif ... %}` condition expression out of a corpus of real Ansible
role/collection files (the roles benchmarked across rounds 1-21, plus
testing/roles), dedupes by expression text, and writes one JSON object
per line to corpus.jsonl:

  {"expr": "<raw text between the delimiters>", "kind": "output"|"condition",
   "sources": ["path1", "path2", ...]}

`kind=output` entries are used as-is (`{{ expr }}` is already a complete,
renderable template). `kind=condition` entries need a synthetic wrapper
(`{% if expr %}TRUE{% else %}FALSE{% endif %}`) added by the oracle
scripts, since a bare `{% if %}` is not renderable alone.

Deliberately NOT extracted: `{% for x in EXPR %}` iterables, `{% set %}`
targets/values, raw block tags. Output + condition expressions cover the
large majority of real bug reports in CRINJA.md; broaden later if the
harness proves useful and cheap to extend.
"""
import json
import re
import sys
from pathlib import Path

EXT = {".yml", ".yaml", ".j2", ".jinja2", ".jinja"}
SKIP_DIR_PARTS = {".terraform", ".git", "molecule", ".reuse"}

OUTPUT_RE = re.compile(r"\{\{(.*?)\}\}", re.DOTALL)
IF_RE = re.compile(r"\{%-?\s*(?:if|elif)\s+(.*?)-?%\}", re.DOTALL)


def iter_files(roots):
    for root in roots:
        root = Path(root)
        if not root.exists():
            continue
        for p in root.rglob("*"):
            if not p.is_file():
                continue
            if p.suffix.lower() not in EXT:
                continue
            if any(part in SKIP_DIR_PARTS for part in p.parts):
                continue
            yield p


def main():
    roots = sys.argv[1:]
    if not roots:
        print("usage: scrape_corpus.py <dir> [<dir> ...]", file=sys.stderr)
        sys.exit(1)

    seen = {}  # (kind, expr) -> set of source files
    files_scanned = 0

    for path in iter_files(roots):
        files_scanned += 1
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue

        for m in OUTPUT_RE.finditer(text):
            expr = m.group(1).strip()
            if not expr:
                continue
            key = ("output", expr)
            seen.setdefault(key, set()).add(str(path))

        for m in IF_RE.finditer(text):
            expr = m.group(1).strip()
            if not expr:
                continue
            key = ("condition", expr)
            seen.setdefault(key, set()).add(str(path))

    out_path = Path(__file__).parent / "corpus.jsonl"
    with out_path.open("w") as f:
        for (kind, expr), sources in sorted(seen.items()):
            f.write(json.dumps({
                "kind": kind,
                "expr": expr,
                "sources": sorted(sources)[:3],
            }) + "\n")

    print(f"files scanned: {files_scanned}", file=sys.stderr)
    print(f"distinct expressions: {len(seen)}", file=sys.stderr)
    print(f"wrote: {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
