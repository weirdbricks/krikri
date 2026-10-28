#!/usr/bin/env bash
# Weight test files by MEASURED per-test wall time from a MINITEST_TIMINGS
# file (written by test/minitest_helper.cr's run_one hook), for
# scripts/minitest.sh's LPT shard balancing. Usage:
#
#   scripts/minitest_file_weights.sh <timings.tsv> <file> [file...]
#
# Emits "weight<TAB>file", sorted heaviest-first - the same shape as the
# it-count fallback inside minitest.sh, so its assignment loop is unchanged.
#
# Timings record test names as "describe chain#test_method". The chain is
# the describe strings joined with "::" verbatim; the method is "test_" plus
# the `it` string with every non-letter/digit run collapsed to "_", exactly
# the mangling in lib/minitest/src/spec.cr and minitest_helper.cr's own
# `it` macro. This script reconstructs that per file (skipping heredocs,
# so playbook fixture content cannot inject phantom names) and sums each
# file's max-per-name seconds. Names that reconstruct to more than one file
# are dropped (ambiguous). Files, or individual tests, with no measurement
# fall back to the suite-wide seconds-per-test average times their `it`
# count, so a file that is entirely dynamic (`it {{ ... }}` interpolation)
# still carries its count-proportional share.
set -euo pipefail

# Byte-order collation everywhere: join rejects the field sorts otherwise
# (test names contain `{%`, parens, ...), and C locale keeps it deterministic.
export LC_ALL=C

timings=${1:?usage: minitest_file_weights.sh <timings.tsv> <file>...}
shift

tab=$'\t'
index=$(mktemp)
maxes=$(mktemp)
maxes2=$(mktemp)
dups=$(mktemp)
joined=$(mktemp)
trap 'rm -f "$index" "$maxes" "$maxes2" "$dups" "$joined"' EXIT

# name<TAB>file for every statically-named test. The block tracker (every
# construct that owns an `end`, plus heredocs) only has to be right enough
# that describe/it capture inside real code, not fixture text: a file whose
# stack desyncs reconstructs no (or wrong) names and falls back to the
# it-count weight.
for f in "$@"; do
  awk -v file="$f" '
    FNR == 1 { nd = 0; inh = 0 }
    {
      line = $0
      if (inh) {
        # a <<- terminator may be indented; a trailing comma continues an
        # argument list but the heredoc itself has ended
        if (line ~ ("^[[:space:]]*" hterm "([[:space:]]*,)?[[:space:]]*$")) inh = 0
        next
      }
      if (match(line, /<<[-~]?"?[A-Za-z_][A-Za-z0-9_]*"?/)) {
        hterm = substr(line, RSTART, RLENGTH)
        sub(/^<<[-~]?"?/, "", hterm); sub(/"$/, "", hterm)
        inh = 1
      }
      if (match(line, /^[[:space:]]*it[[:space:]]+"(.*)"[[:space:]]+do[[:space:]]*$/)) {
        str = substr(line, RSTART, RLENGTH)
        sub(/^[[:space:]]*it[[:space:]]*"/, "", str)
        sub(/"[[:space:]]+do[[:space:]]*$/, "", str)
        gsub(/\\"/, "\"", str)
        # method name, exactly the macro rule: "test_" plus the it string
        # with every non-letter/digit run collapsed to "_"
        meth = str
        gsub(/[^[:alnum:]]+/, "_", meth)
        meth = "test_" meth
        if (meth ~ /^test_[[:alnum:]_]+$/) {
          chain = ""
          for (i = 1; i <= nd; i++) if (stack[i] != "") chain = chain (chain == "" ? "" : "::") stack[i]
          printf "%s#%s\t%s\n", chain, meth, file
        }
        stack[++nd] = ""
        next
      }
      if (match(line, /^[[:space:]]*describe[[:space:]]+"(.*)"[[:space:]]+do[[:space:]]*$/)) {
        str = substr(line, RSTART, RLENGTH)
        sub(/^[[:space:]]*describe[[:space:]]*"/, "", str)
        sub(/"[[:space:]]+do[[:space:]]*$/, "", str)
        gsub(/\\"/, "\"", str)
        stack[++nd] = str
        next
      }
      if (line ~ /^[[:space:]]*(if|unless|case|def|begin|while|until|class|module|struct|macro)([^[:alnum:]_]|$)/ ||
          line ~ /[[:space:]]do([[:space:]]*\|[^|]*\|)?[[:space:]]*$/) {
        stack[++nd] = ""
        next
      }
      if (line ~ /^[[:space:]]*end([^[:alnum:]_]|$)/ && nd > 0) nd--
    }
  ' "$f" >> "$index"
done

# Max seconds per test name - the same "max over records" rule as
# scripts/minitest_timings.sh (run_one is entered several times per test
# under nested describes; only one record does real work). Always assigns,
# so a 0-second test records 0 rather than leaving the entry unset, and
# sorts, so the join below always sees sorted input.
awk -F'\t' '{ t = $1 + 0; if (t > m[$3] + 0) m[$3] = t } END { for (k in m) print k "\t" m[k] + 0 }' \
  "$timings" | sort > "$maxes"

# Drop names reconstructing to more than one file. (The NR==FNR idiom
# only works when the first file is non-empty - with zero duplicates the
# whole maxes file would be swallowed - hence the branch.)
if [ -s "$dups" ]; then
  awk -F'\t' 'NR == FNR { d[$1] = 1; next } !($1 in d)' "$dups" "$maxes" | sort > "$maxes2"
else
  cp "$maxes" "$maxes2"
fi
sort -t "$tab" -k1,1 -k2,2 "$index" > "$index.s"

join -t "$tab" "$index.s" "$maxes2" |
  awk -F'\t' '{ sum[$2] += $3; n[$2]++ } END { for (f in sum) printf "%.2f\t%d\t%s\n", sum[f], n[f], f }' > "$joined"

# Suite-wide seconds-per-`it` average: total measured seconds over total
# it-counts, the same scale the count-only fallback lives on.
total_sec=$(awk -F'\t' '{ t += $1 } END { printf "%.6f", t }' "$maxes2")
total_cnt=$(cat "$@" /dev/null |
  awk '/^[[:space:]]*it[[:space:](]/ { c++ } END { printf "%d", c + 0 }')
avg=$(awk -v t="$total_sec" -v c="$total_cnt" 'BEGIN { printf "%.6f", (c > 0 ? t / c : 0) }')

# Per file: measured seconds plus the count fallback for its unmeasured
# tests. Weights are scaled x10 and truncated: the scale keeps the
# seconds-per-test fallback (avg ~0.13s/test) above truncation, and the
# integer keeps run-to-run timing jitter from flipping a file between
# shards, which would change the hashed entrypoints and force shard
# recompiles. LPT is scale-invariant.
for f in "$@"; do
  read -r measured matched <<< "$(awk -F'\t' -v f="$f" '$3 == f { print $1, $2 }' "$joined")"
  cnt=$(awk '/^[[:space:]]*it[[:space:](]/ { c++ } END { print c + 0 }' "$f")
  weight=$(awk -v m="${measured:-0}" -v mc="${matched:-0}" -v c="$cnt" -v avg="$avg" \
    'BEGIN { w = (m + (c - mc) * avg) * 10; printf "%.2f", (w < 1 ? 1 : w) }')
  printf '%d\t%s\n' "${weight%%.*}" "$f"
done | sort -t "$tab" -k1,1nr -k2,2
