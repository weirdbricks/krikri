# Performance Review — `0.9.77`

**Author:** review pass by Opus, 2026-08-05, against `0.9.77`
**Scope:** the engine only — `crystal-play.cr` and `src/`, excluding
`plugins/` (the module binaries).

**Status as of `0.9.79`: 12 of 14 items landed**, in one commit
("Land 12 of 14 OPUS_PERFORMANCE_REVIEW_0.9.77 items, plus --gathering").
Items 1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13 and 14 are done and their
write-ups have been removed; `README.md`'s Performance section and the commit
message carry the measured before/after. Headline numbers, 3 real Atlantic.net
hosts, `0.9.78` vs `0.9.79` interleaved, median of 5: cold run 16.39s → 10.13s
(1.62×), warm run 3.09s → 2.45s (1.26×), `--gathering smart` 2.10s → 1.54s
(1.36×) on a 4-play playbook.

What remains is **item 7.2** and **one sub-item of item 6**, both below. Both
are Tier 2 (per-task CPU and allocation), i.e. an order of magnitude smaller
than the Tier 1 round-trip work that already landed, and they matter most for
`localhost`/`--connection local` playbooks and very large inventories, where
there is no SSH latency to hide behind.

Note also `OPUS_PERFORMANCE_IMPROVEMENTS.md`, which this document superseded:
one site of its item 5 is still open there and is not duplicated here.

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

## 7.2. Build one `VarSubstitutor` per `(task, host)`

**Where:** thirteen construction sites in
`src/crystal_play/task_executor/executor.cr` — `:447, :509, :579, :751, :814,
:991, :1207, :1235, :1315, :1327, :1415, :1427, :1574`. A single plain remote
task routinely builds three (`when_passes?`, `execute_task_once`,
`apply_changed_failed_when`), plus a fourth if it has `delegate_to:`.

**What already landed (7.1).** `@evaluator` and `@renderer` are now built
lazily, so a `substitute` call that hits the `includes?("{{")` early return
constructs neither.

**Correction to this document's original premise.** 7.1 was predicted to remove
"5 of the 6 allocations from the common path" and most of the constructor cost.
Measured, it moved construction from 1.21 µs / 5.0 kB to **1.13 µs / 4.79 kB** —
about 7%. The reason: the constructor's cost is dominated by **copying the
entire vars hash** into a fresh `Hash(String, JSON::Any)` and adding the magic
variables, not by the six component objects, which only store a reference. The
original write-up misattributed it.

That makes 7.2 the item that actually carries this win — it is the only way to
stop paying for the hash copy 3-4× per task per host.

**Measured, for calibration:** 1.13 µs and 4.79 kB per construction, against
23.7 ns and **zero** allocation for `substitute` on a literal string. For a
task whose params contain no placeholders at all, essentially all of the cost
is still the constructor.

**Fix.** Build one substitutor per `(task, host)` in `execute_task`, after
`build_vars_context`, and thread it through `when_passes?` /
`execute_task_once` / `prepare_batch_step`.

**The one that must stay separate:** `apply_changed_failed_when` genuinely
needs a *different* context — it `dup`s `vars_context` and injects the task's
own result under its `register:` name (`executor.cr:979-982`) before evaluating
`changed_when:`/`failed_when:`. Threading the shared instance into it would make those
conditions unable to see the result they are about, which no spec may catch if
the fixtures only assert on the common cases. Leave it constructing its own.

**Verify.** `crystal spec` in full, with particular attention to
`changed_when:`/`failed_when:` and `register:` fixtures, and to `delegate_to:`
(which resolves its host through a substitutor built over a different context
again). Then a real-SSH A/B: this changes how every task's variable context is
threaded, and `--forks` fan-out means several hosts hold substitutors
concurrently.

---

## Verification requirements

Both remaining items are pure refactors with no intended behavior change, so
the bar is that nothing moves:

- `crystal spec` fully green (789 specs as of `0.9.79`, modulo the three
  documented Docker/MySQL/PostgreSQL integration cases that need live servers).
- `ameba` clean on all new and touched code — the repo carries 6 pre-existing
  findings; do not add to them.
- The `compat/` Docker harness at 39/39.
- Byte-identical playbook output before and after, against real hosts, batched
  and `--no-batching`. Local-only testing does not exercise the batch path at
  all — batching applies only to remote hosts — so a local A/B is not
  sufficient evidence for item 7.2.
- A `ROADMAP.md` entry with the *measured* before/after, including an honest
  "no measurable win" if that is the result. 7.1 is the cautionary case: its
  predicted win did not materialize, and recording that was more useful than
  the change itself.

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
