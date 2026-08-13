#!/usr/bin/env python3
"""
Step 1b: render every corpus.jsonl entry through real Python jinja2 (the
test oracle - see CRINJA.md Decision 1) with NO context variables bound,
so results are driven purely by syntax/literal semantics, not by guessed
Ansible fact values. Undefined-variable references resolve through
jinja2's default lenient Undefined (matches Crinja's own default
Undefined behavior closely enough for a syntax-level diff).

trim_blocks=True / lstrip_blocks=False mirrors this codebase's own
Crinja config (CrinjaRenderer#shared_env) so whitespace differences
don't create noise unrelated to expression semantics.

Writes oracle_python.jsonl: one result object per corpus line, same
order, with either {"ok": true, "output": "..."} or
{"ok": false, "error_type": "...", "error": "..."}.
"""
import json
import sys
from pathlib import Path

import jinja2

env = jinja2.Environment(trim_blocks=True, lstrip_blocks=False)


def render(kind, expr):
    if kind == "output":
        src = "{{ " + expr + " }}"
    elif kind == "condition":
        src = "{% if " + expr + " %}TRUE{% else %}FALSE{% endif %}"
    elif kind == "for_block":
        # Already a complete, self-contained {% for %}...{% endfor %}
        # span scraped verbatim from real source - no wrapper needed,
        # unlike output/condition which are bare expressions.
        src = expr
    else:
        raise ValueError(kind)

    try:
        tmpl = env.from_string(src)
        return {"ok": True, "output": tmpl.render()}
    except Exception as e:
        return {"ok": False, "error_type": type(e).__name__, "error": str(e)}


def main():
    in_path = Path(__file__).parent / "corpus.jsonl"
    out_path = Path(__file__).parent / "oracle_python.jsonl"

    n = 0
    with in_path.open() as f, out_path.open("w") as out:
        for line in f:
            entry = json.loads(line)
            result = render(entry["kind"], entry["expr"])
            result["kind"] = entry["kind"]
            result["expr"] = entry["expr"]
            out.write(json.dumps(result) + "\n")
            n += 1

    print(f"rendered {n} entries -> {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
