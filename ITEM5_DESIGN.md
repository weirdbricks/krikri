# Item 5 design pass — "ship the play, not the tasks"

Design investigation for `OPUS_PERFORMANCE_IMPROVEMENTS.md` item 5,
written 2026-08-29 against 0.9.635, **before** any implementation.

Item 5's own text describes the target-side executor as "a relocation of
existing code, not new evaluator work", on the grounds that the fat
plugin binary already links `VariableSubstitutor`,
`ConditionalEvaluator`, `FilterEngine` and Crinja. The evaluators are
indeed already there. This pass exists to answer the question that
actually decides the item: **what, concretely, does the controller still
have to do — and how often?**

The short answer is that the boundary is not where item 5 assumes. It is
not a list of a few task-level features (`delegate_to`, `pause:`,
`connection: local`). It cuts *through templating*, and it cuts through
the file-staging that five of the most common modules depend on.

---

## 1. What the run actually needs from the controller

Enumerated from the code, not from the item's summary.

### 1a. Controller filesystem, per task, for the most common modules

`prepare_batch_step` and `execute_task_once` both run this chain before
any dispatch (`executor.cr`):

| method | modules affected | what it touches |
|---|---|---|
| `resolve_role_relative_src` | copy, template, script, unarchive, assemble | role `files/`/`templates/` paths on the controller |
| `inline_copy_source_content` | `copy:` | **reads the source file** and inlines it into params |
| `stage_unarchive_remote_src` | `unarchive:` | reads/stages the local archive |
| `stage_script_src` | `script:` | reads the local script |
| `stage_assemble_dir` | `assemble:` | reads every fragment in a local directory |

Plus `TemplateActionPlugin`, whose own header says *"Runs on CONTROLLER
to read and render Jinja2 templates, then sends rendered content to
remote host"*.

So `copy:`, `template:`, `script:`, `unarchive:` and `assemble:` are all
controller-file-bound today. In a typical config-management role these
are not a minority — os_hardening is largely `template:` and `copy:`.

**This is the single biggest omission in item 5's description.** Moving
the interpreter target-side does not move the role's `files/` and
`templates/` directories with it.

### 1b. Controller environment, *inside* templating

`expression_evaluator.cr` implements `lookup()` for: `first_found`,
`env`, `url`, `file`, `pipe`, `template`, `password`, `varnames`.

Of those, `env`, `file`, `pipe`, `template` and `first_found` read the
**controller's** environment, filesystem and subprocesses. Real Ansible
is unambiguous that lookups are controller-side, so this is required
behaviour, not an implementation accident.

The problem is *where* they sit. A lookup is not a task-level feature
that can be checked before dispatch — it is reached from deep inside
expression evaluation, which happens per parameter, per `when:`, per
`changed_when:`. A target-side interpreter cannot evaluate an arbitrary
expression without potentially needing the controller mid-expression.

`expression_evaluator.cr:145` already notes lookups "must never run
twice", so a naive "try target-side, fall back to controller" retry is
actively unsafe for `lookup('pipe', ...)`.

### 1c. Cross-host state

`hostvars` is built from `@facts` across **all** hosts, with a
generation counter (`@hv_generation`) bumped on every fact/register
write. A target-side executor for host A can reference host B's facts
through `hostvars`. Each agent therefore has either a stale view or a
callback per access.

### 1d. Controller-side task features

The genuinely task-level ones, which item 5 does list: `delegate_to`
(incl. `delegate_to: localhost`), `connection: local`, `fetch`
(`CONTROLLER_ONLY_PLUGINS`), `vars_prompt`, `pause:`, the debugger,
`run_once`, and display/recap.

### 1e. Controller-side bookkeeping

~140 mutation sites across `@results`, `@halted_hosts`, `@facts`,
`@registered_vars`, `@hv_generation`, `@batch_cache`, `CustomStats`,
plus `any_errors_fatal` / `max_fail_percentage` / `serial:`, which are
cross-host decisions no single agent can make.

---

## 2. Why "fall back for that task" does not work here

Item 5 proposes the daemon's existing discipline: try target-side, fall
back to controller-driven for anything the agent cannot handle.

That discipline works for the daemon because a daemon request is
**one task, stateless, and idempotent to retry**. Neither holds here:

1. **The agent is mid-graph.** Falling back for task 40 of 200 means the
   controller must resume with the agent's accumulated state — every
   registered var, set_fact, and handler notification. That state has to
   be transferred and reconciled, which is item 4's `--verify-context`
   problem except unavoidable rather than optional.
2. **Discovery is too late.** A `lookup('pipe', ...)` inside a
   `when:` is discovered *while evaluating*, after the agent has already
   started the task, and re-running it on the controller may re-execute
   the pipe. `expression_evaluator.cr` explicitly forbids that.

So the boundary cannot be discovered at runtime. It has to be decided
**statically, before the graph is shipped**.

---

## 3. Recommended shape: static partitioning, not runtime fallback

Rather than "ship the play and fall back", ship **only provably
self-contained runs**.

Add a planner pass, in the spirit of `TaskBatcher.plan`, that walks the
task list and marks each task *agent-eligible* or *controller-bound*.
Controller-bound if any of:

- module in {copy, template, script, unarchive, assemble, fetch}
  (controller-file-bound), or any module needing `NEEDS_FULL_VARS`
- any parameter, `when:`, `changed_when:`, `failed_when:`, or `vars:`
  expression whose text contains `lookup(` / `query(`
- any reference to `hostvars` or `groups`
- `delegate_to`, `connection:`, `run_once`, `pause:`, `vars_prompt`
- debugger enabled for the run

Consecutive agent-eligible tasks form an **agent run**, shipped and
executed target-side in one round trip. Controller-bound tasks execute
exactly as they do today. This is precisely the `TaskBatcher` model one
level up, and it inherits its safety argument: the analysis is textual,
conservative, and never needs to be undone mid-flight.

The agent returns its accumulated register/set_fact/notify deltas at the
end of each run; the controller merges them before the next
controller-bound task. One merge point per run, not per task.

**Note this composes with item 3 rather than replacing it.** A batched
group is already one round trip; an agent run is many groups in one
round trip.

---

## 4. Honest estimate of the win

Item 5 claims N×RTT → ~1 RTT per play per host. Under static
partitioning the real figure is N×RTT → (number of agent runs)×RTT, and
the run count is set by how often a controller-bound task interrupts.

On `devsec.hardening.os_hardening`, the workload used for items 1–3:
it is template- and copy-heavy, so on the rules above it would partition
into **many** short agent runs, not one. The win there is real but far
from the headline.

Measured context for what is actually left to win: a `/bin/true` task
costs ~69ms through the daemon, of which the payload is 220 bytes
(see item 4's closure). So per-task cost today is round-trip **plus
per-module process work on the target**. Item 5 removes the round trip
but not the process work — so even a perfectly partitioned role does not
approach zero.

**I would not promise better than ~2x warm on a template-heavy role**
before measuring, and it could be materially less. That is a
substantially weaker claim than the item makes, and it is the main
reason this design pass exists.

---

## 5. Cheaper alternatives that should be priced first

Given the above, two smaller items plausibly beat item 5 per unit of
risk:

- **Item 6 (agent outliving the run).** Already independently motivated:
  item 2's measurement showed the daemon's *startup* is what has to be
  amortized, and item 6 removes it. Much smaller blast radius.
- **Controller-side file staging over the daemon.** `copy:`/`template:`
  currently inline content into params on a path that predates the
  daemon. Sending content once per distinct file, keyed by digest,
  instead of per task, is a contained change that attacks the
  template-heavy case item 5 handles worst.

---

## 5b. Measured partitioning (`scripts/agent_partition_report.cr`)

The measurement §6 asks for, now built and run. It parses and classifies
only — no hosts, no execution. Corpus: the 10 roles from the 0.9.635
regression sweep plus os_hardening.

Two modes, because the distinction turned out to decide the answer:

- **strict** — classify as the engine behaves today.
- **movable** — assume `debug`/`assert`/`fail`/`set_fact` move into the
  agent. They touch no controller resource; they evaluate an expression
  against the vars context, and `debug`'s output streams back like any
  other result. They are controller-side today as an implementation
  choice (`ActionPluginManager`), not a constraint. `pause:` is
  genuinely controller-bound — it reads the operator's terminal.

That split matters a lot: **in strict mode the single biggest blocker is
`assert`/`debug` — 76 of 138 tasks.** `robertdebock.functions` is 22
tasks of pure `assert`, which strict mode partitions into *zero* agent
runs. Any real item 5 would have to move the pure action plugins first,
so movable is the honest mode to plan against.

Result over the corpus (138 statically-visible tasks):

| | count |
|---|---|
| agent runs (movable) | 24 |
| controller tasks that still dispatch remotely | 10 |
| **round trips under item 5** | **~34** |

**The critical correction this produced.** My first cut reported "6.6x
fewer round trips" by comparing against 138. That is wrong twice over:

1. A controller-bound `template:`/`copy:` **still dispatches remotely**
   after staging, so it still costs a round trip. Only the pure action
   plugins and includes are free.
2. **The baseline is not one trip per task.** Item 3 already collapses
   consecutive tasks into one trip. Measured on os_hardening: **79 round
   trips for ~95 runtime tasks.** Item 5's marginal value is
   *(today's batched trips) − 34*, not *138 − 34*.

Remaining blockers in movable mode, over the whole corpus: 10
include/import, 4 `template:`, 3 `copy:`, 3 `unarchive:`. Note what is
*absent* — not a single `lookup()`, `hostvars`, `delegate_to` or
`run_once` in this corpus. §1b's concern is real but rare; **§1a's
controller-file problem and dynamic includes are what actually
fragment a role.**

**Caveat, stated because it bounds all of the above.** The parser does
not expand `include_tasks:`/`include_role:` — they are dynamic by
definition. So os_hardening shows 2 statically-visible tasks against
~95 at run time. The per-role absolute numbers are therefore not runtime
task counts; the *shape* is the finding. A role that is mostly includes
is also, on these rules, a role that fragments heavily — each include is
its own boundary — so the direction of that error is against item 5, not
for it.

---

## 6. Recommendation

**Do not start item 5 as specified.** Its "relocation, not new work"
framing holds for the evaluators but not for the run: controller
filesystem access and lookups are woven through templating, and the
runtime-fallback discipline it borrows from the daemon is unsafe
mid-graph.

If item 5 is wanted, the version worth building is the statically
partitioned one in §3 — and it should be preceded by a measurement of
how a real role actually partitions, which is cheap: the planner pass
can be written and run against the existing role corpus with **no
execution at all**, reporting run counts and lengths per role. That
number decides whether the rest is worth building.

Suggested order: measure the partitioning first, then item 6, then
revisit.

**Update after measuring (§5b): the recommendation hardens.** Item 5
buys ~34 round trips against a batched baseline that is already 79 on
os_hardening — call it a ~2x reduction in trips, not the order of
magnitude "N x RTT -> ~1 RTT" implies, and that is before the
per-module process work that item 5 does not remove at all. Meanwhile
the corpus shows the blockers are controller-file access and dynamic
includes, not the exotic cases. That points at the cheaper §5
alternative — sending file content once per digest instead of per task —
as the better next move, with item 6 alongside it.
