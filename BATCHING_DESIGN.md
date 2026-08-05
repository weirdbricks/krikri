# Design: batching multiple tasks into one SSH round trip

Status: **implemented in `0.9.61`, behind `--experimental-batching`
(opt-in, defaults off)**. This is item 3 from
[POSSIBLE_PERFORMANCE_IMPROVEMENTS.md](POSSIBLE_PERFORMANCE_IMPROVEMENTS.md).
See "Implementation notes" near the end of this file for what shipped,
how it was verified, and what's still open.

## Why (measured, not assumed)

A prerequisite measurement (`0.9.60`-era, one throwaway Atlantic.net
instance, destroyed after) isolated what "SSH-invocation overhead" per
task actually consists of:

- 30 trivial `debug:` tasks, `gather_facts: false`, `--release` build,
  `ansible_connection=local`: ~0.12s total (~4ms/task) - local plugin
  startup only, no SSH involved.
- Same 30 tasks over real SSH to a fresh remote host (after plugin
  upload/caching, so measuring steady-state per-task cost): ~10s total
  (~330ms/task marginal).
- A bare `ssh <host> true` issued 30 times over the *same already-open*
  `ControlMaster` connection: median 350ms, mean 364ms - matching the
  full crystal-ansible per-task cost almost exactly.

Conclusion: the per-task remote cost is dominated by the SSH channel-open
round trip for each new `ssh ... exec` invocation, not by local fork/exec
or plugin-binary startup (already known, ~6-8ms, see item 1). That
round-trip cost is proportional to network RTT to the target (the test
path measured ~120ms avg, ±40ms jitter - unusually bad; a typical
same-region VPS deployment will see much less, so the absolute win from
batching is environment-dependent, not a fixed multiplier). Batching K
sequential tasks into one SSH invocation collapses roughly K round trips
into 1, so the win scales with both K (how many tasks are safely
batchable in a row) and the target's RTT.

**Before implementing:** get a real number for K on realistic playbooks.
Static analysis over `compat/playbooks/*.yml` and `testing/*.yml` (which
tasks fail the batchability predicate below and why) is cheap, local-only,
and should be done first - if most real playbooks batch into runs of 2-3
before hitting a boundary, the win is much smaller than the "K=30 trivial
independent tasks" measurement above suggests.

**Done** (local-only, `PlaybookParser` driven directly against every real
fixture, no infra/SSH involved): walked all 71 parseable fixtures across
`testing/*.yml` + `compat/playbooks/*.yml` (2 skipped - vault-encrypted,
need a password), applying the exact predicate below recursively into
`block:`/`rescue:`/`always:`. Results:

- 592 tasks total (top-level + nested block tasks), 185 batchable runs.
- **87.0% of tasks fall inside a run of length >= 2** (i.e. actually
  benefit from batching); only 77 of 592 tasks are stuck at length 1.
- Mean run length **3.2**, max **34** (a single run in
  `38-postgresql-privs.yml` covering 34 consecutive independent grant/
  revoke tasks - correctly cut right before a `copy:` task that
  interpolates 16 different earlier `register:` names into its
  `content:`, confirming the register-dependency check actually fires
  and isn't just theoretical).
- Histogram is a real spread, not one outlier carrying the average:
  length 1: 77 runs, length 2: 38, length 3: 28, length 4: 10, length
  5-10: 19 runs, length 13-34: 6 runs (mostly the DB/docker-plugin
  fixtures, which chain many independent flag-variation tasks in a row -
  exactly the shape that benefits most).

This is a meaningfully better number than the "K=30 independent debug
tasks" synthetic benchmark implied - real fixtures batch well *without*
needing every task to be data-independent from every other task in the
whole file, because the predicate only needs a run's *own* window clear,
and most real task sequences don't chain through their own immediately-
preceding sibling's `register:` result. Combined with the RTT-dependent
per-task cost above, this makes item 3 look like a genuinely worthwhile
follow-up once someone picks up the implementation - the risk is in the
correctness surface (see predicate/protocol below), not in whether
there's enough batchable structure in real playbooks to make it worth
doing.

## Current per-task flow (what batching has to preserve exactly)

Today, `TaskExecutor#execute_task_once` (`task_executor/executor.cr`) does,
per task, per host, synchronously:

1. Substitute `when:` and check it (skip + `@results[host]["skipped"] += 1`
   if false) - `execute_task_once`.
2. Substitute `params:`/`become_user:` against the current `vars_context`
   (which includes every `register:`ed variable from *every previously
   executed task*, this or earlier batches, in this or earlier plays).
3. Run the action plugin if any (`ansible.builtin.template` today - renders
   the template controller-side before the module ever runs).
4. Build `config_json` (`host`, `params`, `vars`, `become`, `become_user`).
5. `PluginManager.execute_plugin` -> for a remote host,
   `execute_remote_plugin` -> one `SSHManager.exec` call: `ssh ... "/bin/bash
   -c 'echo '<json>' | <remote_plugin_path>'"`, blocking until it returns
   `{exit_code, stdout, stderr}`.
6. `apply_changed_failed_when` (needs the result already parsed).
7. `finish_single_task`: merge `ansible_facts`, `register_result` (visible
   to every task after this one), queue `notify:` handlers if `changed`,
   display, update `@results` stats, `halt_if_failed` (sets
   `@halted_hosts`, checked by the outer loop before running *any* further
   task - block, top-level, or otherwise - against that host).

The controller-side bookkeeping in step 7 is what has to survive batching
completely unchanged - notify/register/stats/halt are all pure functions
of "here is one task's parsed JSON result," and batching should only ever
change *how that JSON result is obtained*, never what happens with it
afterward.

## What actually blocks naive batching

Two tasks can only safely go in the same SSH round trip if the *second*
task's `params:`/`when:`/`become_user:` don't need data that only exists
once the *first* task has actually run remotely - i.e., no
`register:`-then-immediately-referenced chain inside the batch window.
Everything else a task can depend on (facts, play/host vars, anything
`register:`ed by a task in an *earlier, already-executed* batch) is fully
known to the controller before the batch is built, so it substitutes
exactly as it does today - only same-batch, forward `register:` references
are the real obstacle, because crystal-ansible does all `{{ }}`
substitution controller-side before a plugin ever runs; there's no
template engine on the remote side to defer that substitution to.

This significantly narrows the actual risk surface: most consecutive
tasks in a real playbook are *not* chained through each other's `register:`
results (that pattern exists - `stat:` then `when: x.stat.exists` - but
it's the exception, not the rule), so a conservative batcher that simply
refuses to cross that specific boundary, and falls back to today's
one-task-at-a-time path for everything it can't prove safe, should still
capture most of the win without touching the harder semantics.

## Batchability predicate

A run of consecutive tasks (within one flat task list - the play's own
top-level list, or one `block:`/`rescue:`/`always:`'s nested list; batches
never cross into or out of a block) can be batched together only if,
for the *whole run*:

- Same `exec_host` (i.e. no `delegate_to:` divergence) and both are the
  non-local connection path (`PluginManager.execute_plugin`'s
  `is_local_connection?` - batching is an SSH-specific optimization; local
  tasks already cost ~4ms and don't need it).
- Not `task.block?`, `.include_tasks?`, `.include_role?` - these are
  structural/dynamic (roles and included files can themselves contain
  anything, including further blocks) and stay on the existing recursive
  `execute_block`/`execute_include_*` path unchanged. A block's *own*
  nested task list is separately eligible for batching internally, once
  it's been loaded.
- No `task.loop_items` / `loop_fileglob` / `loop_template_kind` (looped
  tasks - each iteration already goes through `execute_task_once`
  individually; batching the N *iterations of one task* is a real,
  separate opportunity - no cross-iteration data dependency by default,
  since `item` is the only thing that varies - but it's a distinct
  mechanism from batching N *different* tasks and is out of scope for v1).
- No `task.until_condition` (retries evaluate a condition against a fresh
  result each attempt - controller-side loop by nature, out of scope).
- No `task.async_seconds` (already local-only and spawns a detached
  process; fundamentally incompatible with "run remotely as part of a
  script").
- `run_once:` only for the play's first host (later hosts already skip
  via `copy_run_once_register` before reaching execution at all - no
  interaction with batching).
- No task in the run has a `when:`, `changed_when:`, `failed_when:`, or
  `params:` value that references (via `{{ }}`) a `register:` name that
  was registered by an *earlier task in the same run*. (Referencing a
  `register:` from an earlier, already-batched-and-executed run, or from
  before batching started, is fine - that data already exists controller-
  side by the time this run is being built.) Detected by a static scan:
  walk the run in order, track which `register:` names have been "emitted
  so far," and cut the batch the moment a task's substituted-template scan
  finds a reference to one of them. This is the one check that actually
  needs implementing carefully - a false negative (missing a real
  dependency) is a correctness bug, so the scan should be conservative:
  treat any `{{ ... }}` occurrence of a tracked register name as a hit,
  including inside filters/dotted access, rather than trying to prove a
  particular reference is safe.
- `ansible.builtin.template` (the one plugin with an action-plugin
  component, `ActionPluginManager`) is fine to include *inside* a batch -
  its controller-side render (`execute_action`) still happens at batch-
  build time, before the script is assembled; only the resulting module
  invocation goes in the script, same shape as any other task's step.

A run that fails the predicate at task N simply ends the batch before N;
N (and whatever follows) becomes the start of the next candidate run (or
falls back to today's one-at-a-time execution if nothing after it batches
either). Nothing about this predicate can make execution *less* correct
than today - worst case, every run is length 1 and behavior is identical
to now.

## Wire protocol for a batch

Do **not** try to encode multiple tasks into a single shell one-liner via
`SSHManager.exec`'s existing `/bin/bash -c '<command>'` wrapping - once
you're generating a real multi-step script, write it to a real file and
execute that, the same way plugin binaries are already uploaded once and
reused (`PluginManager.batch_upload_plugins_for_playbook`). Concretely,
per batch:

1. Controller builds each included task's `config_json` exactly as
   `execute_task_once` does today (steps 1-4 above, unchanged) - the only
   thing new is that this happens for N tasks before any of them run,
   instead of interleaved with running them.
2. Controller writes a generated script to a local temp file:

   ```sh
   #!/bin/bash
   set -u
   run_step() {
     # $1=index $2=ignore_errors($3=plugin path with become already applied
     local idx="$1" ignore_errors="$2" plugin="$3"
     "$plugin" > "/tmp/.crystal-play/batch-<id>/$idx.out" 2> "/tmp/.crystal-play/batch-<id>/$idx.err" <<'TASKCFG'
   <task N's config JSON>
   TASKCFG
     echo "$idx $?" >> /tmp/.crystal-play/batch-<id>/rcs
     rc=$(tail -1 /tmp/.crystal-play/batch-<id>/rcs | cut -d' ' -f2)
     if [ "$rc" != "0" ] && [ "$ignore_errors" = "false" ]; then
       exit 0   # halts the script; controller sees fewer completed steps than sent
     fi
   }
   run_step 0 true  /tmp/.crystal-play/plugins/debug
   run_step 1 false /tmp/.crystal-play/plugins/copy
   ...
   ```

   `become:`/`become_user:` differ per line naturally (`sudo -n -u X --
   <plugin>` as the `$3` argument for that step only) - no uniformity
   needed across a batch, unlike an earlier, simpler design that would
   have required one `become:` for the whole batch.

3. One `scp` (or reuse of the existing upload path) puts the script on
   the target; one `SSHManager.exec` runs it (`bash
   /tmp/.crystal-play/batch-<id>/run.sh`); one final `cat` of every
   `$idx.out`/`$idx.err`/`rcs` file (or, better, have the script itself
   emit a **length-prefixed** dump of each file at the end - `wc -c` then
   `cat`, not a text delimiter - so a plugin's own JSON/stderr output can
   never collide with a marker string, however unlikely) pulls all
   results back in the same SSH round trip. Do not rely on marker strings
   like `===TASK_START===` printed into the same stdout stream as plugin
   output - a crashed plugin or an unusual `command:`/`shell:` task's
   stdout could in principle contain anything, including a string that
   collides with your delimiter. Length-prefixing makes that class of bug
   structurally impossible instead of merely unlikely.
4. Controller parses N (or fewer, if the script halted early) results
   back into `JSON::Any`, in order, and feeds each one through the
   **existing, unmodified** `apply_changed_failed_when` ->
   `finish_single_task` pipeline, exactly as if `execute_task_once` had
   returned it directly. Tasks that never got a result (halted mid-batch)
   are **not** displayed as `skipped:` - they get no output at all,
   matching real Ansible's (and this codebase's existing
   `@halted_hosts`) "the rest of the play doesn't run for this host"
   semantics exactly.

This keeps the entire "what happens with a task's result" surface
(register, notify, changed_when/failed_when, stats, halt, display)
completely untouched - only the transport between "N configs ready" and
"N results back" changes. That containment is the main thing keeping this
from being a full rewrite of `TaskExecutor`.

## Explicitly out of scope for v1

- Batching loop iterations of a single task (real opportunity, separate
  mechanism, no data-dependency complexity - good v1.5 candidate once the
  cross-task version is proven).
- Batching across `block:`/`rescue:`/`always:` boundaries, or into/out of
  `include_tasks:`/`include_role:` (dynamic content, can't be planned
  ahead of time).
- `until:`/`retries:`, `async:` (fundamentally sequential/local).
- Any attempt to make the *remote* side template-aware so that
  register-chained tasks could batch too - this would mean shipping a
  second implementation of `VarSubstitutor`/`ConditionalEvaluator` that
  has to stay in lockstep with the real one forever. Not worth it unless
  v1's conservative batching turns out to leave most of the real-world win
  on the table (find out empirically first, per the "measure K on real
  playbooks" note above).

## Rollout / risk containment

- Land behind an opt-in flag (e.g. `--experimental-batching`) defaulting
  off, so default behavior is provably unchanged until this has its own
  track record.
- The batchability predicate (which tasks form a run) should be a pure
  function over `Array(Task)` + the set of already-known variable names,
  spec-testable with zero process/SSH involvement - keep that boundary
  clean so the correctness-critical planning logic doesn't require real
  infrastructure to test.
- Extend `compat/` (real `ansible-playbook` vs. `crystal-ansible`,
  diffed) with cases the predicate is specifically meant to handle
  correctly: a `register:`-chained pair that must NOT batch across itself,
  a batch where a middle task fails without `ignore_errors:` (subsequent
  *and* already-would-have-been-batched tasks must not run, matching
  today's halt semantics), `ignore_errors: true` letting a batch continue
  past a failure, `become:` varying within a batch, and a `notify:` fired
  from a task inside a batch (handler must still fire once, at the normal
  end-of-play point).
- Once implemented, verify with the existing methodology (3x fresh hosts,
  before/after, fresh-run + idempotency-rerun, compare distributions) -
  and specifically on a *low-latency* target in addition to whatever the
  next high-latency test looks like, since the whole point of item 3 is
  that its payoff is RTT-dependent; a same-region-VPS number is the one
  that actually predicts real-world value for most users, not another
  high-latency outlier like the instance this design's own prerequisite
  measurement happened to land on.

## Implementation notes (`0.9.61`)

Shipped behind `--experimental-batching` (default off - `crystal spec`/
`ameba` both confirmed clean with the flag never touched, so default
behavior is unaffected either way):

- `src/crystal_play/task_batcher.cr` - `TaskBatcher.plan`, the pure
  predicate above, productionized from the measurement script almost
  unchanged. **Two conditions were added that the original design/
  measurement missed**, both found by reasoning through the actual
  TaskExecutor integration rather than the predicate in isolation:
  - `run_once:` now ends a run. Without this, a non-first host reaching
    a batch group containing a `run_once:` member would still trigger
    the whole group's remote script - including the `run_once:` step it
    should never run for that host (`execute_task`'s existing
    `copy_run_once_register` early-return only guards the *solo* path).
  - `changed_when:`/`failed_when:` now end a run. These can retroactively
    flip a task's `failed:` verdict using data only available after a
    controller-side Jinja evaluation - the batch script's own script-side
    fail-fast can only see a step's raw exit code and its own JSON
    `"failed":true`/`false`, so it has no way to know changed_when:/
    failed_when: would change that verdict. Left in a batch, a task that
    should have halted the host could let later steps run anyway,
    executing real remote side effects that should never have happened.
  - Re-running the fixture measurement with both fixes applied still
    shows the same overall shape (spot-checked, not re-published as a
    new headline number here - the fixtures barely use `run_once:`/
    `changed_when:`/`failed_when:` on tasks adjacent to long batchable
    runs, so the 87%/3.2-mean figures above are materially unchanged).
- `src/crystal_play/batch_script.cr` - the wire protocol. Diverged from
  this doc's original sketch in one way: input framing also moved to
  base64 (not just output). The original sketch piped each step's config
  over the same SSH invocation's stdin via a length-prefix; base64-
  embedding each step directly in the script text avoids ever needing a
  second data channel sharing that stdin at all, sidestepping a known
  footgun (`bash -s`'s own script-reading can read ahead in blocks, not
  strictly line-by-line, which can corrupt the boundary between "script"
  and "data" if they share one stream). Fail-fast is exit-code-nonzero OR
  a literal `"failed":true` substring grep against the step's own
  captured stdout (verified this matches Crystal's `to_json` compact
  serialization exactly - no space after the colon).
- `TaskExecutor` changes preserve the design's core promise exactly as
  planned: `execute_batch_group` only ever fills a per-host result cache;
  every register:/notify:/changed_when:/failed_when:/display/stats/halt
  decision still happens exactly once, lazily, at the same place in the
  task-major loop it always has (`finish_single_task`, unmodified). This
  is what let the real-host verification below diff clean.
- New `SSHManager.exec_script` (runs a script via `ssh ... bash -s`,
  piped over that single invocation's stdin) alongside the existing
  `exec` (single command via `bash -c`) - kept separate rather than
  overloading `exec`, since the two have genuinely different framing
  concerns.

**Verification done:**
- Unit: `spec/unit/task_batcher_spec.cr` (16 examples - every
  run-ending condition, register-chain splitting including the
  whole-word-not-substring case, ordering) and
  `spec/unit/batch_script_spec.cr` (8 examples - build/parse round trip
  run for real via `bash`, not mocked: halt-on-`failed:true`,
  `ignore_errors: true` continuing, halt-on-nonzero-exit with no JSON at
  all, embedded-newline safety, and confirming the script's own `rm -rf`
  cleanup actually ran).
- Real SSH, one throwaway Atlantic.net instance (destroyed after): a
  5-play verification playbook covering every scenario this doc's own
  rollout section called out - a long independent batch, a
  register-chained pair that must split (`{{ r1.stdout }}` referenced by
  a later task), `become:` varying within a batch (root vs. a real
  unprivileged user, verified via file ownership), `ignore_errors: true`
  continuing a batch past a failure, a `notify:` fired from inside a
  batch (handler ran exactly once), and a hard failure without
  `ignore_errors:` halting everything after it (verified a
  should-never-run file genuinely never got created). Ran the identical
  playbook twice against a freshly-reset host - once with
  `--experimental-batching`, once without - and diffed: **every per-task
  status line matched byte-for-byte**, remote file state (existence,
  ownership, content) was identical between the two runs, confirmed via
  direct SSH `stat`/`ls`, not just the playbook's own self-reported
  output. Also timed both (not a rigorous 3x/fresh-host benchmark, just
  a sanity check alongside the correctness verification): batched run
  ~18% faster on this same noisy high-latency path used for the
  original SSH-overhead measurement.
- Not yet done: the `compat/` harness extension this doc's rollout
  section calls for (the scenarios above were verified by hand against
  one real host, not added as permanent regression coverage), and the
  low-latency-target verification the rollout section specifically asks
  for (this was, again, the same high-RTT vantage point as the original
  measurement - still don't have a real number for what the win looks
  like on a fast link, only the theoretical argument that it should be
  smaller).
