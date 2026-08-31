# Crinja differential test harness

Implements step 1 of the Crinja convergence strategy: scrapes real
`{{ }}` / `{% if %}` expressions out of every role/collection benchmarked
across rounds 1-21 (`~/scratch/round*_bench`) plus `testing/roles`, renders
each through real Python jinja2 (the oracle) and through raw Crinja
directly (bypassing `CrinjaRenderer`), and diffs the results into ranked
divergence buckets.

Not part of `crystal spec` / CI - a one-off investigation tool, run by
hand. `corpus.jsonl` / `oracle_*.jsonl` / `divergence_report.md` are
generated output, safe to delete and regenerate; not meant to be committed
(regenerate instead of trusting a stale copy - the corpus depends on
`~/scratch/round*_bench` trees that get destroyed between benchmark
rounds).

## Usage

```bash
# 1. scrape expressions from the corpus into corpus.jsonl
python3 scripts/crinja_corpus/scrape_corpus.py testing/roles ~/scratch/round*_bench

# 2. render every expression through real Python jinja2 -> oracle_python.jsonl
python3 scripts/crinja_corpus/oracle_python.py

# 3. render every expression through raw Crinja -> oracle_crinja.jsonl
crystal run scripts/crinja_corpus/oracle_crinja.cr

# 4. diff and classify -> prints bucket counts, writes divergence_report.md
python3 scripts/crinja_corpus/diff.py
```

`bench_evaluators.cr` is a separate, standalone tool in this same
directory - not part of the corpus/diff pipeline above. It measures the
hand-rolled `ExpressionEvaluator` against raw Crinja (both uncached and
with a source-keyed `Template` parse cache) for a handful of
representative expression shapes, informing the dual-evaluator-convergence
performance question. Run with `crystal run --release
scripts/crinja_corpus/bench_evaluators.cr` (release build matters, it's a
perf measurement).

Requires `python3 -c "import jinja2"` to work (`pip install jinja2` if
not). Re-run step 1 whenever a new benchmark round leaves scratch trees
behind, to widen the corpus.

## Reading the report

Buckets A/B/C/D in `divergence_report.md` are the actionable ones -
closed-form or syntax-level divergences that can't be blamed on a missing
Ansible fact value. Bucket E ("both sides error, different exception
type") is intentionally dumped without triage: skimming it shows it's
dominated by expected noise (Ansible-only filters like `ternary`/
`regex_replace`/`password_hash` that neither raw Crinja nor raw Python
jinja2 know about - this codebase's own `jinja_filters.cr` registers those
separately - and undefined-variable errors under two different exception
class names). If a future run of this harness needs to mine bucket E for
real bugs, filter out `FeatureLibrary::UnknownFeatureError` /
`TemplateAssertionError "No (filter|test) named"` pairs first.
