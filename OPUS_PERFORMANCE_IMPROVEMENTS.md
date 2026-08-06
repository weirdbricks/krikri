# Performance Improvement Proposal

**Author:** review pass by Opus, 2026-08-05, against `0.9.64`
**Scope:** the engine only — `src/` excluding `src/crystal_play/plugin_helpers/`
and the `plugins/` binaries.

**Status as of `0.9.79`: this document is essentially complete.** Items 1, 2,
3, 4, 7, 8, 9, 10, 11 and 12 and the whole "Dead code" section landed across
`0.9.66`–`0.9.77` (verified: `src/crystal_play.cr`, `src/crystal_play/
facts_gatherer/` and `src/crystal_play/ssh_config.cr` are all gone). Their
write-ups have been removed rather than left as noise; `ROADMAP.md` carries the
measured before/after for each.

Two items were still open when `OPUS_PERFORMANCE_REVIEW_0.9.77.md` was written
and were carried forward into it:

- **Item 5** (`JSON.parse(x.to_json)` as a mutable copy) → review item 5, which
  landed in `0.9.79`. One site the review never named is still open; it is the
  only item left in this document and is written up below.
- **Item 6** (`VarSubstitutor` rebuilt per task) → **review item 7**, still
  partly open. Track it there, not here — do not work from this document's
  copy.

---

## 5. `JSON.parse(x.to_json)` used as "give me a mutable copy" — one site left

**Where:** `crystal-play.cr:47`, in the `__async_run` entry point.

```crystal
result_hash = JSON.parse(result.to_json).as_h
result_hash["finished"] = JSON::Any.new(1_i64)
```

**Problem.** Serializes a `JSON::Any` to a string and re-parses it purely to
obtain a mutable `Hash(String, JSON::Any)`. It then adds a single **top-level**
key, so a shallow `.as_h.dup` is equivalent — nothing mutates a nested value.

The three executor sites this item originally listed
(`apply_changed_failed_when`, the per-loop-item copy, and `register_result`)
were converted in `0.9.66`, and the fourth, `PluginManager#
execute_remote_plugin`, was removed outright in `0.9.79` when the remote config
path stopped round-tripping at all. This one was missed by both passes: the
review's item 5 rewrote the *solo config* path and never looked at
`__async_run`, which reads a config back from a job file and still uses the old
JSON::Any entry point.

**Measured** (release build, `Benchmark.ips`):

| result size | `JSON.parse(r.to_json).as_h` | `r.as_h.dup` | speedup |
|---|---|---|---|
| 8 KB `stdout` | 29.8 µs, 17.2 kB/op | **37 ns, 208 B/op** | **814×** |
| small result | 670 ns, 1.31 kB/op | **37 ns, 208 B/op** | **18×** |

Temper the headline number against where it actually sits: this runs **once per
async job**, in a detached background process, not once per task. The 814× is
real but the absolute saving is microseconds on a code path that has already
paid for a process spawn. Worth doing because it is one line and removes the
last instance of a pattern this repo has otherwise eliminated — not because it
will show up in a wall-clock measurement.

**Fix.** `result_hash = result.as_h.dup`.

**Verify.** `crystal spec` in full, plus a real-mode (not `--check`) run of
`testing/test-async-quick.yml` against `spec/fixtures/inventory-testservers-
local.ini` — `--check` skips the async path entirely, so a check-mode run
proves nothing here. Compare output before and after; only the generated job id
should differ.

---

## Verification requirements

1. `crystal spec` fully green (789 specs as of `0.9.79`, modulo the three
   documented Docker/MySQL/PostgreSQL integration cases that need live
   servers).
2. `ameba` clean on all touched code — the repo currently carries 6
   pre-existing findings; do not add to them.
3. The `compat/` harness still at 39/39.
4. A `ROADMAP.md` entry with the *measured* before/after. Do not record an
   improvement that was not measured — including honest "no measurable win"
   results, as the `0.9.63` entry already does.
