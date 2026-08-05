# Performance Improvement Proposal

**Author:** review pass by Opus, 2026-08-05, against `0.9.64`
**Scope:** the engine only — `src/` excluding `src/crystal_play/plugin_helpers/`
and the `plugins/` binaries. Plugin-internal work (native syscall conversion,
etc.) is already well covered by `ROADMAP.md`'s `0.9.15`-`0.9.23` and `0.9.61`
entries and was deliberately left out of this review.
**Intended implementer:** Sonnet, one item per commit.

---

## How to read this

Every claim below was measured or verified against the shipped binary, not
assumed — matching this repo's existing methodology. Where a number appears,
the benchmark that produced it is reproducible from "Benchmark harness" at the
bottom of this document.

Items are ordered by expected real-world impact, and each is independently
landable. **Do them in the order listed within each tier**, but tiers do not
depend on each other — Tier 2 item 4 is the single best value-per-line change
in the document and can land first if you want an early win.

Each item states: what's wrong, where, the evidence, the fix, and how to
verify it. An item is not done until its verification step passes.

---

## Tier 1 — remote round trips

This is where real wall-clock time goes for any playbook targeting real hosts.
`ROADMAP.md`'s `0.9.63` entry already established the framing: batching saves
round trips, not real work, and the win scales with link latency.

### 1. Loop iterations are never batched — one SSH round trip per item

**Where:** `src/crystal_play/task_batcher.cr:99-102`
(`needs_controller_control_flow?`), consumed by
`src/crystal_play/task_executor/executor.cr:795` (`execute_looped_task`).

**Problem.** `TaskBatcher` excludes any task with `loop_items` /
`loop_fileglob` / `loop_template_kind` from batching, with the comment
"batching N *iterations* of one task is a distinct, separate opportunity from
batching N *different* tasks (out of scope for this v1)". As a result
`execute_looped_task` calls `execute_task_once` once per item, and each call
goes through `PluginManager.execute_plugin` → `SSHManager.exec` → a full SSH
round trip. A `loop:` over 20 packages is 20 sequential round trips.

Loops are extremely common in real playbooks (package lists, user lists,
file lists), so with plain-task batching now default-on since `0.9.63`, this
is the largest remaining source of avoidable remote latency.

**Why this is easier than the work already shipped.** Batching N *different*
tasks required the whole `references_register?` data-dependency analysis,
because task B may consume task A's `register:`. Iterations of a *single*
task cannot reference each other's results — Ansible has no such semantic —
so that entire class of analysis does not apply here. The `BatchScript`
protocol, the `interpret_remote_result` path, and the `--no-batching` A/B
verification harness all already exist and are reused unchanged.

**Fix.**

In `execute_looped_task`, before the per-item loop:

1. Bail out to the existing one-at-a-time path (no behavior change) if any of:
   `@batching_enabled` is false; `exec_host != host`;
   `PluginManager.is_local_connection?(exec_host, vars_context)`;
   `task.changed_when` or `task.failed_when` is set (same reasoning as
   `TaskBatcher#retroactive_verdict?` — the script's fail-fast can't see a
   controller-side verdict override); `task.delegate_to` is set.
2. For each item, build its `vars_context` (base + `item`) and evaluate
   `when_passes?`. This is safe to do up front: an item's `when:` depends only
   on `item` and the base context, both known before any remote call. Record
   skips exactly as today (`when_passes?` already prints and counts them).
3. Feed the surviving items through `prepare_batch_step` — one `Step` per
   item — and run them as a single `BatchScript` via `SSHManager.exec_script`,
   exactly as `execute_batch_group` does.
4. Consume the results back in item order through the existing aggregation
   logic (`display_result` / `update_stats` / `results <<` / `any_changed` /
   `any_failed`), so `register:` aggregate shape, notify, and halting
   bookkeeping stay byte-identical.

Prefer factoring the "build steps → run script → parse results" middle out of
`execute_batch_group` into a shared private helper rather than duplicating it;
the two callers differ only in how they produce their step list.

**Watch out for.** `ignore_errors:` is per-*task*, not per-item, so every step
in a loop batch shares one value — the script's fail-fast semantics are
therefore simpler here than in the mixed-task case. A failing item without
`ignore_errors:` must halt the remaining items, matching today's behavior
where `execute_task_once` returns a failed result and `any_failed` is set (note
that today the loop actually *continues* after a failed item; preserve
whichever behavior the existing compat tests assert, and if they don't assert
it, preserve today's continue-after-failure behavior rather than changing it
as a side effect of this work).

**Verify.** Add a compat playbook with a `loop:` of ~10 items against a real
remote host. Run it with and without `--no-batching` and diff per-task output
byte-for-byte plus resulting filesystem state, the same protocol `0.9.63` used.
Then measure round trips via `SSHManager.stats["commands_executed"]` — it
should drop from ~N to ~1 for the looped task.

---

### 2. Plugin pre-upload costs `2N+1` SSH invocations per host, serially

**Where:** `src/crystal_play/plugin_manager.cr:120-232`
(`upload_plugins_to_host`).

**Problem.** Per host: one `ssh mkdir` (`:130`), then **one `ssh cat` per
plugin** to read its remote `.md5` (`:150`), then **one `ssh echo >` per
uploaded plugin** to write the new `.md5` back (`:189` for the rsync path,
`:220` for the scp fallback). Each is a separate `ssh` process spawn.

For a modest playbook using 8 distinct modules across 10 hosts that is roughly
170 `ssh` invocations before a single task executes — all sequential, all
before the user sees any task output. On a high-latency link (the kind
`ROADMAP.md`'s `0.9.63` measurements were taken on) this is seconds of dead
startup time.

**Fix.** Collapse to **three round trips per host**:

1. One `SSHManager.exec_script` that `mkdir -p`s the plugin dir and prints
   every existing `.md5` in one pass, e.g. a loop emitting
   `<plugin> <md5>` lines. Parse that into a `Hash(String, String)` and
   compare locally against the local digests.
2. One `rsync` for everything that needs uploading (see item 3).
3. One `SSHManager.exec_script` that writes all the new `.md5` files.

**Also in this same function:**

- `Digest::MD5.hexdigest(File.read(local_plugin_path))` at `:147`, `:186`,
  and `:219` reads a ~2.3 MB binary fully into memory, and computes the
  **same digest twice** for every uploaded plugin (once to compare, once to
  store). Compute each plugin's digest **once**, into a local
  `Hash(String, String)`, using `Digest::MD5.file(path)` — which streams
  rather than loading the whole file. `bin/plugins/` is 101 MB across 44
  binaries, so the current code can read hundreds of MB per run for no reason.
- `get_local_plugin_path` (`:465`) runs a regex `sub` plus one or two
  `File.exists?` calls on every invocation, and it is invoked repeatedly for
  the same plugin inside these loops. Memoize it in a class-level
  `Hash(String, String)`.

**Verify.** Instrument with `SSHManager.stats["commands_executed"]` before and
after against a real remote host; assert the count drops from `2N+1` to 3 per
host. Confirm the incremental path still works: run twice in a row, second run
must upload nothing. Confirm the scp fallback still works by temporarily
making the rsync check fail.

---

### 3. `rsync_upload_batch` spawns one rsync process per file

**Where:** `src/crystal_play/ssh_manager.cr:299-357`.

**Problem.** The method's own comment says it avoids `--files-from` "to keep
it simple", then loops and spawns a full `rsync` process — and therefore a
separate SSH session — per file (`:325-349`). rsync accepts multiple sources
natively.

**Fix.** One invocation:
`rsync -az --chmod=… -e "ssh …" f1 f2 f3 user@host:remote_dir/`.
Keep the existing all-or-nothing success semantics (the caller falls back to
scp on `false`), which is actually *easier* to express with a single exit code
than with the current `success_count` tally.

**Also:** `Process.run("which", ["rsync"], …)` at `:263` and `:312` spawns a
process on every call. Cache the result in a `@@rsync_available : Bool?` class
variable resolved once per run.

**Verify.** Existing plugin-upload path against a real remote host; confirm all
binaries land with mode `0755` and correct content (compare MD5s remotely).

---

### 4. No parallelism across hosts

**Where:** `src/crystal_play/task_executor/executor.cr:132` (the `@hosts.each`
inside the task loop) and `:149` (`gather_facts_for_all_hosts`).

**Problem.** There is no `--forks` anywhere in the codebase — verified by grep.
Wall-clock time is strictly linear in host count, where real `ansible-playbook`
defaults to 5 forks. For any inventory beyond a handful of hosts this dominates
every other item in this document combined.

**Fix — staged, do not attempt in one commit.**

**Stage A (low risk, do this one first):** parallelize
`gather_facts_for_all_hosts`. Each host's fact gathering is fully independent,
writes only to `@facts[host.name]` and `@results[host.name]` (both pre-seeded
per host in `initialize`, so no concurrent hash resizing), and produces exactly
one line of output per host. Spawn a bounded pool of fibers, collect results
through a `Channel`, and print in deterministic host order after the join so
output stays stable.

**Stage B:** parallelize the per-task host loop behind a new `-f/--forks N`
flag, defaulting to **1** (today's behavior) so this ships dark and can be
opted into. The per-host state is already keyed by host name — `@results`,
`@registered_vars`, `@facts`, `@batch_cache`, `@halted_hosts` — which is most
of the work. The real hazards are:

- **Output interleaving.** Today every path `puts` directly as it goes.
  Buffer each host's output per task and flush in host order at the task
  barrier, or the display becomes unreadable. This is the bulk of the work.
- **`@handler_runner.notify`** and `@handler_runner.handlers.concat`
  (`:1090`) mutate shared state — needs a lock or per-host accumulation
  merged at the barrier.
- **`@task_group` / `@grouped_lists`** are written by `ensure_grouped` from
  inside `run_task_list`, which under Stage B would be reached concurrently.
  Pre-plan all task lists before the parallel section, or guard with a mutex.
- **`run_once:`** reads `@hosts.first` and copies its register — needs the
  first host to have completed the task before the others read it, which a
  naive fan-out breaks.

Given the size, **Stage B should be its own proposal with its own design
review.** Land Stage A, measure it, and stop there for this round.

**Verify (Stage A).** Multi-host inventory against real hosts; assert the
gathered `@facts` per host are identical to the serial run and output ordering
is stable across repeated runs.

---

## Tier 2 — per-task CPU and allocation churn

Microseconds each, but multiplied by tasks × hosts × loop items. These matter
for large playbooks and are cheap and low-risk to fix.

### 5. `JSON.parse(x.to_json)` used as "give me a mutable copy"

**Where:**
- `src/crystal_play/task_executor/executor.cr:741` (`apply_changed_failed_when`)
- `src/crystal_play/task_executor/executor.cr:812` (per loop item)
- `src/crystal_play/task_executor/executor.cr:1168` (`register_result`)
- `src/crystal_play/plugin_manager.cr:340` (`execute_remote_plugin`)

**Problem.** Each site serializes a `JSON::Any` to a string and re-parses it
purely to obtain a mutable `Hash(String, JSON::Any)`. All four then only add
**top-level** keys, so a shallow `.as_h.dup` is equivalent — nothing mutates a
nested value.

**Measured** (release build, `Benchmark.ips`):

| result size | `JSON.parse(r.to_json).as_h` | `r.as_h.dup` | speedup |
|---|---|---|---|
| 8 KB `stdout` | 29.8 µs, 17.2 kB/op | **37 ns, 208 B/op** | **814×** |
| small result | 670 ns, 1.31 kB/op | **37 ns, 208 B/op** | **18×** |

A registered `shell:` task with real output pays this twice (once in
`apply_changed_failed_when`, once in `register_result`); a 50-item loop pays it
50 times, and the cost grows linearly with output size for zero benefit.

**Fix.** Replace with `result.as_h.dup` at all four sites. Note
`plugin_manager.cr:340` also does a redundant re-wrap into `JSON::Any.new` at
`:348` — simplify that whole block while you're in it.

**Highest value-per-line change in this document. Land it first.**

**Verify.** `crystal spec` in full — these sites are covered by existing
register / `changed_when:` / `failed_when:` / loop specs. Add one spec
asserting a registered result with nested structure survives round-trip
unchanged.

---

### 6. `VarSubstitutor` is reconstructed 2–5× per task, per host

**Where:** 14 call sites in `src/crystal_play/task_executor/executor.cr` —
`:285, :347, :417, :550, :613, :744, :749, :866, :894, :974, :986, :1054,
:1066, :1213`.

**Problem.** The constructor (`src/crystal_play/variable_substitutor.cr:18-42`)
copies the entire vars hash into a fresh `Hash(String, JSON::Any)`, adds magic
variables, then builds an `ExpressionEvaluator` (which itself constructs four
sub-objects) and a `CrinjaRenderer`.

**Measured:** **2.65 µs and 9.28 kB per instantiation** (release build, 122
vars — realistic once facts are gathered).

The plain execution path constructs it at minimum twice over the *same*
`vars_context`: once in `when_passes?` (`:417`) and again in
`execute_task_once` (`:613`). With `changed_when:`/`failed_when:` it is four
times (`:744`, `:749`), and `:744`/`:749` build two separate instances over an
identical `eval_context`.

**Fix.** Build once per `(task, host, vars_context)` and pass it down.
Concretely: have `execute_task` construct it after `build_vars_context` and
thread it as a parameter through `when_passes?`, `execute_task_once`,
`resolve_delegate_host`, and `apply_changed_failed_when`. At minimum, collapse
the two adjacent instances at `:744`/`:749` into one — that's a two-line change
with no signature churn, worth doing even if the threading is deferred.

**Verify.** `crystal spec` in full. The substitutor is stateless with respect
to a given vars hash (`set_variable` is the only mutator and is not called from
the executor), so sharing an instance is safe — confirm by grepping for
`set_variable` call sites.

---

### 7. `build_vars_context` is called twice per task in the batch path

**Where:** `src/crystal_play/task_executor/executor.cr:232` (in `execute_task`)
and `:501` (in `execute_batch_group`).

**Problem.** When a task belongs to a batch group, `execute_batch_group` builds
a `vars_context` for every member to prepare its step. Later, as the task-major
loop reaches each member, `execute_task` builds the **identical** context again
at `:232` before calling `try_batched_result`.

**Measured:** `VariableContext.build` plus the facts merge costs **3.48 µs and
18.3 kB per call** (release build, 120 facts, 20 host vars, 10 play vars). So
every batched task pays ~7 µs and ~37 kB where ~3.5 µs and ~18 kB would do.

**Fix.** Store the context alongside the result in `@batch_cache` — widen its
value type to carry both — or add a small per-`(task, host)` memo cleared at
the task boundary. The cache-widening option is cleaner and keeps the existing
"fill the cache, consume it lazily" design intact.

**Verify.** `crystal spec`, plus the `--no-batching` A/B diff from `0.9.63`
to confirm batched and non-batched output stay byte-identical.

---

### 8. Debug output is unconditional in the shipped binary

**Where:**
- `src/crystal_play/variable_substitutor/expression_evaluator.cr:22-57` —
  8 sites, ~3 writes per `{{ }}` expression evaluated
- `src/crystal_play/variable_substitutor/crinja_renderer.cr:18-79` — 20 sites
- `src/crystal_play/variable_substitutor/array_slicer.cr` — 27 sites
- `src/crystal_play/template_action_plugin.cr` — 2 sites
- `src/crystal_play/base_plugin.cr:105` — backtrace on plugin failure
  (**this one is legitimate, keep it**)

**Problem.** These are live in `bin/crystal-ansible`, not dead debug scaffolding.
Verified empirically: a 100-task playbook with two `{{ }}` expressions per task
emitted 200 `=== ExpressionEvaluator.evaluate ===` blocks to stderr. `STDERR` is
unbuffered in Crystal, so each is a write syscall.

`CrinjaRenderer` is the worst of the three: `prepare_crinja_vars` (`:63-80`)
dumps **every variable's value** and calls `.to_s` **twice per variable** to do
it. With facts gathered that's ~120 stringifications plus ~125 syscalls on
every single `{% %}` render.

Beyond speed, this makes the tool's stderr unusable for anyone piping or
logging it, and it leaks variable values — including anything decrypted from
vault — into logs.

**Measured** (release build, commenting out only `expression_evaluator.cr`'s
sites, with stderr redirected to `/dev/null` — a real terminal or file is
slower):

```
substitute() as shipped:   5.34 µs
substitute() without:      1.69 µs      3.2x faster
```

**Fix.** Delete them. `expression_evaluator.cr`'s `STDERR.puts "Path: …"` lines
are pure development scaffolding with no diagnostic value to a user. If any are
genuinely worth keeping, gate them behind the existing `PluginManager.verbose`
flag (promote it to a shared `CrystalPlay.verbose?` if needed) — but default to
deleting rather than gating.

**Verify.** Run any compat playbook and assert stderr is empty on success.
`crystal spec` in full — check first whether any spec asserts on this output.

---

## Tier 3 — smaller, still real

### 9. Every local command spawns three processes instead of two

**Where:** `src/crystal_play/local_executor.cr:38-45`.

Builds the string `"/bin/bash -c '#{command.gsub("'", "'\\''")}'"` and passes it
with `shell: true`, which spawns `sh` → which spawns `bash` → which runs the
command. Use `Process.new("/bin/bash", ["-c", command], …)`: one fewer process
per local command, and it deletes the hand-rolled quote-escaping entirely
rather than merely making it faster.

**Verify.** `crystal spec` plus a compat playbook using `shell:` with embedded
single quotes, backslashes, and `$` — the escaping change is the risk here, not
the spawn change.

### 10. Regex recompiled inside loops

- **`src/crystal_play/task_batcher.cr:126`** — `/\b#{Regex.escape(name)}\b/` is
  constructed inside a nested `seen.any? { … haystacks.any? … }`, giving
  O(tasks × registers) regex compilations during planning. Compile each
  register's pattern **once**, when the name is added to `seen`, and store
  `Hash(String, Regex)` alongside it.
- **`src/crystal_play/inventory_parser.cr:45`** — `name =~ /^#{regex}$/` inside
  a `select` block recompiles per host. Crystal only caches non-interpolated
  regex literals. Hoist to a local before the `select`.

### 11. `VarSubstitutor#substitute` is O(k·n)

**Where:** `src/crystal_play/variable_substitutor.cr:61-74`.

Loops `result.match(pattern)` — which rescans from index 0 each iteration —
then `result.sub(full_match, value)`, allocating a fresh string per placeholder.
A single `gsub` with a block does it in one pass with one allocation.

**Note, and confirm before changing:** because the current loop rescans the
*substituted* result, a variable whose value itself contains `{{` loops forever.
`gsub` fixes that as a side effect. Check whether any existing behavior
intentionally depends on recursive substitution (grep the specs) — if something
does, that's a deliberate feature and this item needs rethinking rather than a
straight `gsub` swap.

### 12. Two O(n²) allocation patterns in `split_by_operator`

**Where:** `src/crystal_play/conditional_evaluator.cr:104` and `:112`.

`condition[i..-1].starts_with?(operator)` allocates a substring on **every
character**, and `current += char` reallocates the accumulator on every
character. `FilterEngine.split_chain`
(`src/crystal_play/variable_substitutor/filter_engine.cr:20-46`) already solves
exactly this problem correctly with `String::Builder` and per-char dispatch —
copy that shape.

---

## Dead code

Three trees are unreachable from `crystal-play.cr` (verified by walking
`require` edges from the entry point):

- **`src/crystal_play.cr`** (289 lines) — a stale duplicate of the CLI:
  pre-batching, pre-vault, no `--forks`, no exit-code handling, and with
  `STDERR.puts "DEBUG: …"` still in its host loop.
- **`src/crystal_play/facts_gatherer/`** (11 files, ~600 lines) — superseded by
  `plugins/facts.cr`. Worth deleting specifically because it still contains the
  34-shell-out implementation that `0.9.61` replaced with syscalls; leaving it
  in the tree invites someone editing the wrong file. (`gatherer.cr:57` shells
  out per fact, and the `date_time_facts.cr` module alone issues 13 separate
  `date` calls.)
- **`src/crystal_play/ssh_config.cr`** (174 lines).

This is a compile-time and maintenance concern, not a runtime one. Delete in a
separate commit from any behavioral change, and check `spec/` for references
first.

---

## Suggested landing order

| # | Item | Risk | Effort | Payoff |
|---|---|---|---|---|
| 5 | `as_h.dup` instead of JSON round-trip | very low | trivial | high |
| 8 | Delete debug stderr | very low | trivial | medium + unblocks piping |
| 2 | Collapse plugin pre-upload round trips | low | small | high (startup) |
| 3 | Single rsync invocation, cache `which` | low | small | medium |
| 9 | Drop the extra shell in `LocalExecutor` | medium (escaping) | small | medium |
| 7 | Stop double-building `vars_context` | low | small | medium |
| 6 | Reuse `VarSubstitutor` per task | low | medium | medium |
| 10-12 | Regex hoisting, `gsub`, `String::Builder` | low | small | small |
| 1 | **Batch loop iterations** | medium | large | **highest remote** |
| 4A | Parallel fact gathering | medium | medium | high multi-host |
| 4B | `--forks` for the task loop | high | large | highest overall |

Items 5 and 8 together are perhaps 30 lines and should be one afternoon.
Item 1 is the one worth doing properly.

---

## Benchmark harness

All numbers above came from `--release` builds via `Benchmark.ips`, run from
the repo root. To reproduce, write a scratch `bench.cr` at the repo root
(so `shard.yml`'s dependencies resolve — building from outside the root fails
on `crinja`), build with `crystal build bench.cr -o /tmp/bench --release`, and
delete it afterwards.

Representative context sizes used, chosen to reflect a real post-facts run:
120 facts, 20 host vars, 10 play vars, an 8 KB `stdout` for the "large result"
case.

```crystal
require "benchmark"
require "./src/crystal_play/variable_substitutor"
require "./src/crystal_play/task_executor/variable_context"

vars = Hash(String, JSON::Any).new
120.times { |i| vars["ansible_fact_#{i}"] = JSON::Any.new("value#{i}") }
vars["greeting"] = JSON::Any.new("hello")
vars["who"] = JSON::Any.new("world")

big = JSON.parse({"changed" => false, "stdout" => "x" * 8000, "rc" => 0}.to_json)

Benchmark.ips do |x|
  x.report("substitutor new + substitute") do
    s = CrystalPlay::VarSubstitutor.new(vars: vars, host_name: "h1")
    s.substitute("{{ greeting }} {{ who }} and {{ greeting }}")
  end
  x.report("substitutor new only") do
    CrystalPlay::VarSubstitutor.new(vars: vars, host_name: "h1")
  end
  x.report("JSON.parse(r.to_json).as_h") { JSON.parse(big.to_json).as_h }
  x.report("r.as_h.dup")                 { big.as_h.dup }
end
```

For the item 8 measurement, take a baseline, then
`sed -i 's/^\( *\)STDERR\.puts/\1# STDERR.puts/'` the target file, rebuild,
re-measure, and **restore the file** before committing anything.

For items 1-4, the meaningful metric is not `Benchmark.ips` but
`SSHManager.stats["commands_executed"]` and wall-clock time against a real
remote host. Per `ROADMAP.md`'s `0.9.63` caveats, a local container does not
exercise the round-trip cost these items target, and the available network path
is high-latency and high-jitter — so report medians across several runs in both
directions, not a single sample.

---

## Verification requirements for every item

1. `crystal spec` fully green (715 specs as of `0.9.64`, modulo the two
   documented MySQL/PostgreSQL exceptions).
2. `ameba` clean on all touched code.
3. The `compat/` harness still at 39/39 (40/40 once `41-task-vars.yml` lands).
4. For any item touching the batch path (1, 7): the `--no-batching` A/B diff
   protocol from `0.9.63` — byte-identical per-task output, both directions,
   fresh-state and idempotency-rerun.
5. A `ROADMAP.md` entry per shipped item with the *measured* before/after,
   following the existing entry style. Do not record an improvement that was
   not measured — including honest "no measurable win" results, as the
   `0.9.63` entry already does.
