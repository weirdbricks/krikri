#!/usr/bin/env python3
"""
Step 1d: join oracle_python.jsonl and oracle_crinja.jsonl on (kind, expr)
and classify divergences into ranked buckets, per CRINJA.md's plan:
"Expected output: a ranked list of divergence classes, which then sizes
Decision 3."

Buckets, most actionable first:

  A. crinja_syntax_error_python_ok - Crinja raises TemplateSyntaxError (or
     any parse-time exception) on an expression real Jinja2 parses cleanly.
     Highest-confidence real bugs: syntax gaps, independent of any guessed
     variable value.
  B. crinja_error_python_ok_no_undefined - Crinja raises ANY exception
     (including runtime ones) on an expression that (a) Python renders
     successfully AND (b) contains no plausible undefined-variable
     dependency (no UndefinedError on the Python side). These are
     closed-form/literal expressions - a Crinja failure here can't be
     blamed on missing context.
  C. value_mismatch_no_undefined - both sides succeed, neither depends on
     an undefined variable (Python raised no UndefinedError), but the
     rendered text differs. Real semantic bugs (e.g. bool stringification,
     truthiness, filter behavior).
  D. python_error_crinja_ok - the mirror of A/B: Python fails, Crinja
     succeeds. Usually a sign the harness's synthetic wrapping is wrong
     for that expression, but occasionally a genuine "Crinja is more
     lenient than spec" case worth a look.
  E. both_error_different_type - both sides raise, but for what look like
     different reasons (excluded from the headline count, low signal,
     dumped separately for manual skim).

Anything where the Python side raised UndefinedError (i.e. the expression
genuinely needs real Ansible fact data we don't have) is excluded from
comparison entirely - noise, not signal - EXCEPT bucket A/B where a raw
syntax/parse-time failure on the Crinja side can't be explained by a
missing variable at all (parse failures happen before any variable lookup).
"""
import json
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).parent


def load(name):
    rows = {}
    with (HERE / name).open() as f:
        for line in f:
            r = json.loads(line)
            rows[(r["kind"], r["expr"])] = r
    return rows


def is_parse_time(error_type: str) -> bool:
    return "SyntaxError" in error_type or "ParseError" in error_type


def main():
    py = load("oracle_python.jsonl")
    cr = load("oracle_crinja.jsonl")

    buckets = defaultdict(list)

    keys = sorted(set(py) & set(cr))
    for key in keys:
        p, c = py[key], cr[key]
        kind, expr = key

        p_ok, c_ok = p["ok"], c["ok"]
        p_undef = (not p_ok) and p.get("error_type") == "UndefinedError"

        if c_ok and not p_ok and not p_undef:
            buckets["D_python_error_crinja_ok"].append((key, p, c))
            continue

        if p_ok and not c_ok:
            if is_parse_time(c.get("error_type", "")):
                buckets["A_crinja_syntax_error_python_ok"].append((key, p, c))
            elif not p_undef:
                buckets["B_crinja_error_python_ok_no_undefined"].append((key, p, c))
            else:
                buckets["B2_crinja_error_python_ok_undefined_present"].append((key, p, c))
            continue

        if p_ok and c_ok:
            if p["output"] != c["output"] and not p_undef:
                buckets["C_value_mismatch_no_undefined"].append((key, p, c))
            elif p["output"] != c["output"]:
                buckets["C2_value_mismatch_undefined_present"].append((key, p, c))
            continue

        if not p_ok and not c_ok:
            if p.get("error_type") != c.get("error_type"):
                buckets["E_both_error_different_type"].append((key, p, c))
            continue

    order = [
        "A_crinja_syntax_error_python_ok",
        "B_crinja_error_python_ok_no_undefined",
        "C_value_mismatch_no_undefined",
        "D_python_error_crinja_ok",
        "B2_crinja_error_python_ok_undefined_present",
        "C2_value_mismatch_undefined_present",
        "E_both_error_different_type",
    ]

    print(f"total distinct expressions: {len(keys)}")
    for name in order:
        print(f"{name}: {len(buckets[name])}")

    report_path = HERE / "divergence_report.md"
    with report_path.open("w") as out:
        out.write("# Crinja differential-harness divergence report\n\n")
        out.write(f"Total distinct expressions compared: {len(keys)}\n\n")
        for name in order:
            rows = buckets[name]
            out.write(f"\n## {name} ({len(rows)})\n\n")
            for (kind, expr), p, c in rows:
                out.write(f"- kind={kind} `{expr}`\n")
                if p["ok"]:
                    out.write(f"  - python: `{p['output']!r}`\n")
                else:
                    out.write(f"  - python: {p['error_type']}: {p['error'][:200]!r}\n")
                if c["ok"]:
                    out.write(f"  - crinja: `{c['output']!r}`\n")
                else:
                    out.write(f"  - crinja: {c['error_type']}: {c['error'][:200]!r}\n")
    print(f"\nfull report written to {report_path}")


if __name__ == "__main__":
    main()
