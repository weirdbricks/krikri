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

`kind=for_block` entries are COMPLETE `{% for %}...{% endfor %}` blocks,
verbatim from the source file (nesting-aware - an inner `{% for %}` inside
the block doesn't prematurely match the outer block's own `{% endfor %}`),
used as-is same as `output`. Added 2026-08-13 after a live real-host
verification round found a real bug (a ternary-parser/for-loop `if`-clause
parsing collision) that this harness's original `{{ }}`/`{% if %}`-only
corpus structurally could never have caught - it only manifests when a
real `{% for %}` block, with its own body, actually executes. The harness
sizes DIVERGENCES; a corpus of ISOLATED expressions can only ever size
divergences in isolated expressions, not construct INTERACTIONS - see
CRINJA.md's "Live re-verification" section for the fuller argument.
Deliberately NOT (yet) extracted: `{% set %}...{% endset %}` block-assign
bodies, `{% block %}`/`{% macro %}` bodies, whole-file rendering - for_block
is the one control-flow construct a real live bug was actually traced to;
broaden further only if another live round finds another construct-
interaction class the corpus still misses.
"""
import json
import re
import sys
from pathlib import Path

EXT = {".yml", ".yaml", ".j2", ".jinja2", ".jinja"}
SKIP_DIR_PARTS = {".terraform", ".git", "molecule", ".reuse"}

OUTPUT_RE = re.compile(r"\{\{(.*?)\}\}", re.DOTALL)
IF_RE = re.compile(r"\{%-?\s*(?:if|elif)\s+(.*?)-?%\}", re.DOTALL)
TAG_RE = re.compile(r"\{%-?\s*(\w+)")


def extract_for_blocks(text):
    """Nesting-aware extraction of complete {% for %}...{% endfor %} spans.

    Walks every {% %} tag in source order, tracking a stack of open `for`
    tags' start offsets. A `for` pushes its start position; an `endfor`
    pops the innermost open `for` and yields the full span from that
    start through the end of this `endfor` tag (inclusive) - so a block
    containing a NESTED `{% for %}` yields both the outer block (once,
    spanning the whole nested structure) and the inner block (once,
    on its own), never a truncated/mismatched pairing.
    """
    stack = []
    for m in re.finditer(r"\{%-?.*?-?%\}", text, re.DOTALL):
        tag_match = TAG_RE.match(m.group(0))
        if not tag_match:
            continue
        name = tag_match.group(1)
        if name == "for":
            stack.append(m.start())
        elif name == "endfor" and stack:
            start = stack.pop()
            yield text[start:m.end()]


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

        for block in extract_for_blocks(text):
            block = block.strip()
            if not block:
                continue
            key = ("for_block", block)
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
