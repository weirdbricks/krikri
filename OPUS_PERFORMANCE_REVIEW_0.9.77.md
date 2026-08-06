# Performance Review — `0.9.77`

**Author:** review pass by Opus, 2026-08-05, against `0.9.77`
**Scope:** the engine only — `crystal-play.cr` and `src/`, excluding
`plugins/` (the module binaries).

**Status as of `0.9.80`: 13 of 14 items landed.** Items 1-5 and 7-14 shipped in
`0.9.79`-`0.9.80`; their write-ups have been removed. `README.md`'s Performance
section and the commit log carry the measured before/after. Headline numbers,
3 real Atlantic.net hosts, interleaved, median of 5: cold run 16.39s -> 10.13s
(1.62x), warm run 3.09s -> 2.45s (1.26x), `--gathering smart` 2.10s -> 1.54s
(1.36x) on a 4-play playbook.

**Item 7.2 closed in `0.9.80`**: one `VarSubstitutor` per `(task, host)`,
threaded through `resolve_delegate_host` / `resolve_fileglob` / `when_passes?` /
`execute_task_once` / `prepare_batch_step`. Measured by counting constructions
at runtime rather than guessing: a `when:`-heavy playbook against 3 real hosts
went from **93 to 48 constructions (-48.3%)**, batched and `--no-batching`
alike; a local `when:`-heavy playbook halved (30 -> 15). Wall clock did not
move (1.79s -> 1.78s, well inside noise) and was not expected to — at ~1.1 us
per construction this is allocation pressure, not latency. It matters for very
large inventories, not for a 12-task playbook.

Two things that measurement settled, worth not re-deriving:

- The win only exists where two substitutors were genuinely built over the
  *same* context: a task with `when:`, a `delegate_to:`, or the batch path
  (`when_passes?` + `prepare_batch_step`). A plain task without `when:` always
  built exactly one, because `when_passes?` returns before constructing when
  there is no condition. Most `testing/*.yml` fixtures show 0% for that reason
  and that is correct, not a failed change.
- Building the shared instance eagerly at the top of `execute_task` is a
  **regression**, not an optimization: the loop and `until:` paths return
  before reaching `execute_task_once` and build their own per item / per
  attempt, so an eager instance is pure waste. Measured at -34.8% (23 -> 31
  constructions) on `test-loop-quick` before being corrected to build it only
  on the paths that use it.

What remains is **one sub-item of item 6**, below - a duplication fix, not a
performance one.

---

## 6 (residual). The duplicated Crinja value converter

**Where:** `src/crystal_play/template_action_plugin.cr:52-86`
(`render_template`), whose `json_any_to_crinja_value` at `:106` is a verbatim
copy of the one in
`src/crystal_play/variable_substitutor/crinja_renderer.cr:76`.

**What already landed.** `CrinjaRenderer` now shares one process-wide `Crinja`
environment instead of constructing one per `{% %}` render, and memoizes its
`JSON::Any -> Crinja::Value` conversion per renderer instance — together
21.08 µs / 61.9 kB → 9.28 µs / 32.2 kB per render.

**What did not.** `TemplateActionPlugin#render_template` still builds its own
`Crinja.new` at `:55` and carries its own copy of the converter.

**Fix — and read the constraint.** The environment there **cannot** be shared
the way `CrinjaRenderer`'s is: its `trim_blocks`/`lstrip_blocks` come from the
task's own `template:` params, so the config genuinely varies per task, which
is exactly the invariance the shared environment depends on. Do not "fix" this
by pointing it at the shared env.

The converter is the part worth extracting — it is pure and identical in both
places. Move it to one home (a module-level function, or a class method on
`CrinjaRenderer`) and have both call it.

This is a duplication fix, not a performance one. There is no measurement to
quote and none should be invented; the win is that a future change to
JSON→Crinja coercion cannot silently apply to only one of the two template
paths.

**Verify.** `crystal spec` in full, plus every `compat/` playbook that uses
`template:` with `trim_blocks`/`lstrip_blocks`, since those params are the
reason the two environments must stay separate.

---

## Verification requirements

The remaining item is a pure refactor with no intended behavior change, so the
bar is that nothing moves:

- `crystal spec` fully green (789 specs as of `0.9.80`, modulo the three
  documented Docker/MySQL/PostgreSQL integration cases that need live servers).
- `ameba` clean on all new and touched code — the repo carries 6 pre-existing
  findings; do not add to them.
- The `compat/` Docker harness at 39/39.
- Byte-identical playbook output before and after, against real hosts, batched
  and `--no-batching`. Local-only testing does not exercise the batch path at
  all — batching applies only to remote hosts — so a local A/B is not
  sufficient evidence for anything touching it. This is how 7.2 was verified:
  51 result lines identical across batched/`--no-batching` × fresh/idempotent
  against 3 real hosts.
- A `ROADMAP.md` entry with the *measured* before/after, including an honest
  "no measurable win" if that is the result. 7.1/7.2 are the cautionary case:
  7.1's predicted win did not materialize, and 7.2's real one is invisible in
  wall clock. Recording both honestly was more useful than either change.

---

## Benchmark harness

Both benchmark programs must live inside the repo root (Crystal resolves
`require "./src/..."` relative to the requiring file, and absolute-path
requires are not supported). Delete them afterward.

Build the variable context from the *real* `facts` plugin rather than a
synthetic hash, so the shape and size match production — this yields a 44-key
context with a 3,889-byte `vars`, which is what every number above was measured
against:

```crystal
require "benchmark"
require "./src/crystal_play/variable_substitutor"
require "json"

facts = JSON.parse(
  `echo '{"host":{"name":"l","user":"x","port":22},"params":{},"vars":{}}' | ./bin/plugins/facts`
)["ansible_facts"].as_h
vars = Hash(String, JSON::Any).new
facts.each { |k, v| vars[k] = v }
10.times { |i| vars["play_var_#{i}"] = JSON::Any.new("value#{i}") }
vars["result"] = JSON.parse({"rc" => 0, "stdout" => "x" * 2000, "changed" => true}.to_json)

Benchmark.ips do |x|
  x.report("VarSubstitutor.new") { CrystalPlay::VarSubstitutor.new(vars: vars, host_name: "h") }

  sub = CrystalPlay::VarSubstitutor.new(vars: vars, host_name: "h")
  x.report("substitute literal")    { sub.substitute("no placeholders here") }
  x.report("substitute plain {{ }}") { sub.substitute("hello {{ play_var_1 }}") }
end
```

Run with `crystal run --release`. A non-release build inverts several of these
ratios and is not a valid basis for any claim here.

For anything measured against real hosts, see the `atlantic-bench-hosts`
workflow: 3 throwaway Atlantic.net instances, before/after binaries run
**interleaved** with a median of 5. Single runs on that network path are
swamped by jitter and will not reproduce these numbers.
