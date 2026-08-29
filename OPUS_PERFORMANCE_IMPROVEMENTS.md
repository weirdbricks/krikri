# OPUS_PERFORMANCE_IMPROVEMENTS.md

Ranked performance work for crystal-ansible, written 2026-08-28 against
0.9.631. Successor to the three deleted perf docs
(`SUGGESTED_PERFORMANCE_IMPROVEMENTS.md`,
`POSSIBLE_PERFORMANCE_IMPROVEMENTS.md`, `OPUS_PERFORMANCE_IMPROVEMENTS.md`,
removed in 4a187fb / 87471ef once their items closed). Item #15 of the deleted docs was the persistent daemon, and it is
**not** finished; its unfinished coverage was items 1-3 below, of which
item 1 has since landed. The stale in-code references to that deleted
file were repointed at this one in 0.9.633.

## What "compatible" means here

The axis that matters is **playbook compatibility**: an unmodified real
Ansible playbook must produce the same observable result - same task
order, same `changed`/`ok`/`skipped` verdicts, same recap, same side
effects on the target. Changing our *own* wire protocol, daemon framing,
transport, or on-target execution model is **not** a compatibility
concern and is never a blocker. Tier 1 below is everything that keeps
playbook semantics byte-identical no matter how radically it rearranges
the plumbing. Tier 2 is the short list of things that genuinely change
what a playbook observes, and each of those needs an opt-in flag.

Do all of Tier 1 before starting Tier 2.

---

## At a glance

Every item is labelled **NOT-BREAKING** (an unmodified real Ansible
playbook behaves identically) or **BREAKING** (some playbook observes a
different result, so it needs an opt-in flag and stays off by default).
Implement every NOT-BREAKING item before starting any BREAKING one.

| # | Item | Compatibility | Est. win |
|---|---|---|---|
| 0 | `--timing-profile` | NOT-BREAKING | **DONE (0.9.632)** - none (enables the rest) |
| 1 | `become:` under the daemon | NOT-BREAKING | **DONE (0.9.633)** - 4.0x on an all-solo `become:` workload, 2.5x on the round trips it moves, 1.13x whole-run warm on os_hardening |
| 2 | `facts` under the daemon | NOT-BREAKING | **DONE (0.9.634)** - 1.5x on a many-PLAY run; no gain from extra hosts (daemons are per host); ~25ms COST on a single-gather run |
| 3 | Batched groups under the daemon | NOT-BREAKING | **DONE (0.9.635)** - 2.57x warm on os_hardening, 4.7x on the groups that moved |
| 4 | Stateful vars context (deltas) | NOT-BREAKING | **CLOSED (0.9.635) - NOT NEEDED**, premise was already false |
| 5 | Ship the play, not the tasks | NOT-BREAKING | **DESIGN PASS SAYS DO NOT BUILD AS SPECIFIED** (ITEM5_DESIGN.md) - measured ~2x fewer trips, not the order of magnitude claimed |
| 6 | Agent outliving the run | NOT-BREAKING* | **6a DONE (0.9.637)** - 1.3-1.4x on small roles; **6b (fact cache) REJECTED** - cannot be made airtight |
| 7 | Stop forking `ssh` per exec | NOT-BREAKING | **CLOSED (0.9.638) - LARGELY SUPERSEDED** by the daemon (items 1-3, 6a); 0-1 forks left per warm run |
| 8 | Controller-side caching/memoization | NOT-BREAKING | unmeasured |
| 9 | Idempotency memoization | **BREAKING** | warm runs stop checking |
| 10 | Out-of-order / parallel within a host | **BREAKING** | main cold-run lever |
| 11 | Coalesce package tasks | **BREAKING** | **DONE (0.9.640)** - in `crystal-ansible-fast` only; N installs -> 1 transaction |
| 12 | Gather only referenced facts | **BREAKING** | **DONE (0.9.639)** - in `crystal-ansible-fast` only; 88ms -> 37ms per gather when nothing optional is referenced |

\* Item 6 is NOT-BREAKING **only** if its cache invalidation is airtight;
stale facts are a correctness bug. If it cannot be made airtight it moves
to the BREAKING tier behind a flag - see the item.

---

## Tier 0: measure first (NOT-BREAKING) — DONE (0.9.632)

**0. `--timing-profile`.** Landed in `src/crystal_play/timing_profile.cr`;
see its own header comment for the grouping rule that keeps nested
buckets from double-counting.
Bucket wall-clock time for a run into: local ssh process spawn, wire
time, remote exec, controller-side templating/evaluation, YAML+role
parse, display. Without this, every item below is an estimate, and at
least one of them (item 12) may turn out to be a rounding error.

Cheap to build, and it is the only way to honestly report before/after
for items 1-7. Emit it as a trailing block after the PLAY RECAP, off by
default.

---

## Tier 1: NOT-BREAKING (do all of these first)

### 1. `become:` bypasses the daemon entirely — DONE (0.9.633)

*NOT-BREAKING. Same tasks, same verdicts; only the process the module runs in changes.*

**Landed as described.** Daemons are keyed on `(host, user, port,
become_user)` and the privileged one is spawned through
`remote_plugin_target`'s own `sudo -n -u <become_user> --` wrapper. The
"watch for" below was real: a key that fails to start 3 consecutive
times is dropped so a host whose sudoers refuses `sudo -n` pays three
wasted spawns rather than one per task. `close_all_daemons`'s flat
1-second exit sleep also had to go — harmless while `become:` held no
daemons, a third of the warm saving once every run holds one. Measured
result is in KNOWN_MISSING.md's item 0-1 entry.

`src/crystal_play/plugin_manager.cr:96-99`:

```crystal
def self.daemon_eligible?(plugin_name : String, become : Bool) : Bool
  return false if become
  !DAEMON_INELIGIBLE_PLUGINS.includes?(simple_plugin_name(plugin_name))
end
```

Nearly every real Galaxy role runs `become: true`. The persistent daemon
is the single biggest measured optimization in the project (3.5x-11.9x
warm in the README's 10-role benchmark), and it is switched off for the
overwhelming majority of tasks in the overwhelming majority of real
playbooks. The published warm numbers were therefore largely produced by
the *fallback* per-task path - which means the headline figure is
probably understating what this architecture can do.

The 0.9.496 commit is explicit that this was a scope cut, not a design
constraint: *"become:'s 'daemon runs as one user' problem is genuinely
unsolved, not attempted here."*

**Fix.** Key the daemon cache on `(host, user, port, become_user)`
instead of `(host, user, port)` - `SSHManager.@@daemon_processes`,
`ssh_manager.cr:289` - and spawn the privileged one as
`sudo -n -u <become_user> -- <remote_binary> --daemon`. The one-shot
path already builds exactly that wrapper in
`PluginManager.remote_plugin_target`; reuse it verbatim for the daemon
spawn command. A play using both `become: true` and unprivileged tasks
then holds two resident daemons per host, which is fine.

**Watch for.** `sudo -n` failing where the one-shot path would have
succeeded (askpass/`-K` flows); a long-lived root process is a bigger
deal than a transient one, so `close_all_daemons` correctness matters
more. The existing rescue-and-fall-through in
`execute_remote_plugin` (`plugin_manager.cr:772-786`) already covers
any daemon failure, so the blast radius of getting this wrong is a
silent perf regression rather than a correctness bug - which is exactly
why item 0 comes first.

**Estimated win.** Large. Potentially converts most tasks in most real
roles from ssh-fork+bash+base64+exec to a pipe write.

### 2. `facts` is daemon-ineligible — DONE (0.9.634)

*NOT-BREAKING. Identical fact payload, different process.*

**Landed, with one estimate corrected.** The "Fix" below was right that
the ineligible-set entry is one line, but the real work was that
`facts` was not in the fat binary at all (no `BasePlugin` class, no
`STDIN.gets_to_end` trailer for the generator to splice), so the body
had to be lifted into `CrystalPlay::FactsGatherer` and given a
hand-written dispatch case via `build.sh`'s new `FAT_EXTRA_MODULES`.

**The "frequently the slowest single step of a warm run" framing was
wrong for a single-play role.** One gather is one round trip out of
dozens; on devsec.hardening.os_hardening it is ~0.2s of a ~16s warm run,
and that run's own +-1s spread cannot resolve the change at all. The win
is real but scales with gathers PER HOST - which means PLAYS, not hosts
and not role length. Measured on a 4-host round: the fact-gathering
phase cost the same before and after in both fork modes, because
`daemon start` went 4 -> 8, one extra daemon per host. Daemons are keyed
per host, so N hosts x 1 gather is N independent single-gather cases
that amortize nothing. 1.5x on a 10-play run; ~25ms cost on a
single-gather run; nothing either way for a single-play run however
many hosts it targets. See KNOWN_MISSING.md's item 2 entry.

**This is the argument for item 6** (an agent outliving the run): the
daemon startup that has to be amortized here is exactly the bootstrap
cost item 6 removes, and it would turn every first-gather-per-host from
break-even into a win.

`DAEMON_INELIGIBLE_PLUGINS = Set{"facts"}` (`plugin_manager.cr:94`), and
`gather_facts_for_host` (`executor.cr:1080`) goes through
`PluginManager.execute_plugin` on the per-task path unconditionally.

Fact gathering is the one task that runs on every host in every play,
and it is frequently the slowest single step of a warm run. It is a
plain module that returns JSON - nothing about it requires a fresh
process. It never runs under `become:`, so it does not even depend on
item 1.

**Fix.** Remove it from the ineligible set and let
`gather_facts_for_host` use the daemon path. Note the payload already
injects `ansible_connection=local` into `wire_vars` for the remote case
(`executor.cr:1088-1094`); that stays as-is.

**Bonus.** Once the daemon serves facts, it can *hold* them (see item 4)
- the controller stops shipping the whole fact dict back to the target
inside every subsequent task's vars context.

### 3. Batched groups and the daemon do not compose — DONE (0.9.635)

*NOT-BREAKING. Our own daemon protocol changes; `TaskBatcher.plan`'s eligibility rules do not.*

**Landed exactly as described, and it was the biggest win so far:**
2.57x warm on devsec.hardening.os_hardening, confirmed in both host
orientations, with the 30 groups that moved costing 0.069s each instead
of 0.321s. `TaskBatcher.plan` needed no change at all, as predicted.

The one thing the item did not anticipate: a daemon runs as ONE user, so
a group whose steps disagree on `become_user` cannot share one request
and still takes the script. On os_hardening that left 14 of 44 groups on
the fallback. Splitting such a group into per-user runs was rejected -
each run is a round trip, so a group needing three of them is no longer
obviously cheaper than the single script it replaces.

This also explains why items 1 and 2 measured smaller than they should
have: 44 of os_hardening's 79 round trips were routing around the daemon
entirely, so every earlier measurement had most of the play on the slow
path.

They are not mutually exclusive per run - they are mutually exclusive
per task. A batched group goes through `BatchScript` /
`SSHManager.exec_script`, a fresh `ssh` + `bash` + base64 per group; the
daemon serves only solo, non-`become:`, non-facts tasks. So every task
takes exactly one of the two optimizations and forfeits the other. This
is why the README benchmark had to run `--persistent-daemon
--no-batching`: batching "routes around that path".

**Fix.** Extend the daemon protocol from one `{"module", "config"}`
request to an optional batch request carrying a *list* of steps, and let
the daemon execute the group in-process with the same fail-fast protocol
`BatchScript` implements script-side today. Protocol change is fine (see
"What compatible means"). `TaskBatcher.plan`'s grouping rules are pure
planning logic and need no change at all - the eligibility rules
(`breaks_run?`) stay exactly as conservative as they are.

This also deletes the bash/base64 layer from the hot path and lets the
batch steps see the daemon's resident vars context (item 4) instead of
re-embedding it per group.

**Estimated win.** Compounds 1-2. Also makes the benchmark honest -
today's published numbers deliberately disable a default-on feature.

### 4. The full vars context is re-serialized and re-sent per task — CLOSED, NOT NEEDED

*Investigated 2026-08-29 against 0.9.635 and closed without implementing:
the premise below is obsolete.*

**This item was written against a stale comment.** It quotes
`plugin_manager.cr`'s claim that the config "embeds the task's whole
vars_context... hundreds of KB". That was true once; it is not true now.
`TaskExecutor#build_plugin_config` prunes the wire vars to three
connection keys (`ansible_connection`, `ansible_host`,
`ansible_ssh_private_key_file`) for every module except `debug`/`assert`
- and those two are in `ActionPluginManager::CONTROLLER_ONLY_MODULES`,
so they never reach a module dispatch at all. In practice NOTHING ships
the full context.

**Measured**, by instrumenting `build_plugin_config` and running a play
that includes `package_facts:` (the exact case the old comment cited as
~570 KB):

| task | config bytes | vars shipped / vars in context |
|---|---|---|
| `package_facts` | 215 | 2 / 62 |
| `command` | 223 | 2 / 63 |
| `file` | 242 | 2 / 65 |
| `command` | 223 | 2 / 65 |

The context grew 62 -> 65 vars across the play and the payload did not
grow. Every task ships ~220 bytes.

Both wire paths were checked, not just the one the item names: the only
other place that serializes `vars` is `gather_facts_for_host`, which
does send the full host vars - but that is the first task of a play,
before facts and registers accumulate, so it is O(1) per play, not
O(tasks).

So "O(tasks x context) -> O(context + tasks)" is already
"O(tasks x 220 bytes)". The win is ~zero, against a real cost: a
stateful daemon plus the `--verify-context` guard this item itself asks
for, to protect a correctness risk it itself flags.

**What the remaining per-task cost actually is.** 40 solo `become:`
tasks running `/bin/true` cost ~69ms each through the daemon (item 1's
benchmark). `/bin/true` is ~1ms and the payload is 220 bytes, so that is
round-trip plus per-module process work on the target - not wire size.
That is item 5's territory, which is now the only remaining Tier 1 lever
of consequence.

---

*Original text follows, kept because the reasoning is sound and only its
starting fact was wrong.*

*NOT-BREAKING. Wire format changes completely; the context the module sees does not.*

`plugin_manager.cr:790-810` documents this directly: the config *"embeds
the task's whole vars_context - ansible_facts, every registered var
accumulated so far in the play, gathered package facts, etc. - and can
grow to hundreds of KB deep into a long-running role."* It is
base64-encoded and pushed over the wire for **every single task**, then
`JSON.parse`d whole on the target. (The daemon path does the same -
`ssh_manager.cr:307`'s `daemon_send` takes `JSON.parse(config)`.) The
one-shot path had to move to `exec_script` precisely because this
overflowed `execve()`'s argument limit on a real role.

Cost today is O(tasks x context). Late-role tasks are the most expensive
ones on the wire, for no reason related to what they do.

**Fix.** Make the daemon stateful. Send the full context once at daemon
start, then per-task deltas only: newly registered vars, `set_fact`
results, gathered facts, loop item. The daemon reconstructs the context
target-side. Requires the controller to know precisely what changed per
task - `executor.cr`'s existing var-store writes are the single choke
point to instrument.

**Watch for.** Any divergence between the controller's model of the
context and the daemon's is a real correctness bug, not just a perf one.
Guard it: a `--verify-context` debug mode that ships the full context
anyway and asserts the daemon's reconstruction hashes identically. Run
it across a benchmark round before trusting the fast path.

**Estimated win.** O(tasks x context) -> O(context + tasks). Grows with
role length; biggest on exactly the long real-world roles that are
slowest today.

### 5. Ship the play, not the tasks (flagship)

*NOT-BREAKING. Same order, same sequential execution, same verdicts - only the interpreter's location moves.*

Items 1-4 make each round trip cheaper. The ceiling they cannot break is
**one round trip per task**. On a 30ms-RTT host a 200-task role spends
6+ seconds doing nothing but waiting for the network, and that number
scales with every host in the inventory.

**Fix.** Send the compiled task graph plus the vars context to a
target-side executor and let it run the whole role locally, streaming
result events back over one connection. The fat plugin binary already
links all of `src/`, so `VariableSubstitutor`, `ConditionalEvaluator`,
`ComparisonEvaluator`, `FilterEngine` and Crinja are all available
target-side already - this is a relocation of existing code, not new
evaluator work.

The controller keeps everything that genuinely cannot move: `delegate_to`
(including the `delegate_to: localhost` local-execution path),
`connection: local` tasks, controller-side lookups, `vars_prompt`,
`pause:`, the debugger, display/recap. The agent calls back to the
controller for those over the same stream, and anything it cannot handle
falls back to controller-driven execution for that task - the same
rescue-and-fall-through discipline the daemon already uses.

Semantics stay identical: same order, same sequential execution, same
verdicts. Only the location of the interpreter changes. That makes this
Tier 1 despite being the largest item here.

**Estimated win.** N x RTT -> ~1 RTT per play, per host. This is the
step that changes the shape of the performance curve rather than its
constant.

**Verification.** Nothing short of a full benchmark round (see
`CLAUDE.md`'s real-host workflow) proves this. Byte-identical recaps
against real ansible-core, cold and warm, on a fresh host pair, for a
meaningful set of real roles - plus explicit `delegate_to` /
`connection: local` / handler / `block:`+`rescue:` coverage, which is
where the fallback boundary lives.

### 6. An agent that outlives the run — SPLIT: 6a DONE (0.9.637), 6b REJECTED

*NOT-BREAKING only if invalidation is airtight; otherwise demote to BREAKING behind a flag.*

**The item's own condition decided it.** Measured directly: with no
boot-id, dpkg or `/etc` signal moving, `ansible_date_time`,
`ansible_memfree_mb` and `ansible_mounts` all change within 2 SECONDS.
A fact cache therefore cannot be made airtight, and per this item's own
escape hatch that half is not shipped on by default. It is not shipped
at all yet - 6b would be an opt-in flag, and is left unbuilt.

**6a - the safe half - landed.** Bootstrap is two round trips before
any real work: one `exec_script` listing remote `.md5` files, and one
fact gather. Item 0's profile over the ten round-197 roles shows that
bootstrap is 4.9% of a 15-second run but **59-74% of a sub-second one**
- it dominates exactly the small roles items 1-3 cannot help, because
they have too few tasks to batch. 6a removes the first round trip by
recording on the CONTROLLER which binaries were verified on which host
(TTL-bounded, keyed on the current local md5).

Deliberately NOT the systemd unit this item describes: that installs a
persistent service on every managed host, which is an operational and
security imposition no amount of speed justifies by default.

**Measured** (2-host pair, warm `robertdebock.cron`, both orientations,
identical recaps): 0.624s -> 0.442s, **1.41x**, 182ms saved; the upload
bucket itself goes 0.102s -> 0.020s. A later re-measurement on a slower
network gave 1.29x - same direction, and the ratio moves with RTT
because what is removed IS a round trip.

**The live testing caught a real regression before it shipped**, which
is the part worth remembering. Deleting `REMOTE_PLUGIN_DIR` behind the
cache's back made the next run lose a task (`ok=4 failed=1`) where the
pre-6a engine completed cleanly - because the recovery path had only
been wired into the one-shot dispatch, not the BATCH path that item 3
now sends most tasks through. Fixed, re-verified (`ok=9 failed=0`), and
pinned. Four failure modes are now exercised live: binaries deleted,
poisoned md5 in the state file, expired TTL, and
`--no-plugin-state-cache`.

With item 5 landed, the next fixed cost is bootstrapping: connect,
upload-check the plugin binaries, gather facts, hydrate context - paid
in full on every run even when the target has not changed since the last
one 5 minutes ago.

**Fix.** A socket-activated systemd unit on the target holding the
plugin binaries, a warm fact cache, and a package-db snapshot across
runs. A warm run becomes connect, send graph, read events.

**Watch for.** Cache invalidation is the entire difficulty and it must
be conservative: reboot (uptime/boot id), dpkg/rpm db mtime+size, `/etc`
mtime, and a hard TTL. Stale facts are a correctness bug, so default to
re-gathering unless every signal says nothing moved. This one is Tier 1
only if the invalidation is airtight - if it cannot be made airtight,
demote it to Tier 2 behind a flag rather than shipping stale facts.

### 7. Stop forking `ssh` per exec — CLOSED, largely superseded

*NOT-BREAKING. Transport only.*

**Closed without building, 0.9.638.** This item is written as "with item
5/6 in place the transport becomes a single long-lived stream" - but the
persistent daemon of items 1-3 already delivers most of that, and item 5
is itself closed.

The daemon holds one long-lived `ssh` process per
`(host, user, port, become_user)`, so nothing daemon-eligible forks per
task any more. What still forks:

- batch groups whose steps disagree on `become_user`, which take the
  script fallback (item 3's documented eligibility rule);
- `scp`/`rsync` file transfers for `copy:`/`template:` staging;
- daemon startup itself, once per key.

**Measured** on the round-198 warm runs, per role: `ssh_script` counts
of **0-1** (e.g. `buluma.samba` 0, `robertdebock.openssh` 1,
`prometheus.prometheus.pushgateway` 1) against 1-4 daemon requests.
Item 6a removed the one that used to be unconditional. So the remaining
prize is tens of milliseconds per run, for a transport rewrite (mTLS or
a bespoke framed protocol) - a bad trade.

**What survives is the throwaway line at the end of the original item**,
which is a config question rather than a rewrite: whether the `--forks`
default (25 here, deliberately unlike real ansible's 5 - see
crystal-play.cr's own comment) and `ControlPersist=600` are right for
multi-play runs. Worth a measurement if anyone wants it; it is not
blocked on anything.

Every `SSHManager.exec` / `exec_script` forks a local `ssh` client
process. ControlMaster amortizes the handshake, but not the fork, the
`bash -c`, or the channel setup. With item 5/6 in place the transport
becomes a single long-lived stream to the agent - bootstrap it over SSH
once, then speak our own framed protocol (mTLS over the existing SSH
channel, or a direct connection where the environment allows it).

Also worth checking as a standalone micro-win: the `--forks` default of
5, and whether `ControlPersist=600` should be longer for multi-play runs.

### 8. Controller-side wins (size them with item 0 first)

*NOT-BREAKING. Pure controller-side caching of work that is already deterministic.*

- Cache the parsed playbook/role graph keyed by a content hash of every
  YAML file that fed it, so repeated runs of a big role tree skip
  YAML + role resolution entirely.
- Memoize template rendering by (template string, fingerprint of the
  vars it actually references). Two independent evaluators re-render the
  same strings repeatedly against deep contexts.
- Buffer stdout instead of writing per line.

All three are plausible and all three are unquantified. The controller
may already be a rounding error next to the network - item 0 answers
this before any of it gets built.

---

## Tier 2: BREAKING (a separate binary, never the default)

Tier 1 is done (items 0-3 and 6a built; 4, 5, 6b and 7 closed on
measurement), so Tier 2 is open.

**Delivered through a separate COMMAND NAME, not per-item flags.** One
build is hardlinked to two names - the same argv[0] trick `build.sh`'s
`build_fat_plugin` already uses for the fat plugin binary - and
`FastMode` reads `PROGRAM_NAME`:

    crystal-ansible        parity. Tier 2 off. The default everywhere.
    crystal-ansible-fast   Tier 2 on, all of it, with a startup banner.

Rationale, recorded because it was a deliberate choice over the
"own flag per item" this section originally called for:

- The separation people want is "this must never happen on a normal
  run". A command name cannot be switched on by a stray flag inherited
  from a wrapper script or a CI variable, and it is visible in `ps` and
  in shell history.
- **All-or-nothing, not one toggle per item.** Four independent toggles
  is sixteen combinations and the benchmark rounds would validate none
  of them; one extra mode is one extra thing to test.
- A hardlink, not a second compilation: one code path, one spec suite,
  no risk of the two drifting while only one gets exercised.

Each item still gets documented in README.md's "How this differs from
real Ansible".

### 9. Idempotency memoization with a cheap invalidation token

**BREAKING** - flag `--assume-unchanged` / `--fast-idempotence`.

Store, target-side, a map from `(module, canonicalized args)` hash to
the last result plus a fingerprint that is far cheaper to compute than
running the module: file stat tuple (mtime, size, inode, mode), dpkg/rpm
db mtime+size, systemd unit state generation. When the fingerprint is
unchanged, skip the module entirely and replay `ok`/unchanged.

Warm runs stop *checking* rather than merely stopping *changing* - the
logical endpoint of the "warm run should be nearly free" line of work.

**Breaks.** Out-of-band drift that the fingerprint does not cover is
missed. A module whose correct verdict depends on state outside its own
args (network reachability, another host, time) can be wrong.
Flag: `--assume-unchanged` / `--fast-idempotence`.

### 10. Out-of-order and parallel execution within a host

**BREAKING** - flag `--speculate`.

Ansible is strictly sequential per host; most tasks in a real role are
independent of each other. Derive a dependency graph from module args
(paths written, packages touched, services, registered vars, handler
notifies) and run independent tasks concurrently on the target.

This is the main lever on **cold** runs - the README's 1.2x-1.9x column,
which is dominated by serialized apt/download waits that both engines
currently pay identically.

**Breaks.** Task order is observable (output order, side-effect
interleaving, anything with an undeclared dependency). Failure semantics
get harder: which tasks "already ran" when one fails mid-flight.
Flag: `--speculate`.

### 11. Coalesce package tasks — DONE (0.9.640)

**BREAKING** - `crystal-ansible-fast` only (the item proposed
`--coalesce-packages`; see the Tier 2 header for why it is a binary
name instead).

**Landed.** `PackageCoalescer.plan` finds runs of consecutive
`apt`/`dnf`/`yum`/`package` installs and merges their name lists into
one transaction at the run's leader. Followers do no work and return
`ok`/unchanged, so the task COUNT is preserved - the recap keeps its
shape and only the `changed` attribution moves, which is the narrowest
form the documented breakage can take.

Eligibility is as conservative as `TaskBatcher.plan`'s, and each rule
maps to a way the merge could change what the play DOES rather than
when: `when:`/loops/`until:`/`async:`/`delegate_to:`/`run_once` (might
not run, or run elsewhere); `register`/`notify:`/`changed_when:`/
`failed_when:`/`ignore_errors` (the verdict is observed, and a follower
reports unchanged); an unrendered `{{ }}` name (not substituted yet);
any state but `present`; any param outside a known shared set; and a
run of one, which is left entirely alone.

Handled on BOTH execution paths - the solo one and item 3's batch one,
since a coalescable task can still be batched. `prepare_batch_step`
already returns `JSON::Any | BatchScript::Step`, so a follower's
synthesized result is expressible there without new plumbing.

Scan the play up front and merge unconditional `apt`/`dnf`/`package`
installs into a single transaction. Each package-manager invocation
carries seconds of fixed cost and roles routinely do 5-15 of them.

**Breaks.** Ordering, per-task `changed` verdicts, conditionals that
depend on an earlier install having happened, handler firing granularity.
Flag: `--coalesce-packages`.

### 12. Gather only the facts the play references — DONE (0.9.639)

**BREAKING** - `crystal-ansible-fast` only (the item originally proposed
a `--minimal-facts` flag; see the Tier 2 header for why it is a binary
name instead).

**Landed.** `FactSubsetPlanner` statically scans the play for the fact
keys each optional family contributes and emits an `all,!family,...`
subset. Measured against the real plugin: **88ms full, 37ms** when all
three optional families are skipped.

The planner is deliberately generous in the safe direction - it keeps a
family on ANY textual sighting, and abandons the optimization entirely
(gathers everything) the moment it sees `hostvars`, `ansible_facts[`, or
a computed `'ansible_' ~ x` name, since no textual scan can resolve
those. A false "used" costs speed; a false "unused" costs correctness.

One trap worth recording: the subset MUST lead with `all`.
`FactsGatherer#subset_enabled?` starts from
`subset.empty? || subset.includes?("all")`, so a bare `!network,!mounts`
reads as an allow-list of nothing and disables even the families the
play does reference. Caught by a play reading `ansible_processor_vcpus`
that came back undefined despite the planner correctly keeping
`hardware`.

Static-scan the play for `ansible_*` references and map them to
`gather_subset` (the facts plugin already accepts it -
`executor.cr:1096-1099`). A typical role reads `ansible_os_family`,
`ansible_distribution`, `ansible_pkg_mgr` and nothing else, while we
probe hardware, network and mounts every time.

**Breaks.** Dynamic access (`vars['ansible_' ~ something]`,
`hostvars`, a fact read by a template file rather than the playbook)
defeats static analysis and yields an undefined fact instead of a value.
Flag: `--minimal-facts`. Note item 6 may make this moot - a cached fact
dict costs nothing to keep complete.

---

## Suggested order

All of Tier 1 (items 0-8) is NOT-BREAKING and lands first. Tier 2
(items 9-12) is BREAKING and is not started until Tier 1 is done.

1. ~~Item 0 (`--timing-profile`)~~ - done, 0.9.632.
2. ~~Items 1 and 2~~ - done, 0.9.633 / 0.9.634.
3. ~~Item 3~~ - done, 0.9.635. ~~Item 4~~ - investigated and closed as
   not needed; the wire payload is already ~220 bytes per task.
4. Items 5, 6b and 7 are all closed without building - see each. Tier 1
   has no remaining lever of consequence; item 8 is a cheap measurement
   that will probably close the same way, and after that only the
   BREAKING Tier 2 items remain.
4. Item 5 - the architectural step.
5. Items 6, 7, 8 - fixed-cost removal, sized by item 0.
6. Tier 2, flag by flag, only then.

Every item lands the same way the rest of this project does: fix, spec
where practical, `VERSION` bump, full `crystal spec`, `./build.sh`, then
a real-host benchmark round proving byte-identical recaps against real
`ansible-core` cold **and** warm before the number is believed.
