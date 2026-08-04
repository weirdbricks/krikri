# Possible Performance Improvements

Crystal Ansible already has full plugin parity with real `ansible-playbook`
(see [ROADMAP.md](ROADMAP.md)) and, in real-SSH benchmarking against fresh
Atlantic.net instances, already runs faster than real Ansible on both a
fresh run and an idempotency rerun (see the `0.9.58` ROADMAP entry for the
full writeup). This file tracks ideas for pushing that further - nothing
here is implemented yet, and nothing here should be implemented without
following the methodology below first.

## Methodology - read this before touching anything

**Benchmark every change 3 times, before and after, and compare all
three runs - not just one.** A single run's timing is noise: SSH/network
jitter, host scheduling, disk cache state, and the cloud provider's own
variance can easily swing a single run by 10-30%, which is larger than
most of the improvements below are expected to yield individually. One
"it got faster" run is not evidence; three consistent runs in the same
direction is.

Concretely, for any change under consideration:

1. Build both the baseline (`main`/before the change) and the candidate
   (the change applied) as separate binaries.
2. Run the same benchmark playbook against **fresh, identical hosts**
   for each - see `compat/README.md` and the `0.9.58`/current ROADMAP
   entries for how this was done (Terraform + Atlantic.net, one
   throwaway instance per configuration, destroyed after). Reusing a
   host between runs invalidates the comparison the same way it did in
   the `apt`/`user` idempotency bugs found earlier - leftover state
   changes what work each run actually has to do.
3. Run **3 times** for baseline, **3 times** for candidate, both a
   fresh-state run and an idempotency rerun each time (matching the
   existing `benchmark.yml` two-run convention). Record wall-clock time
   (`time`), `changed:`/`failed:` counts, and exit status for every run
   - correctness regressions matter at least as much as speed.
4. Compare the *distributions*, not single points. If the 3 baseline
   runs and 3 candidate runs overlap, the change didn't demonstrably
   help (or hurt) - don't claim a win either way.
5. Never optimize and verify in the same run that also changes
   correctness-relevant behavior. If a change touches both performance
   and behavior, land and verify them separately.
6. Document the actual before/after numbers in this file (or in
   ROADMAP.md, matching how every other verified change in this project
   is recorded) - not just "seemed faster."

This project may end up getting help from other models/agents on some of
these - if so, this file (and the methodology above) is the shared
starting point. Anyone picking up an item here should re-read the
methodology section first; "benchmark 3x, compare distributions, verify
correctness didn't regress" applies to every item below equally,
regardless of who implements it.

## Ideas, roughly in order of value-for-risk

### 1. Collapse `facts.cr`'s subprocess forks (best ROI found so far)

`plugins/facts.cr` (the `Gathering Facts` task, which runs on nearly
every play, every host, unconditionally by default) currently shells out
via backticks to roughly **13 separate subprocesses** per run:

- `hostname -f`
- `uname -r`
- `uname -m`
- `dpkg --print-architecture` (falls back to `rpm --eval '%{_arch}'`,
  falls back to `uname -m`)
- `ip -4 route get 1`
- `ip -4 addr show`
- `python3 --version` (falls back to `python --version`)
- `which python3` (falls back to `which python`)
- `id -u`
- `id -g`
- `date +%Z`

It already reads `/proc/meminfo` and `/proc/cpuinfo` directly for some
facts, proving the direct-read approach works fine here - the backtick
calls are the exception, not a hard requirement. Most of the above have a
direct-read or Crystal-stdlib equivalent instead of forking a subprocess:

- `/etc/os-release` for most `uname`/architecture-adjacent facts
- `Process.uid`/`Process.gid` (or Crystal's `System` module) instead of
  `id -u`/`id -g`
- Crystal's own hostname resolution instead of `hostname -f`
- `/proc/net/route` or reading `/sys/class/net/*` instead of shelling to
  `ip` for the default-route/address facts (needs care - `ip`'s output
  format is more stable across kernel versions than hand-parsing
  `/proc/net/route`, so this one may not be worth the parsing-fragility
  tradeoff; verify against several real distros before committing to it)
- Reading `/etc/timezone` or a `TZ`-aware Crystal stdlib call instead of
  `date +%Z`

Since this task runs once per host per playbook regardless of what the
playbook actually does, and executes *before* the SSH-uploaded plugin
binary even starts doing anything user-visible, it's the single highest-
value target of anything found so far: fully general (every playbook,
every host), low-risk (pure internal refactor of one plugin, no
behavior/output changes if done correctly - the resulting `ansible_*`
facts need to come out byte-identical to today's, verified against the
existing `spec/integration/facts_spec.cr`/`compat/` coverage), and
bounded in scope (one file).

**Before implementing:** verify what each of these ~13 forks actually
costs in isolation (some may already be cheap enough that removing them
doesn't move the needle - measure, don't assume all 13 are equally
worth chasing).

### 2. Skip fact-gathering entirely when nothing needs it

A playbook that never references any `ansible_*` fact still pays the
full gathering cost (all 13-ish forks, or however many remain after
item 1) on every host, every run, because `gather_facts:` defaults to
`true` and crystal-ansible currently gathers unconditionally when it's
not explicitly `false`.

Real Ansible's own `gather_facts:`/`gather_subset:` handling is more
nuanced than a blunt skip - a genuinely correct implementation of this
would need to detect fact usage across `{{ }}` substitutions, `when:`
conditions, and templates throughout the whole play (not just the first
task), which is a real static-analysis problem, not a quick change. A
narrower, safer first cut: honor `gather_facts: false` more completely
if it doesn't already (verify current behavior first), and treat this
broader "detect whether facts are actually used" version as a separate,
larger follow-up rather than bundling it with item 1.

### 3. Batch multiple tasks into one SSH round trip

Every task against a remote host currently costs one `ssh` process
invocation (reusing the multiplexed `ControlMaster` connection, so no
new TCP/auth handshake, but still a real fork+exec+protocol round trip
per task - measured at roughly 6-8ms just for the crystal-ansible plugin
binary to start locally; the SSH-invocation overhead on top of that
hasn't been isolated and measured yet and should be before prioritizing
this item).

Real Ansible has its own version of this problem and addresses it
partly via connection plugins and "pipelining" (`ANSIBLE_PIPELINING`),
which changes how modules get transferred/executed rather than batching
multiple *different* tasks into one connection. A crystal-ansible
equivalent - queuing up several sequential tasks bound for the same host
and running them via a single SSH invocation (e.g. a small generated
shell script, or a persistent control connection that accepts multiple
commands) - is a materially bigger and riskier change than items 1-2:

- Handlers, `when:` conditions evaluated against results of *earlier*
  batched tasks, loops, and `register:` all currently assume each task
  fully completes (and its result is available) before the next one is
  even dispatched - batching would need to preserve that ordering and
  data-dependency semantics exactly, not just execute faster.
- Failure handling (`ignore_errors:`, `rescue:`/`always:`, `any_errors_fatal:`)
  mid-batch needs to behave identically to today's one-task-at-a-time
  model - a batched task 3 failing shouldn't silently skip evaluating
  whether task 4 even should have run under today's semantics.
- This is the kind of change that should get its own design pass and
  probably its own compat-harness coverage extension before
  implementation starts, not just a benchmark comparison after the
  fact.

**Recommendation:** don't start this until items 1-2 are done and
measured, and only pick it up with a real design writeup first (separate
from this file) given the correctness surface it touches.

### 4. Plugin binary startup time itself - deprioritized

Measured at roughly 6-8ms per plugin invocation locally (uncompressed,
`--release` build). This is already fast for a per-task cost, and the
only way to meaningfully beat it is some form of persistent
daemon/long-lived process holding plugins in memory instead of spawning
a fresh binary per task - which would trade away the "just a bunch of
standalone binaries, no daemon, no persistent state to reason about"
simplicity that's made this project easy to verify and test throughout
its whole history (every `ameba`/`crystal spec`/compat-harness run in
this project's history has relied on that simplicity). Not recommended
unless items 1-3 turn out to be insufficient and there's a specific,
measured workload that needs it.

**Already tried and rejected, for reference:** UPX compression of the
release binaries. Real compression (main binary 3.3MB -> 924KB, typical
plugin ~830KB -> ~290KB), but decompression happens on *every*
invocation while the size win only ever helps the *first* upload of a
given plugin to a given host (plugin binaries are MD5-cached on the
target after that - see `src/crystal_play/plugin_manager.cr`). Measured
locally: UPX-compressed startup was ~2.3x-4.3x slower per invocation
than uncompressed. Net loss for any playbook that invokes a plugin more
than once, which is nearly all of them. Not worth reconsidering unless
the caching mechanism itself changes.

## Status

Nothing in this file has been implemented yet. Pick an item, re-read the
methodology section above, benchmark the true baseline first (3 runs,
matching the convention above) before writing any code, then implement,
then benchmark the candidate (3 runs) before claiming a win.
