# Known Missing / Known Gaps

The goal is 100% behavioral compatibility with `ansible-playbook`,
verified against real runs rather than assumed - not "cover the common
cases." This file tracks what's actually missing **today**. It does
**not** carry implementation history or root-cause narrative for fixed
bugs - that lives in `git log` commit messages; search there (e.g.
`git log --all --grep=auth_socket`) rather than in a second, easily-
stale copy here. When an item below gets fixed, delete its bullet
instead of leaving a "fixed in 0.9.x" note - the commit that fixes it
is the record.

**Currently at `0.9.692`.** Vendored `crinja` fork now at tag
`crystal-play-0.9.21` (see `shard.yml`).

---

## Real gaps (worth revisiting)

### Block-nested handlers (`handlers/main.yml` entries wrapping a `block:`/`rescue:`) not supported - `notify:` on the inner task's name fails "handler not found"

Found via `robertdebock.rsyslog`'s own `handlers/main.yml`, which wraps
its real handler in a block purely to add rescue-time diagnostics:

```yaml
- name: Restart rsyslog block
  block:
    - name: Restart rsyslog
      ansible.builtin.service:
        name: "{{ rsyslog_service }}"
        state: restarted
  rescue:
    - name: Get rsyslog journal logs after service restart failure
      ...
```

Tasks `notify: Restart rsyslog` - the *inner* task's own name, not the
outer block's. Real Ansible flattens block-nested handlers so the inner
name is directly notify-able. This engine's `handler_answers_to?`/
`raise_unless_handler_exists` (`src/krikri/task_executor/executor.cr`)
and `HandlerRunner#run`/`#should_run_handler?`
(`src/krikri/task_executor/handler_runner.cr`) only ever compare
against the flat top-level `handler.name`, never recursing into a
block-type handler's `block_tasks`/`rescue_tasks` - so the run aborts
with `HandlerNotFoundError` ("The requested handler 'Restart rsyslog'
was not found...") even though a real handler of that name exists,
just nested.

Not fixed: merely teaching the existence check to recurse into block
members would stop the false abort, but `HandlerRunner#run` would then
need real support for locating and executing that *specific* nested
task within its parent block's rescue-on-failure semantics - genuine
engine work (not a one-line lookup fix), with real design questions
(e.g. what happens when the SAME nested handler name is notified
alongside a sibling task in the same block - does the block run once or
per-notification?) that need deliberate thought before implementing.
Flat handlers and `listen:`-based handlers are unaffected and work
correctly.

### Ansible's lazy dict-templating (`_AnsibleLazyTemplateDict`) not replicated - a variable built via `.update()` side-effect + concatenation stays a real dict in real Ansible, becomes unusable here

Found round 755/753 (`jtyr.nsswitch`/`jtyr.motd`): both roles define a
config variable via the idiom `some_var: "{{ some_dict.update(other_dict)
}}{{ some_dict }}"` (call `.update()` purely for its mutating side
effect, discard its `None` return, then render the now-merged dict).
Real Ansible's templar preserves `some_var` as a genuine dict-like
object all the way through (confirmed live: its Python `__class__` is
`_AnsibleLazyTemplateDict`, a private ansible-core internal for lazy,
type-preserving templating) - `{% for key, val in some_var | sort %}`
and `{% for key, value in item %}` (iterating a list of such dicts)
both work correctly on the real object. This engine's plain
string-based substitution has no equivalent - the multi-block template
coerces to a string, and a later `{% for key, val in ... %}` over it
fails with "cannot unpack multiple values of type Crinja::Value" (each
sorted/iterated element isn't a real key-value pair). Not fixed -
replicating ansible-core's own private lazy-dict-templating machinery
faithfully would be a major architectural undertaking (deferred
evaluation + type preservation through the whole vars pipeline), not a
one-line filter fix; needs deliberate design work, not chased further
without cost-benefit tracking closer to the actual frequency of this
idiom in real-world roles.

### `template:`/`copy:`'s `validate:` stages in `dest_dir`, not real Ansible's `remote_tmp`

Found round 312 (`bertvv.dhcp`)'s "Install config file" task
(`validate: 'dhcpd -t -cf %s'`): real Ansible stages the rendered file
in its own `remote_tmp` (`~/.ansible/tmp/ansible-tmp-.../`) before
running the validate command against it; `plugins/template.cr` instead
stages next to `dest_dir` (`.krikri-playbook-template-*.tmp`). Usually
invisible, but a validate command confined by AppArmor/SELinux to only
the program's own real config paths (dhcpd's own profile permits
`/etc/dhcp/` but not `/root/.ansible/tmp/`) sees a different outcome
depending on which directory the temp file lands in - real Ansible got
"Permission denied" and failed the whole play; krikri's dest-adjacent
placement happened to be permitted, so it validated and proceeded where
real Ansible couldn't.

Not fixed: switching to `remote_tmp` staging would reintroduce a real,
already-fixed bug (`File.rename`'s cross-device-link failure when
`remote_tmp` and `dest_dir` are different filesystems, found on
konstruktoid-hardening - see `template.cr`'s own comment on
`temp_file`) unless a copy-then-delete fallback is added alongside it,
which is a real design change, not a one-line fix. Needs deliberate work
with full spec coverage across every `validate:`-using plugin
(`template.cr`/`copy.cr`), not a solo benchmark-round patch.

### `RemovedActionError`'s hardcoded message text has drifted from current ansible-core wording

Found round 307 (`Stouts.django`): krikri's message for a removed
`ansible.builtin.include` (`playbook_parser.cr`'s `RemovedActionError`,
"The 'ansible.builtin.include' action plugin has been removed...") was
worded to match whichever ansible-core version confirmed it originally
(2.19.4, per `mrlesmithjr.firewalld`'s round 176 fix); real ansible-core
2.17.14 now says "[DEPRECATED]: ansible.builtin.include has been
removed. Use include_tasks or import_tasks instead...". Same detection,
same `rc=1` both engines - cosmetic text only. Not fixed: the "correct"
wording is a moving target across ansible-core minor versions (this
session alone has hit both 2.17.14 and 2.19.4 on different hosts), so
hardcoding to one specific version's phrasing doesn't durably fix
anything - would need either a version-aware message table or accepting
this as permanently approximate.

### Generic `TASK [Task 1]` label on a nameless task

Surfaced round 300-303 (`cloudalchemy.cortex`, `gantsign.intellij-plugins`): a
task with no `name:` gets a generic `Task 1` label; real Ansible instead
derives one from the action itself (`TASK [debug]`, or `TASK [<role> :
<action>]` inside a role). Cosmetic only - doesn't affect ok/changed/failed
counts or control flow, just console output. Not fixed: `parse_task` doesn't
yet know the resolved module/directive name at the point the fallback name is
assigned, and the real-Ansible convention differs per directive type
(`include_tasks`, `include_role`, a plain module task, a block, ...) - fixing
this needs a wider, per-branch change across `parse_task`/`parse_block_task`/
`parse_include_tasks`/`parse_include_role` etc., each verified against real
Ansible's own convention for that shape, not a single one-line fallback.

(The sibling `PLAY [Play 1]` label and the spurious "Host 'x' has no user
specified" inventory warning from the same round are both fixed: a nameless
play now displays its `hosts:` value, matching real Ansible - see
`parse_play`'s `explicit_name` handling - and the inventory-user-check
warning was removed outright, since real `ansible-playbook` never emits it at
all regardless of connection type.)

### No fact-caching support (`ANSIBLE_CACHE_PLUGIN_CONNECTION` / `fact_caching` config)

Real Ansible skips "Gathering Facts" on a rerun when fact caching is configured
and warm; krikri-playbook has no fact-cache backend at all and always
re-gathers. Surfaced in round 201 (`geerlingguy.raspberry-pi`): with
`ANSIBLE_CACHE_PLUGIN_CONNECTION` set, real Ansible's warm rerun showed
`ok=0` (facts served from cache) where krikri showed `ok=1` (facts
re-gathered) - same failing task otherwise, not a correctness bug in the
failing task itself, just an ok/changed-count mismatch caused by the missing
feature. Not fixed - no fact-cache plugin architecture exists yet to hang a
fix off of.

### bimdata.ferm's `namespace()`-accumulator + nested `lookup('template', ...)` round-trip - root-caused and fixed (0.9.681 + 0.9.682's crinja bump)

Found benchmarking bimdata.ferm (round849): its own `get_vars.j2` builds a
result list with `{% set ns = namespace(items=[]) %}` +
`{% for varname in lookup('varnames', pattern, wantlist=True) %}...{% set _ =
ns.items.append(...) %}{% endfor %}`, then emits `{{ ns.items | to_json }}`,
reached via `defaults/main.yml`'s `_ferm_rules: "{{ lookup('template', ...,
template_vars=dict(...)) | from_json }}"` - a `{{ }}`-valued default that
gets re-rendered on read via `CrinjaRenderer.convert_var`/
`rerender_nested_templates`, which dispatches to Crinja's own native
`lookup` function (`jinja_filters.cr`'s `:lookup`, independent of
`expression_evaluator.cr`'s hand-rolled `lookup_template` per this repo's own
two-evaluator split - see this file's own top-of-repo `CLAUDE.md`).

Three separate bugs, all now fixed, needed to make this real round-trip
work end to end:

1. **`template_vars=dict(...)` and the `#jinja2:` directive-strip were
   missing from `jinja_filters.cr`'s native `:lookup` "template" case**
   (0.9.681) - the identical fix `expression_evaluator.cr`'s
   `lookup_template` already had, ported in.
2. **Crinja's `Resolver#resolve_attribute` crashed with "Invalid Int32:
   ..." on `namespace().items.append(...)`** - its numeric-index fallback
   called the raising `name.to_i` on ANY failed attribute lookup,
   including a genuine method-call name like "append" (not just inside a
   nested lookup - this crashed `namespace()`-accumulation everywhere,
   including a plain top-level `.j2` template render, once actually
   traced down; the original "comes back as literal unrendered text"
   symptom first seen was from a different path - a bare `{{ }}` task
   param, which doesn't dispatch complex block-tag expressions to Crinja
   at all, not a namespace()-specific rendering failure inside nested
   lookups as first suspected).
3. **`Array` had no `crinja_call` at all**, so even once #2 stopped
   crashing, `.append(x)`/`.extend(iterable)` simply weren't implemented -
   Crinja's method dispatch only calls through to `crinja_call` for types
   that implement it.

\#2 and #3 are fixed in the vendored `crinja` fork itself
(`weirdbricks/crinja` tag `crystal-play-0.9.21`, `shard.yml` bumped) -
`src/runtime/resolver.cr`'s rescue-guarded probe and the new
`src/runtime/python_list_methods.cr` (mirroring the existing
`python_hash_methods.cr`'s `Hash#crinja_call` pattern for `Hash#keys`/
`#values`/`#items`/`#get`). See that fork's own `PATCHES.md` for the full
detail. Verified end to end against the exact bimdata.ferm shape -
`namespace()` accumulation through `to_json`/`from_json` via a nested
`lookup('template', ..., template_vars=dict(...))` call now resolves
correctly. See `spec/unit/crinja_renderer_spec.cr`.

### brunobenchimol.certbot_dns (round855) - recap skip-count mismatch, root-caused and fixed (0.9.682)

`rc=0` on both engines, no crash - but real Ansible's recap showed `ok=8
skipped=40` where this engine showed `ok=9 skipped=21`. A side-by-side
TASK-banner diff (not just a recap-count comparison) ruled out two
hypotheses before finding the real one: the role's `meta/main.yml`
dependency on `geerlingguy.certbot` runs exactly once on both engines, and
the later explicit `import_role: name: geerlingguy.certbot` (gated `when:
certbot_create_if_missing`, default `false`) is correctly skipped by both -
neither is a role-params-leaking-across-role-boundaries bug.

**Root cause: `import_role:`'s `when:` was evaluated once against the
IMPORT ITSELF, instead of being combined onto every task the role expands
to.** Real Ansible resolves `import_role:`/`import_tasks:` statically - the
import line produces no task result of its own at all, only its expanded
children do, and its `when:` is combined (parent PREPENDED, matching
`import_tasks:`'s own already-fixed short-circuit ordering - see
`try_parse_import_tasks`'s comment) onto EVERY one of those children. A
`when: false` static import must therefore still show each inner task
individually as `TASK [...]`/`skipping:` under its own real name - real
Ansible's py output here showed the entirety of `geerlingguy.certbot`'s own
task list expanded and skipped this way. This engine's
`run_include_role_once` instead returned early on a false `when:` without
ever loading or expanding the role's tasks at all, undercounting `skipped`
by the whole imported role's task count - not a loop-counting issue as
first suspected; the role's own `with_items:`-driven "Delete Certificates."
task was unaffected on both engines throughout.

Fixed by loading the role's tasks unconditionally for a static import, then
propagating the import's own `when:` onto each (parent prepended, same
short-circuit-safe ordering `import_tasks:` already uses - a child
referencing a `register:` result from an earlier task the parent gate
would have skipped stays safe, verified directly). See
`spec/integration/import_role_when_expansion_spec.cr`.

## The parity-breaking tier was built, measured, and removed (0.9.641)

The perf-tracking Tier 2 - a second binary
(`krikri-playbook-fast`) carrying optimizations that deliberately do not
preserve parity - shipped in 0.9.639/0.9.640 and was deleted in 0.9.641.
Recorded here so it is not re-proposed without the numbers.

**Measured on ten real roles, fresh host pair each, parity binary
against the fast one: 1.00x cold, 1.03x warm.** Inside run-to-run
variance, and the sign flipped per role.

Per optimization:

- **Package coalescing (item 11) never fired once** in ten roles. Real
  roles put `when:`, `notify:`, `register:`, loops or templated names on
  essentially every package task, and the eligibility rules correctly
  exclude all of those. Sound mechanism, no population.
- **Fact subsetting (item 12)** engaged on 7 of 10, saving the ~50ms it
  was measured at - invisible against multi-second runs.
- **Package memoization (item 9)** was scoped, built, and measured
  against seven roles chosen for having the MOST package tasks in the
  corpus. Exactly one memoized anything (4 tasks, ~100ms of an 11s run).
  The dominant real shape is one `apt:` task with a package list and
  `update_cache: yes`, which has to be disqualified because a replay
  would skip the cache refresh.

Against that, the tier produced a **silent wrong answer**:
`dev-sec.os-hardening` ran `ok=24` where the parity binary ran `ok=25`,
on two separate fresh host pairs, because the role's only hardware-fact
reference is inside `templates/etc/initramfs-tools/modules.j2` and the
planner scanned task params only. It took two rounds and two attempted
fixes to run down.

The lesson worth keeping is WHY all three under-delivered: each was
designed against a picture of the engine from before items 1-3. Once
the daemon removed the per-task process-spawn cost, the work they
optimize stopped being where the time goes. Measured per-module check
cost on a converged system, net of that spawn floor: `file` and
`lineinfile` ~0ms, `copy` ~1ms, `service` ~7ms, `systemd` ~16ms, `apt`
~23ms, `package` ~32ms, `get_url` ~229ms - and a 30-task warm run
profiles at 98.9% "task execution" with templating and display at 0.3%
each. Remaining warm-run cost is wire round trips, not module work or
controller work. That points at batching coverage, not at anything
Tier 2 did.


## Round 198 (10-role round validating item 6a, 0.9.637 -> 0.9.638)

10 roles drawn at random from the verified-clean list, excluding both
previous rounds' picks. Fresh 2-host pair per role, real
`ansible-playbook` 2.19.4 on one host and crystal on the other, cold and
warm.

**Accuracy: 18 of 20 comparisons byte-identical.** Both mismatches are
the same role and neither is item 6a's doing.

**Fixed 0.9.638 - the `vars` magic variable was missing from
`when:`/`assert:`.** `prometheus.prometheus`'s preflight does
`__common_parent_role_short_name ~ '_skip_install' not in vars`;
crystal failed it with "'vars' is undefined" at task 6 where python
completed all 33. The Crinja path already synthesised a `vars` dict -
the hand-rolled `ConditionalEvaluator` did not. See that commit; note
the two nesting traps the differential testing caught (the snapshot must
exclude itself, on BOTH evaluator paths, because contexts layer on
cached base contexts).

### Benchmark numbers (python vs crystal, seconds)

| role | py cold | cr cold | py warm | cr warm | warm |
|---|---|---|---|---|---|
| robertdebock.openssh (61 tasks) | 13.54 | **9.10** | 9.78 | **0.58** | 16.9x |
| buluma.handbrake | 67.91 | **40.17** | 29.56 | **1.77** | 16.7x |
| buluma.apt_repository | 4.39 | 8.51 | 2.59 | **0.29** | 8.9x |
| buluma.cni | 26.08 | **11.92** | 20.95 | **3.28** | 6.4x |
| robertdebock.mitogen | 7.96 | 8.53 | 5.71 | **0.98** | 5.8x |
| andrewrothstein.supervisord | 8.60 | 10.87 | 5.35 | **1.44** | 3.7x |
| buluma.samba | 10.30 | **9.84** | 5.62 | **1.52** | 3.7x |
| andrewrothstein.dnsmasq | 7.15 | 7.59 | 4.60 | **1.25** | 3.7x |
| robertdebock.enpass | 13.12 | **10.91** | 4.49 | **1.28** | 3.5x |

Mean **cold 1.41x, warm 10.36x** (median warm 6.11x). Totals 293.1s
python vs 139.2s crystal. Cold is up from round 197's 1.04x, consistent
with 6a removing a fixed cost - though the role set differs, so that is
not a controlled comparison and should not be quoted as one.

### What actually validated item 6a

Not the random roles. Across rounds 197 and 198 - 20 roles, 40
comparisons - **every bug found was pre-existing and unrelated to the
performance work** (`copy: force`, Jinja's `is in` test, `vars`). Zero
were caused by items 0-6a. Useful signal, but it means random sampling
is not what tests 6a.

What tested 6a was targeted adversarial work, and it earned its keep:
deleting `REMOTE_PLUGIN_DIR` behind the cache's back exposed a REAL
regression before it shipped - the recovery path had only been wired
into the one-shot dispatch, not the batch path that item 3 sends most
tasks through. Four failure modes are now exercised live (binaries
deleted, poisoned md5, expired TTL, `--no-plugin-state-cache`), plus:

**The IP-reuse hazard, now deterministic.** 6a keys its record on
`user@host:port`, so the dangerous case is a DIFFERENT machine at the
same address. Neither round produced a recycled IP from Atlantic.net
across 20 hosts, so that case had only been covered by construction.
`testing/ipreuse/` now reproduces it in seconds with containers on a
reused forwarded port: four consecutive impostor swaps all clean, plus a
12-task batching play (`ok=13 changed=12 failed=0`) - the batch variant
being the one a naive test would have missed.


## Round 197 (10-role python-vs-crystal round, fresh pair per role, 0.9.636)

Run to test whether item 3's 2.57x generalises beyond os_hardening.
10 roles drawn at random from the verified-clean list (excluding the
0.9.635 round's picks), a FRESH 2-host pair per role, real
`ansible-playbook` 2.19.4 on one host and crystal on the other, cold and
warm.

**Accuracy: 18 of 20 comparisons byte-identical.** Both mismatches are
the same role, `linux-system-roles.timesync`, where crystal exits 4 on
the role's own `library/` modules (`sr_fingerprint`,
`timesync_provider`) - the documented custom-module scope cut, and rc=4
is the correct behaviour for an unavailable module. Its ROLES_TESTED
entry (✅, round 158, Rocky 9.6) is now stale for Ubuntu, where the
role takes a branch that reaches those modules.

**Fixed 0.9.636 - `copy:` with `content:` + `force: false` overwrote an
existing file.** Real data loss, not a verdict difference. See that
commit; found on `mrlesmithjr.mdadm`, whose "Ensure mdadm conf file
exists" task is exactly that shape against the distro's own
`/etc/mdadm/mdadm.conf`. Python left 688 bytes; crystal left 0. The only
visible symptom in the recap was `changed=1` vs `changed=0`, which is
the argument for checking real on-host state in these rounds rather than
trusting recaps. Re-verified live post-fix: recap matches and the file
is 688 bytes on both hosts.

**One claimed divergence retracted before it was written up.**
`robertdebock.ara` initially showed python rc=1 (no recap) vs crystal
rc=2, and the hypothesis was that crystal fails to resolve a
ROLE-INTERNAL `import_role` at parse time. Tested directly with a
purpose-built nested role: both engines exit 1 and neither runs the
preceding task. The real cause was mundane - `robertdebock.service` was
not installed, a harness gap, not an engine difference. With the
dependency installed both engines produce identical results.

### Benchmark numbers (python vs crystal, seconds)

| role | py cold | cr cold | py warm | cr warm |
|---|---|---|---|---|
| robertdebock.mysql | 8.28 | 7.76 | 5.26 | **1.40** |
| geerlingguy.exim | 7.36 | 10.04 | 5.09 | **1.47** |
| mrlesmithjr.mdadm | 8.30 | 9.95 | 6.88 | **1.03** |
| mrlesmithjr.guacamole | 35.08 | **27.45** | 27.74 | **15.06** |
| robertdebock.ara | 5.35 | 7.58 | 3.70 | **0.44** |
| andrewrothstein.devpiserver | 8.59 | 10.80 | 4.99 | **1.45** |
| robertdebock.cron | 10.72 | **6.56** | 6.59 | **0.51** |
| linux-system-roles.timesync | 32.22 | **19.63** | 23.13 | **2.67** |
| andrewrothstein.bash-dcb | 6.07 | 8.15 | 3.23 | **0.44** |
| robertdebock.node_red | 8.09 | 8.80 | 4.77 | **0.46** |

Mean speedup: **cold 1.04x, warm 6.69x**. Totals 221.4s python vs
141.7s crystal.

**Cold is at parity, and crystal is SLOWER on 6 of the 10 roles cold**
(0.71x-0.92x). That is worth stating plainly rather than quoting only
the warm figure: a cold run is dominated by apt/network work both
engines pay identically, and crystal's per-run plugin upload is real
overhead that python does not have.

### What this says about item 3's 2.57x - it does NOT generalise

The `--timing-profile` transport split was captured per role. Warm
`daemon_batch` counts across all ten: 0,0,0,0,0,1,1,1,1,2. os_hardening
had **30**.

The reason is size, not batch-hostility: these roles have 1-25 tasks,
os_hardening has ~95. Item 3 only pays where there are many consecutive
batchable tasks to collapse, and a small role has none. So the 2.57x is
a property of LARGE roles, and the warm speedups above come mostly from
crystal's startup and per-task cost, not from item 3.

**Conclusion: do not publish 2.57x as a general figure.** It is
accurate for os_hardening and roles of that size. The defensible
general claim from this round is the python-vs-crystal one: ~6.7x mean
warm, ~1.0x cold.


## Performance item 3 (0.9.635)

**Batched groups and the daemon now compose.** NOT-BREAKING: only this
engine's own daemon protocol changed. `TaskBatcher.plan`'s grouping and
eligibility rules are untouched, and every measured pair produced an
identical `PLAY RECAP`.

They were never mutually exclusive per RUN - they were mutually
exclusive per TASK. A batched group went out as a fresh `ssh` + `bash`
+ base64 script; the daemon served only solo tasks. So every task took
exactly one of the two optimizations and forfeited the other, and the
published warm benchmark had to disable batching (`--no-batching`) to
measure the daemon at all.

The daemon protocol now accepts an optional `{"batch": [...]}` request
carrying a LIST of steps, executes them in-process in order, and replies
once. The fail-fast rule is deliberately the same one `BatchScript`
implements script-side - a step whose result is `"failed": true` stops
the batch unless it set `ignore_errors` - and a step that never ran is
ABSENT from the reply, exactly as an absent index means "never ran" in
`BatchScript.parse`. Which transport ran a group is therefore not
observable in any result.

**Eligibility is one rule:** a daemon is one resident process running as
ONE user, so every step in a request must agree on `become_user`. A
group mixing privileged and unprivileged tasks stays on the script,
which resolves privilege per step via its own `sudo -n -u ... --`
prefix. Deliberately not "split the group into runs and send several
requests" - each request is a round trip, and a group needing three of
them is no longer obviously cheaper than the one script the fallback
already sends.

Measured on a fresh 2-host Atlantic.net `G3.2GB` Ubuntu 22.04 pair, one
binary per host, runs issued simultaneously, plus a full swapped-host
control:

| devsec.hardening.os_hardening | before | after | |
|---|---|---|---|
| warm, wall clock (4 runs, both orientations) | 18.02s | 7.00s | **2.57x** |
| ...orientation A only | 18.24s | 6.96s | 2.62x |
| ...orientation B only (swapped) | 17.79s | 7.04s | 2.53x |
| cold, wall clock | 40.93s | 29.52s | 1.39x |
| the 30 groups that moved to the daemon | 0.321s each | 0.069s each | **4.7x** |

The transport rows show what happened: 44 `ssh exec_script` calls
totalling 14.1s became 14 calls totalling 2.0s plus 30 daemon batch
requests totalling 2.1s. The 14 that remain are the mixed-`become_user`
groups taking the documented script fallback. Both orientations agree
to within 0.1x, so this is the engine and not the host pair.

This is the largest single win of the performance work so far, and it
is also why items 1 and 2 read smaller than they should have: on this
role 44 of 79 round trips were routing around the daemon entirely, so
every earlier measurement was taken with most of the play on the slow
path.

**One risk accepted, and it is the same one the solo path already
carries.** On any daemon failure the whole group is re-sent as a script.
A request whose response was lost may already have run, so this widens
the existing re-execution window (see `PluginManager#
execute_remote_plugin`'s own rescue) from one task to one group. The
alternative is worse: leaving those members with no cache entry, which
`execute_batch_group`'s contract reads as "skipped", silently NOT
running tasks the playbook asked for. A wrongly-repeated idempotent
module beats a silently dropped one.


## Performance item 2 (0.9.634)

**`facts` under the persistent daemon.** NOT-BREAKING; the fact payload
is unchanged and every measured pair produced an identical `PLAY RECAP`.

`facts` was the last module held off the daemon path. The one-line part
was dropping it from `DAEMON_INELIGIBLE_PLUGINS`; the actual work was
the reason it was excluded, which was never fact-gathering semantics but
SHAPE: `plugins/facts.cr` had no `*Plugin < BasePlugin` class and no
`input = STDIN.gets_to_end` trailer, which is what `build.sh`'s
fat-binary generator keys on, so `facts` was not in the fat binary at
all and a daemon request for it would only have hit the generated
dispatcher's "unknown plugin" fallback.

The gathering body is now `Krikri::FactsGatherer`
(`src/krikri/plugin_helpers/facts_gatherer.cr`), lifted out
VERBATIM - the only change is being wrapped in a module, which matters
once it is linked alongside 80+ other plugins, since it defines
top-level `capture`/`gather_*` helpers. Its two C bindings stay at top
level deliberately: nesting `lib LibC` makes it a new lib rather than a
re-opening of the stdlib's and loses `GidT`. `build.sh` grew a
`FAT_EXTRA_MODULES` list for modules that belong in the fat binary but
need a hand-written require + dispatch case instead of the generic
source-splicing loop; `facts` is its only member. `plugins/facts.cr`
remains as a thin standalone driver calling the same
`FactsGatherer.run`, so there is exactly one implementation.

It was deliberately NOT reshaped into a `BasePlugin` subclass, which
would have needed no generator change at all: `run_and_capture` returns
a `PluginResult`, whose `to_json` round-trips every extra field through
`JSON.parse(value.to_json)` - a serialize-then-reparse of the entire
fact dict, on the exact hot path this item exists to make cheaper - and
would have added an always-empty `msg` to a payload that never had one.

Measured on a fresh 2-host Atlantic.net `G3.2GB` Ubuntu 22.04 pair, one
binary per host, runs issued simultaneously:

| workload | before | after | |
|---|---|---|---|
| 10 plays x 1 gather, wall clock | 3.03 / 3.05s | 1.89 / 2.11s | **1.52x** |
| ...the fact-gathering phase alone (10 gathers) | 2.87s | 1.69s | **1.70x** |
| 1 play x 1 gather, wall clock (mean of 4) | 0.468s | 0.492s | **0.025s SLOWER** |
| devsec.hardening.os_hardening warm (1 gather of 79 round trips) | 15.65 / 17.05s | 16.55 / 16.22s | cannot resolve |

**The win is per-gather-PER-HOST, i.e. it scales with PLAYS only - not
with hosts, and not with role length.** This was measured directly on a
second 8-host round (4 targets per engine, os_hardening, warm, both
`--forks 25` and `--forks 1`, plus a swapped-host control):

| 4 hosts x 1 play, fact-gathering phase (4 gathers) | before | after |
|---|---|---|
| parallel (`--forks 25`), both orientations | 0.777 / 0.766s | 0.841 / 0.754s |
| serial (`--forks 1`), both orientations | 0.877 / 0.961s | 0.882 / 0.900s |

No win at all - the gathers cost the same either way, in both fork modes
and in both host-set orientations. The reason is visible one line down
in the same profile: `daemon start` went from **4 to 8**, exactly one
extra per host. Daemons are keyed per host, so N hosts x 1 gather is N
independent single-gather cases, each spawning its own daemon for its
own single request and amortizing nothing. Only repeated gathers against
the SAME host amortize, and that means multiple plays.

So: the first gather on a given host is roughly break-even because it
absorbs that host's daemon startup inside its own round trip (0.284s ->
0.255s on the 1-play case); every LATER gather on that same host is
pure profit at ~0.13s, which is entirely what produces the 10-play
2.87s -> 1.69s figure. A single-play run gains nothing however many
hosts it targets, and a single-play single-host run pays ~25ms.
Accepted rather than gated on a play count, which would mean threading a
"will this host gather again?" prediction through the executor for 25
milliseconds.

The whole-run wall clock on the 4-host round is NOT reported as a
before/after ratio, deliberately: the two host sets differed by ~0.9s on
an ~18s run and the environment drifted faster between the first and
second measurement blocks than the effect being measured (identical
`--forks 1` runs came in at 65s early and 59s later). Orientation
swapping cancels the host-set bias but not the drift, since orientation
and time were confounded in this round. The fact-gathering bucket is the
direct measure and it is unambiguous. Every one of the 8 runs produced
an identical per-host recap (`ok=95 changed=0 failed=0 skipped=52`).

That 25ms is what is left after `close_all_daemons`'s exit poll went
from a flat 20ms interval to a 1ms-doubling backoff (same 1s hard
deadline) - a daemon was reliably burning two whole 20ms ticks. Before
that fix the single-gather cost was 0.103s and went the same direction
in 4 of 4 runs; after it, 0.025s and 3 of 4. Worth recording how that
was nearly missed: the profile's own "unaccounted" row only moved
0.041s -> 0.032s, which looked like the fix had barely worked, and the
wall-clock means were what actually showed it removing three quarters of
the regression. Read the number the user feels, not the nearest bucket.



## Performance items 0-1 (0.9.632 -> 0.9.633)

First two items of the new performance plan, both NOT-BREAKING (an
unmodified real Ansible playbook observes the identical result). One
real engine bug found on the way, fixed and re-verified live.

**Item 0 - `--timing-profile` (0.9.632).** Every other item in the plan
was an estimate until a run's wall clock could be attributed to
something. New `src/krikri/timing_profile.cr` buckets a run into
playbook/inventory parse, plugin upload, task execution and fact
gathering; ssh exec / exec_script / local ssh process spawn / daemon
request / daemon start / scp / rsync / local plugin exec; and
controller-side templating, conditionals, crinja and result display.
Off by default and a bare `yield` when off. Overlapping buckets declare
a group so nesting never double-counts, and the guard is per-fiber so
`--forks > 1` concurrency is not mistaken for re-entrancy.

**Item 1 - `become:` under the persistent daemon (0.9.633).** Every
`become: true` task was daemon-ineligible, which is nearly every task
in nearly every real Galaxy role - the project's single biggest
measured optimization was switched off for the overwhelming majority of
real work, and the published warm speedups were largely produced by the
per-task FALLBACK path. Daemons are now keyed on `(host, user, port,
become_user)` and a privileged one is spawned through the same `sudo -n
-u <become_user> --` wrapper the one-shot path already builds, so a
host where one-shot become works has a working daemon, and one where it
doesn't fails the same way and falls back. A key that fails to start 3
times in a row stops being attempted, so a host whose sudoers refuses
`sudo -n` pays three wasted ssh spawns rather than one per task.

Measured on a fresh 2-host Atlantic.net `G3.2GB` Ubuntu 22.04 pair, one
binary per host (before = the commit immediately preceding, with the
`is in` fix below backported so both sides run the identical task set),
runs issued simultaneously so both see the same network. Every pair
below produced an identical `PLAY RECAP`, which is the point - item 1
changes no verdicts:

| workload | before | after | |
|---|---|---|---|
| 40 solo `become:` tasks, task-execution phase | 11.00s mean of 3 | 2.77s mean of 3 | **4.0x** |
| devsec.hardening.os_hardening warm, wall clock | 19.70 / 20.33s | 17.55 / 17.88s | **1.13x** |
| ...the 34 of its 79 round trips that moved to the daemon | 4.02s (0.118s/task) | 1.61s (0.047s/task) | **2.5x** |
| devsec.hardening.os_hardening cold, wall clock | 30.15s | 29.41s | 1.03x |

The whole-run figure is bounded by how many of a role's round trips are
solo rather than batched: os_hardening batches 45 of its 79, and a
batched group still takes the `ssh`+`bash`+base64 path (that is item 3,
which makes batching and the daemon compose). The synthetic case, where
every task is solo, is what item 1 is worth when nothing routes around
it. Cold barely moves because a cold run is dominated by real apt and
package work rather than transport. A swapped-host control (before
binary on the after host and vice versa) reproduced the same direction,
ruling out per-VM speed bias.

`SSHManager.close_all_daemons` also stopped sleeping a flat second on
the way out. That was a rounding error while `become:` tasks held no
daemons; with item 1 essentially every real run holds one, and the flat
second was eating a third of the warm saving - visible as an
exactly-1.001s "unaccounted" row in item 0's own profile, which is what
made it obvious. It now polls at 20ms to the same 1s ceiling.

**Fixed 0.9.633 - Jinja2's `in` TEST spelling was unsupported.**
`x is in y` / `x is not in y` (Jinja 2.10+) is the containment operator
spelled as a test. `ConditionalEvaluator`'s `not in` OPERATOR handler
ran first and split `item is not in os_always_ignore_users` on
" not in ", handing the containment check a left operand of `item is` -
so every looped item failed with "Error while evaluating conditional:
'item is' is undefined" instead of skipping or running. Found live
benchmarking devsec.hardening.os_hardening (its `user_accounts.yml`
gates every interactive-user task this way); verified against real
ansible-core 2.19.4 before fixing. Live re-verify: `ok=95 changed=0
failed=0 skipped=52`, rc=0, idempotent.


## Round 191 (60-role marathon, fresh G3.2GB pair per role, cold+warm both engines, 0.9.625 → 0.9.627)

Two real bugs found and fixed, one open bug documented, one module gap
recorded; 60 roles run (10 of the original 60 picks were dead upstream on
Galaxy - GitHub tag 404s - and were replaced in-round; every role ran on
its own freshly-provisioned server pair, each engine run twice).

**Fixed 0.9.626 - `ansible_userspace_bits` fact missing.**
`plugins/facts.cr` never set it (`ansible_userspace_architecture` was
there, its sibling wasn't). `gantsign.ansible-role-golang`'s first task
chain is `include_vars:
vars/architecture/{{ ansible_facts.architecture }}-{{ ansible_facts.
userspace_bits }}.yml`, so the role died before touching the network
while real ansible proceeded to (and failed on) a dead Google Storage
403. Re-verified on a fresh pair with 0.9.626: crystal now loads the
same version vars and fails at the identical upstream 403 - parity.

**Fixed 0.9.627 - `apt state: latest` ignored apt-get's exit code.**
`plugins/apt.cr` `handle_latest` only looked for the
"N upgraded, M newly installed" summary line; when apt-get exits 100
("E: Unable to locate package sensu" - packagecloud's sensu/stable repo
carries no jammy candidate), summary was nil and the fallback
`exit_code == 0` concluded "already at latest version", changed=false,
rc=0. Real ansible fails with "No package matching 'sensu' is
available". Found via `buluma.sensu-install` (py rc=2, crystal rc=0);
re-verified on a fresh pair with 0.9.627: both engines rc=2, identical.

**Fixed 0.9.629 - recursive re-templating of command args containing
literal `{{ ... }}` text (gantsign.helm).** The whole-output re-pass
loop in `substitute_impl` re-rendered brace text that came from an
evaluated QUOTED LITERAL in the task itself (helm's `--template
{{ "'{{ if .Version }}...{{ else }}...{{ end }}'" }}` argument),
parsing `{{ else }}` as a Jinja tag and failing with "'else' is
undefined" while real ansible (single-pass Jinja2, output never
re-scanned) ran the command fine. The loop now only engages when a
span of the ORIGINAL argument resolves via a variable lookup to a raw
value that is itself a template - real ansible's actual recursion
model. Regression specs in
`spec/unit/var_substitutor_recursive_retemplating_spec.cr`; live-
verified on a fresh pair: both engines rc=0 cold+warm (real 22.8s/10.7s
vs crystal 16.1s/2.6s).

**Non-divergence strictness differences recorded (both engines fail,
different reasons):** `gantsign.gitkraken` (2.19 rejects legacy
`always_run` on a `uri` task; crystal parsed it and continued to a 404)
and `andrewrothstein.cassandra-cluster` (2.19 rejects `become_user` on
a TaskInclude; crystal proceeded to a dead Oracle JDK 400).

**Environmental noise (both engines fail identically - not bugs):**
stale apt mirror 404s for pinned versions (airflow, awscli, azurecli,
binpack, gnome, mate, obsproject, rabbitvcs), dead upstream download
URLs (apacheds, bitcoin_core, cassandra, azure_pipelines_agent, ceph
repo), and Alpine-only packages on Ubuntu (alpine_iso_build).

Times for the round (all 60 roles, per-role cold/warm py-vs-crystal)
are recorded in `ROLES_TESTED.md`'s round-191 rows.

## Real gaps (worth revisiting)

- **Role-private `library/*.py` modules stay skipped** (documented
  no-arbitrary-Python scope cut, now seen live twice): the
  linux-system-roles family's `sr_fingerprint` success-fingerprint tasks
  (crypto_policies, journald) ship the role's own Python module; real
  ansible executes it with the target's Python while this engine skips
  it and exits with the "unavailable modules" rc=4 signal. Both engines
  otherwise agree; journald's only recap delta was those two skipped
  tasks (both engines rc=0).
- **The same no-arbitrary-Python scope cut also covers third-party
  COLLECTION custom modules and filters, not just role-private
  `library/*.py`** (round 199, bodsch.* author's own `bodsch.core`/
  `bodsch.systemd` collections - `bodsch.core.check_mode`,
  `bodsch.core.facts`, `bodsch.core.type` filter, `bodsch.core.upgrade`
  filter, `bodsch.systemd.journalctl`): real Ansible executes these as
  ordinary Python; this engine correctly reports "unavailable modules"
  for a MODULE reference and skips the task, but for a FILTER reference
  it currently degrades less clearly (an unrecognized filter silently
  passes its operand through unchanged instead of raising an
  "unavailable filter" error the way modules do), so a downstream `when:`
  or `set_fact:` built on the un-filtered value fails with a confusing
  type error ("Conditional result (True) was derived from value of type
  'dict'") rather than a clear unsupported-filter message. Confirmed
  against bodsch.chrony/monitoring_plugins/redis/monit/logrotate/
  tomcat/forgejo, all on Ubuntu 22.04 - every one of these roles calls
  at least one bodsch.core/bodsch.systemd custom module or filter for
  real logic (not just a declarative wrapper), so this author's roles
  specifically will keep diverging from real Ansible by design; not
  worth re-testing more of them expecting a different outcome.
- **A `vars:`-level filter chain resolving to a real Bool loses its type,
  coming back as the Python-repr STRING `"True"`/`"False"`** (round 199,
  robertdebock.epel): `epel_next: "{{ _epel_next[ansible_distribution_
  release] | default(_epel_next['default']) }}"` where `_epel_next` is a
  dict whose values are real Jinja booleans (`default: false, Stream:
  true`) - real ansible-core 2.19.4 resolves `epel_next` to a genuine
  Bool and a bare `when: [epel_next]` evaluates/skips it normally; this
  engine's `{{ type_debug }}` on the same variable reports `str` (value
  text `"False"`), and the strict-conditional check correctly rejects
  that non-bool result ("Conditional result (True) was derived from
  value of type 'str'"), turning a should-skip task into a hard failure.
  Minimal repro: a `vars:`-templated dict-index-with-`default()`-fallback
  expression whose resolved value is a Bool, referenced bare in a `when:`
  list. Likely the same "default() doesn't preserve the fallback
  argument's real JSON type" class as the FilterEngine boolean-passthrough
  fixed elsewhere for other filters - not yet traced to a specific line.
- **`changed_when` with a missing dict attribute is lenient**
  (cloudalchemy.pushgateway): the role's own `changed_when` references
  `.diff` on a dict result that has none - real ansible-core 2.19 raises
  while evaluating the conditional ("object of type 'dict' has no
  attribute 'diff'") and fails the task; this engine treats the miss as
  falsy and rc=0s. Matching 2.19 means raising on missing dotted
  attributes inside conditionals - a wide behavior change needing its
  own round.
- **`include_vars:` with a failing templated path** (gantsign.oh-my-zsh,
  harness-limited): when the path template itself can't resolve, this
  engine reports `include_vars: file not found: undefined` where real
  ansible fails a LATER task with "'users' is undefined". Both engines
  fail the role; the failure point and message differ.
- **±1-task recap deltas** (gantsign.java warm, cloudalchemy cold on
  re-run pairs sharing controller /tmp state): single loop-item/task
  counting differences; root cause not yet isolated.
- **`community.rabbitmq` warm deltas** (mrlesmithjr.rabbitmq re-run):
  both engines now run the role rc=0 with the new native
  rabbitmq_plugin/rabbitmq_user plugins, but crystal's warm pass reports
  changed=2 where real reports changed=0 (one plugin enable + one user
  item). The plugin-side detection was hardened twice (marker regex,
  ANSI strip, stderr merge) - the remaining delta needs the literal
  `rabbitmq-plugins list -e` / `rabbitmqctl list_users` output from a
  live host to pin down.
- **`community.general.ufw` rule idempotency delta** (Oefenweb.ufw,
  round 196 re-run): both engines now run the role rc=0, but on the warm
  pass crystal reports changed=4 where real ansible reports changed=0 -
  this engine's built `ufw` command differs enough from real
  community.general's own construction that ufw treats the re-applied
  rules as new. Real rule-tuple diffing (the module's actual
  idempotency check) needs netfilter access to verify; deferred.
- **collection modules**: `community.general.redhat_subscription`
  (linux-system-roles.rhc), `community.rabbitmq.rabbitmq_plugin/_user`
  (mrlesmithjr.rabbitmq) - unimplemented, rc=4 "unavailable modules"
  vs real ansible rc=0. Same class as the community.crypto notes below.



Round 190 (60-role marathon, fresh Atlantic.net pair per role, cold+warm
both engines) found and fixed six more engine bugs (all in 0.9.625):

- **`main.yaml` roles loaded an EMPTY defaults/vars/tasks set.**
  `load_vars_file_main` (and the tasks/handlers/meta main-file lookups)
  only ever checked `main.yml` - real Ansible accepts `.yml`/`.yaml`/
  `.json` interchangeably. `buluma.ara_api` ships `defaults/main.yaml`,
  so EVERY defaults var was undefined (`'ara_api_root_dir' is undefined`)
  and `buluma.handbrake`'s whole `tasks/main.yaml` role silently ran as
  ZERO tasks (rc=0 with ok=0 while real ansible did the real work).
  Fixed with a shared `find_main_file` across all five main-file sites.
- **`command:` with `environment: PATH:` couldn't find venv binaries.**
  `Process.new(env:)` sets the CHILD's environment but the executable
  lookup (execvp) uses the PARENT's PATH - `command: ara-manage` +
  `environment: PATH: <venv>/bin` failed "No such file or directory"
  while real ansible (which runs via `/bin/sh -c` with the env exported
  first) found it. The plugin now resolves the executable against the
  task's own PATH override before spawning.
- **Nested task-vars lost their types.** `render_task_vars` only
  templated top-level string values, so a task-level `vars:` DICT
  (ara_api's `reconciled_configuration: { DEBUG: "{{ ara_api_debug }}",
  ... }`) kept every nested bare-mustache as an unevaluated STRING -
  `set_fact` stored `"False"`/`"0"`, `to_nice_yaml` wrote quoted strings,
  Django crashed on `float + str`. Now recursively walks Hash/Array
  values through the same type-preserving bare-mustache path.
- **`set_fact` container values rendered as Python-repr text.**
  `substitute_task_params` applied `output: true` to EVERY module arg,
  stringifying a `set_fact: cfg: "{{ {k: v} }}"` container into the
  literal `{'default': {...}}` repr text. `set_fact` (and only set_fact)
  now gets `output: false` + a `native:` flag that keeps bare int/float/
  bool references as real JSON scalars (`DATABASE_CONN_MAX_AGE: 0`,
  `DEBUG: false`).
- **`apt_key: file:` was unimplemented** ("Missing required parameter:
  url or data" - mrlesmithjr.ansible_es_apm_server copies the key to
  /tmp then points file: at it). Now supported, target-side path.
- **`lookup('config', 'OPT1', 'OPT2', ..., wantlist=True)` was
  unimplemented** (`buluma.multi`'s color-loop failed `'item' is
  undefined`). Both evaluators now implement it with ansible-core 2.19
  defaults for the COLOR_*/DEFAULT_*/RETRY_* options roles actually
  look up, plus ANSIBLE_<NAME> env-var honouring.

Also fixed en route (round 190, found via the remote-only user_dir gap):
facts now derive `ansible_user_id/_dir/_shell/_gecos` from
`getpwuid(getuid())` instead of ENV - the facts plugin runs remotely in a
non-login SSH shell where USER/HOME/SHELL are frequently unset.

Remaining open from this round (documented, not yet fixed): none new -
the other same-fail roles are legacy `include:`, missing Galaxy
dependencies, or desktop packages on headless Ubuntu, all failing
identically on both engines.


Round 189's three divergences (list-form `failed_when:` filter-chain
false-fail, folded multi-line compound `when:` silent-skip, `async:`
over SSH refused) were all fixed in 0.9.624 - see git log.

Everything that used to be here is fixed - the nested-undefined chain
(`0.9.599`), `notify:` validation timing (`0.9.600`), the
`ansible_distribution` display name plus the `debugger:` assignment
commands and `--scp-extra-args` (`0.9.601`), the `omit` sentinel leak
(`0.9.602`), cross-role vars/defaults visibility (`0.9.603`), a failed
dynamic `include_role:` double-counting `ok` alongside `failed`
(`0.9.605`), `user:`'s `groups:` passing a literal `"[]"` straight
to `useradd` (`0.9.606`), an undefined variable reaching a filter
being silently coerced to an empty result instead of failing the task
(`0.9.607`), and - found while building the `community.crypto` modules
(`0.9.608`) - the missing `playbook_dir`/`inventory_dir`/`inventory_file`
magic vars plus task-level `check_mode:` being ignored in both
directions (`0.9.609`), and then - found while verifying those - the
inventory loader's missing implicit localhost, directory and host-list
sources, an `[all:vars]` block reaching nobody at all, and `group_names`
omitting `ungrouped` (`0.9.610`), and INI inventory values being typed
by this engine's own rules rather than Python's `literal_eval`
(`0.9.611`), and finally the three that fix exposed: non-boolean
`when:` results being accepted, containers rendering as JSON rather than
Python repr, and INI host lines being whitespace-split rather than
shlex-split (`0.9.612`); and - found in round 186's 60-role marathon -
a list-form `when:` made of `x | bool` filter chains hard-failing under
the new strict-boolean check because the filter chain's own render path
produces Python-repr text ("True"/"False") that isn't valid JSON
(`0.9.613`), a plain-mustache `{{ expr -}}`/`{{- expr }}` trim marker
having its CHARACTER stripped but never its WHITESPACE-TRIMMING EFFECT
applied, corrupting any multi-line YAML `|-` block built from one such
span per line (`0.9.614`), and a bare FLOAT literal (`5.1`) in a
comparison having no case at all in the strict-undefined evaluator,
plus no float-numeric fallback in the comparison itself once found
(`0.9.615`); and - found in round 187's 60-role marathon, all four
stacked in the SAME motivating role - a multi-package `pip:` `name:`
list containing a shell metacharacter (`urllib3<2`) breaking the
`bash -c` invocation it reached unescaped, plus the per-package
idempotency check that surfaced once fixed (`0.9.616`), `lookup('file',
...)` on a missing file silently returning the "undefined" sentinel
instead of raising like real Ansible - and that sentinel then getting
written straight into `~/.ssh/authorized_keys` as if it were a real key
(`0.9.616`), the `user:` module's registered result never carrying
home/uid/group/shell/name at all, so `.home` etc. was always undefined
regardless of whether the user already existed (`0.9.617`), a
nonexistent command's exec failure never populating rc/stdout the way
real Ansible's own ENOENT handling does, so a `failed_when: false`-
guarded probe left a later `.stdout` reference genuinely undefined
(`0.9.618`), `systemd_service`'s `scope: user` being completely
unhandled - every systemctl call always hit the system manager
regardless (`0.9.619`) - which once fixed exposed real Ansible's own
auto-set `XDG_RUNTIME_DIR` for scope:user having no equivalent here
(`0.9.620`), which once fixed exposed the actual root cause underneath
all three: block-level `become:`/`become_user:` was never inherited by
child tasks at all, so an entire block silently ran as root instead of
the intended user (`0.9.621`); and, found in the same round, a
`meta/main.yml` dependency written with `src:` (real Ansible's own
`RoleRequirement` key, not just `role:`/`name:`) aborting the parse of
the WHOLE PLAYBOOK (`0.9.622`); see `git log`. Two more turned out not to be
engine bugs at all and were withdrawn rather than fixed:
`buluma.phpmyadmin`'s warm-rerun churn is role-side (`geerlingguy.php`
and `buluma.php` both own `php.ini` and overwrite each other, on real
Ansible too), and the `buluma.httpd` "Configure httpd" difference
chased after it was an artifact of my own comparison - alternating two
engines against ONE shared host makes each run the other's cold state.
On a clean single-engine sequence both engines alternate `ok` then
`changed` identically, because that role's template strips the
`Include /etc/phpmyadmin/apache.conf` line the phpmyadmin role's
`lineinfile` re-adds every run.

And - found re-verifying `weareinteractive.vsftpd` (which `ROLES_TESTED.md`
marked "unblocked in 0.9.608, not yet re-run live") - two pre-existing
engine bugs that survived the 0.9.608 community.crypto additions, both
fixed in `0.9.623`. (1) `import_tasks: ... when: <gate>` was combining
the parent's `when:` as `"#{child} and #{parent}"` - child operand
first. Real Ansible evaluates `and` left-to-right with short-circuit,
so when the parent gate is `false` the child operand should never be
evaluated; crystal was evaluating the child first, hitting
strict-undefined on a `register:` reference from a prior inner task
that the gate would have skipped, and aborting the whole play with
`'item_stat.stat.exists' is undefined` even though real Ansible would
have skipped the whole file. One-line fix in `playbook_parser.cr:1469`:
parent `when:` prepended, not appended. (2) `MODULE_SEARCH_COLLECTIONS`
was missing `"community.crypto"`, so bare short names
(`openssl_privatekey:`, `openssl_csr:`, `x509_certificate:`,
`openssl_pkcs12:`, `openssh_keypair:`) had no FQCN-prefix to try
against `AVAILABLE_PLUGINS`, the resolver returned `nil`, the task
was dropped with a "uses unimplemented plugin" warning, and the work
was silently skipped despite the plugin source AND compiled binary
both existing - the 0.9.608 community.crypto additions arguably
unblocked the engine from `rc=4` errors but did NOT actually run the
work in roles that use the bare short names (the community-collection
idiom). One-line fix in `playbook_parser.cr:932-935`: added
`"community.crypto"` to the list. After both fixes, the
`weareinteractive.vsftpd` re-verify is byte-identical to real
ansible-core 2.19.4 on Ubuntu 22.04 (cold 20.73s vs py 63.91s; warm
3.84s vs py 40.89s; same `ok=12 changed=5 failed=0 skipped=14` /
`ok=11 changed=0 failed=0 skipped=14` recap both engines, both
phases).

And - found re-running the rest of the original round 188 shortlist
after the 0.9.623 re-verify landed (`~/scratch/round188_10roles/`,
9 new roles: `andrewrothstein.{calicoctl,cfssl,coder,bazel}`,
`mrlesmithjr.{nfs-server,ansible_apt_sources}`,
`geerlingguy.{sonar-runner,ssh-chroot-jail}`, `buluma.forensics`,
fresh Atlantic.net pair per role, cold + warm both engines). 8/9
clean, 1/9 environmental both-fail (`geerlingguy.ssh-chroot-jail` -
the role tries to copy `/usr/bin/vim` into the chroot, `vim` isn't
installed on a fresh Rocky 9.6 image, both engines hit the same
`"/usr/bin/vim not found"` and fail the task the same way), 1/9 a
NEW real engine bug (`buluma.forensics` Rocky 9.6, crystal rc=2 vs
py rc=0 - the role's `command_collector | Save output` task uses
`delegate_to: localhost` for an `ansible.builtin.copy` module, and
krikri-playbook tries to scp the plugin binary to `localhost:22`
before running it, which fails with "Connection refused" on a cloud
VPS whose controller has no sshd running; real ansible-core runs
the plugin via `connection: local` and never ssh's to itself). Fix is
in `src/krikri/task_executor/executor.cr` `delegate_to:`
resolution: short-circuit to `connection: local` when the delegate
target is the controller (localhost / 127.0.0.1 / controller
hostname), so the SSH plugin-upload step is bypassed entirely and
the plugin is run on the controller's filesystem directly. The role
itself is correct (real ansible passes); the bug is structural and
likely affects every role that uses `delegate_to: localhost` for an
SSH-uploading module on a controller without sshd. Per-role timings
recorded in `~/scratch/round188_10roles/results/timings-continuation.tsv`
(real 12-298s, crystal 1.9-62s - crystal 1.3-17x faster on every
role, both phases). Two entries remain.

- **Templating is not native-typed, and real Ansible's now is.** A
  `{{ }}` expression whose value is a YAML int renders here as the
  STRING "3" where ansible-core 2.19.4 gives the int 3. Reproduced
  minimally (`a_number: 3`, `v_num: "{{ a_number }}"`):
  `v_num | type_debug` is `int` on real Ansible and `str` here, so
  `v_num == 3` is True there and False here, and `v_num == '3'` is
  False there and True here - a `when:` gate on either spelling can
  take the opposite branch.

  This is a MODEL difference, not a bug at one call site, and the
  comment in `crinja_renderer.cr` asserting that "real Ansible's
  default (non-jinja2_native) templating renders a `{{ }}` expression
  to plain text and does NOT re-infer a scalar type" is simply out of
  date: that was true through ansible-core 2.18, and 2.19 made native
  types the default. Anything done here has to keep the case that
  motivated the current behavior working - `bind_python_version: "{{
  bind_default_python_version }}"` where the referenced var is the
  quoted YAML STRING "3" must stay the string "3" (buluma.bind's own
  `(bind_python_version == '3') | ternary(...)`, which picked the wrong
  branch and installed python2-era package names when this engine
  re-inferred types blindly). Native typing satisfies both - it
  preserves the SOURCE type rather than re-inferring from rendered text
  - which is why this is worth doing properly rather than patching per
  call site. Sizeable: it touches both evaluators.

  **How often does this actually bite? Measure before building.**
  Exposure is much narrower than "numbers are broken", and the one
  corpus measured so far says it may not be worth the rewrite yet.
  Of 16 realistic templating shapes checked against ansible-core
  2.19.4, only FIVE diverge, and every one needs both conditions: the
  value passes through a TEMPLATE INDIRECTION (`v: "{{ other }}"`) and
  is then equality-compared, membership-tested, or type-inspected:

  | diverges                    | agrees                              |
  |-----------------------------|-------------------------------------|
  | `ind == 3` (True -> False)  | direct `n_int == 3`                 |
  | `ind == '3'` (False -> True)| arithmetic `ind + 1`, `\| int`      |
  | `ind \| type_debug` int->str| `>` / `<` comparisons               |
  | bool `type_debug` bool->str | truthiness, `if/else`               |
  | `ind in some_list` T->F     | rendering to text, `\| length`      |

  In a 353-YAML corpus (the `buluma.phpmyadmin` dependency chain - 7
  Galaxy roles) the divergent shape appears ZERO times. All 12 numeric
  equalities there are against REGISTER FIELDS (`php_installed.rc != 0`,
  `result.status == 200`), which come from module JSON rather than
  template rendering and are natively typed on BOTH engines - verified
  identical, `type_debug` included. That sample is small and
  homogeneous (one Debian web stack), which is exactly why the next
  round should widen it rather than guess.

  **Proposed for the next benchmark round - a passive frequency
  measurement, NOT a change to role selection.** Run whatever roles the
  round would have picked anyway; before running, scan the downloaded
  role set. Do NOT go hunting for roles that use the shape: selecting
  for it answers "does it break when exercised", which is a different
  question and cannot measure frequency, since the sample is biased by
  construction. Hunt only if the passive scan shows real occurrences.

  A naive grep is NOT good enough - it was tried, and 12 of 12 hits were
  false positives (register fields). The detector has to cross-reference
  the operand:

  ```
  for each `X == <number>`, `X != <number>`, or `X in <var>` in a role's
  tasks/ (including when:/until:/changed_when:/failed_when:/assert that:):
      look X up in that same role's defaults/main.yml + vars/main.yml
      report ONLY if X is defined there AND its value contains "{{"
      (the indirection is what diverges; a literal or a register field
      does not)
  ```

  Roughly 20 minutes to write once, then free on every later round.
  Report per role: file, line, the expression, and X's defining value.

  Decision rule for whoever runs it: if the shape shows up in a
  meaningful fraction of a WIDER corpus (a RHEL/hardening/collection
  sweep, not another Debian web stack), that justifies the native-typing
  work - and each hit is a ready-made motivating role and regression
  test, which is how every other fix in this project got one. If it
  stays at or near zero across a few hundred more roles, leave this
  entry documented and spend the time elsewhere: when it does bite it
  bites silently (an inverted `when:` gate, no error, no failed task),
  which is why it stays recorded at all rather than being withdrawn.

  **Frequency scan run** against a 611-role corpus (every role ever used
  across all benchmark rounds to date - buluma/robertdebock/geerlingguy/
  mrlesmithjr/weareinteractive/etc., a much wider and more author-diverse
  sample than the earlier 353-file single-dependency-chain corpus; ~60
  of the requested 672 roles 404'd on Galaxy, the usual dead/renamed-repo
  noise). The cross-referencing detector (script not checked in - a
  ~100-line Python one-off, regex-based rather than a real YAML/Jinja
  parse) found 5 hits across 5 roles, but 3 are detector-side false
  positives it can't rule out statically: `X in <var>` matched two
  Jinja *substring* tests on string values (`bootstrap_install.
  stdout_regex in bootstrap_install_packages.stdout` in `buluma.
  bootstrap`/`robertdebock.bootstrap`, `java_folder in temp` in the
  transitively-pulled `lean_delivery.java`) - substring testing on a
  string renders identically under both typing models regardless of the
  indirection, so these don't actually diverge; only *list*-membership
  against typed elements does, and the static scan can't tell the two
  apart without evaluating the right-hand operand.

  The one real hit, duplicated across two near-identical role forks
  (`robertdebock.java` and `buluma.java`), is exactly the documented
  shape and is live/reachable today: `vars/main.yml` maps
  `ansible_distribution` to a YAML-int Java version table
  (`_java_default_version: {Alpine: 8, RedHat: 11, Ubuntu-18: 17, ...}`),
  indirects it twice (`java_default_version`, then `defaults/main.yml`'s
  `java_version: "{{ java_default_version }}"`), and gates the Oracle
  JCE-policy install task on `java_version == 8` (the role's own comment
  shows the author even weighed `== "8"`). On real ansible-core 2.19
  `java_version` stays `int 8` and the task correctly runs on
  Alpine/Gentoo/Suse; here it renders as the string `"8"`, the equality
  is always False, and the task is silently always skipped regardless of
  distro - no error, no failed task, matching the "bites silently"
  warning above exactly.

  **Verdict: still near zero (1 genuine pattern in 611 roles, ~0.16%)
  even on a much wider, non-Debian-web corpus - the decision rule's
  "meaningful fraction" bar is not met.** Per the rule, defer the full
  native-typing rewrite. `robertdebock.java`/`buluma.java`'s
  `java_version == 8` is now a ready-made motivating role and regression
  test if the rewrite is ever picked up; it could also be patched as a
  narrow one-off (special-case numeric equality against an
  `{{ other_var }}`-only indirection) rather than waiting on the full
  model change, if this specific role is ever hit in a live benchmark
  round.

- **`get_url`/`lookup('url', ...)` can't complete a TLS handshake
  against a server running very old OpenSSL/TLS.** Found in round 187's
  60-role marathon: `andrewrothstein.subgit` downloads
  `https://subgit.com/download/subgit-3.3.18.zip`, whose server (Apache
  2.4.25, OpenSSL 1.0.2u per its own response header) real Ansible's
  Python TLS stack negotiates fine but Crystal's stdlib `HTTP::Client`
  cannot: `SSL_shutdown: error:0A000197:SSL routines::shutdown while in
  init`, reproduced directly with a bare `HTTP::Client.get` (not
  anything this project's own wrapper does differently) - a genuine
  Crystal/OpenSSL binding limitation talking to a legacy TLS
  configuration, not a bug in this project's download code. Fixing it
  properly would mean deliberately relaxing this engine's TLS context
  (lower minimum version and/or broader cipher list) for every HTTP(S)
  download - a security-relevant tradeoff worth a real decision, not a
  quick patch slipped into an unrelated benchmark round. Documented, not
  fixed. `curl` from the same host reaches the server fine, confirming
  it's specifically Crystal's own TLS client, not network/DNS/firewall.

## Explicit scope cuts (not gaps to fix - documented so they aren't re-litigated)

- **`ansible-playbook`'s CLI flag surface is fully covered by name, and
  all but one flag is now behavioral.** `--help` lists every flag real
  ansible-core 2.19.4 does.

  * `-M`/`--module-path` is accepted and ignored, and this one is a real
    scope cut rather than an oversight: real Ansible searches those
    directories for PYTHON modules, while every module here is a
    compiled binary shipped with the engine. Honouring the flag would
    mean an arbitrary-Python-module runner (already an explicit scope cut
    below), and pretending to honour it - silently searching the given
    path for a same-named compiled binary - would be a worse failure
    mode than ignoring it, since a user's `-M` directory holds `.py`
    files this can never execute.
  * `--scp-extra-args` became real in `0.9.601`. The entry that used to
    live here ("accepted and stored, but nothing to attach to - this
    engine moves files over ssh plus a piped stream rather than shelling
    out to scp") was wrong on its own facts: `SSHManager#upload_file`/
    `#download_file` are `scp` invocations, and `PluginManager` falls
    back to scp for the plugin-binary push whenever rsync is missing on
    the target. It now extends those command lines, alongside
    `--ssh-common-args` (which real Ansible applies to scp as well -
    only `--ssh-extra-args` is ssh-only).
  * `--sftp-extra-args` is accepted and inert, and correct by
    construction: nothing here ever invokes `sftp`, so - exactly as in
    real Ansible under a non-sftp transfer method - there is no sftp
    command line for it to extend.
  * `--flush-cache` is accepted and correct by construction: facts live
    only in a run-scoped store, so there is no on-disk cache to
    invalidate.
  * Short forms match real Ansible as of `0.9.566`: `-C` is `--check`,
    `-D` is `--diff`, `-c` is `--connection`. **`-c` previously meant
    `--check` in this engine and no longer does** - a breaking change,
    made deliberately so a command line copied from `ansible-playbook`
    behaves the same here. `-d` is kept as an extra alias for `--diff`
    (real Ansible has no `-d`, so it collides with nothing).

- Cloud provider modules (`amazon.aws`/`community.aws` - `ec2_instance`,
  `s3_object`, IAM, security groups, etc.), `azure_rm_*`, and dynamic
  cloud inventory *plugins* (`aws_ec2.yml` et al.) - not implemented,
  not planned. These are a fundamentally different kind of module (HTTP
  calls to a cloud API from the controller, needing real request
  signing/auth, not shell commands run on a managed target) - a real
  API client built from scratch, not "another module that shells out to
  a CLI tool" like everything implemented so far. Revisit only if a
  specific real-world need justifies the investment.
- `community.general.apache2_module` (Debian/Suse `a2enmod`/`a2dismod`
  wrapper) has no plugin binary at all. Found round175 benchmarking
  `buluma.httpd` on Rocky 9.6: the role's own "locations | Enable
  modules" task is gated `when: ansible_facts['os_family'] in
  ["Debian", "Suse"]` and is correctly skipped by both engines on
  RHEL-family, but this engine's own eager parse-time module-resolution
  check (the same one that made a role-private custom module or a
  genuinely misspelled module exit 4, see above) still counts the
  reference against `unavailable_modules_found` regardless of whether
  the gating `when:` will ever let it run - which matches real
  Ansible's OWN behavior (verified live: `couldn't resolve module/
  action` fires at parse time even behind `when: false`) given a bare
  `ansible-core` with no `community.general` installed. The actual
  divergence is that the local real-ansible comparison side has
  `community.general` installed (`ansible-galaxy collection list`
  shows 11.2.1/12.5.0), so it resolves the module and never reaches
  this check at all. Not a logic bug - a genuinely unimplemented
  plugin. Deferred rather than implemented blind: needs a real
  Debian/Suse host (not exercised by this round's RHEL-only pair) to
  verify `a2enmod`/`a2dismod` invocation and idempotency
  (`apache2ctl -M` mtime-check semantics) against actual behavior
  before shipping it.
- More of the same "genuinely unimplemented plugin, referenced only in
  a task this platform never actually reaches" class as
  `community.general.apache2_module` above, found sweeping 60 new
  roles (rounds 177-179) - same root cause each time (this engine's
  eager parse-time module check counts a reference regardless of a
  gating `when:`, matching real Ansible's own behavior, but the local
  comparison side happens to have the collection installed and never
  hits the check): `ansible.builtin.cronvar` (`weareinteractive.cron`
  - a real core module, unlike the others here; worth implementing if
  it recurs, modest scope, similar spirit to `lineinfile`/`cron.cr`),
  `zypper` (`weareinteractive.docker` - SUSE-only, out of this
  project's Ubuntu/RHEL scope, not planned),
  `community.docker.docker_compose_v2` (`mrlesmithjr.blocky`),
  `community.general.clustering.consul.consul_acl`
  (`mrlesmithjr.consul` - also demonstrates the "WHICH TASKS RUN
  differs" side of this same gap: real Ansible refuses at parse time
  with zero tasks run, this engine runs the whole play first, ~80s of
  real work, before reporting the same rc=4 - already covered by the
  role-private-custom-modules entry below, not distinct).
- The legacy free-form `action: "<templated module name> key=val ..."`
  task syntax (module name and args packed into one string, with the
  module name itself resolved from a runtime variable like `{{
  ansible_pkg_mgr }}`) isn't parsed at all - this engine treats the
  literal YAML key `action` as the module name itself, reporting
  `unavailable modules: action`. Pre-2.4-era idiom, found in
  `weareinteractive.users_oh_my_zsh` (round 178). Not implemented -
  real-world usage of this exact form is rare and every modern role
  uses `ansible.builtin.<module>:` directly instead.
- Role-private custom modules (a role's own `library/*.py`, outside the
  `ansible.builtin`/`community.*`/etc. plugin set this engine ships as
  native binaries) - there's no generic arbitrary-Python-module runner,
  so these can't execute at all. The task is skipped with a
  parse-time warning ("uses unimplemented plugin: <name>") rather than
  crashing the run - deliberately, so a role leaning on its own
  `library/*.py` stays benchmarkable for everything else it does - but
  anything downstream depending on its result sees an undefined value,
  which can cascade into broader task-status divergence for roles that
  lean on this (seen repeatedly benchmarking `linux-system-roles`:
  `sr_fingerprint`, `timesync_provider`, `kernel_settings_get_config`,
  `blivet`). Since `0.9.558` such a run **exits 4**, real Ansible's own
  code for refusing a playbook it can't resolve a module for, instead of
  the previous 0 - which reported a green run to CI for a playbook real
  `ansible-playbook` rejects outright. What remains divergent here is
  only WHICH TASKS RUN (real Ansible refuses at parse time and runs
  nothing; this engine runs the rest of the play), not the exit status a
  caller sees.
- `docker_*`'s `api_version:` pin - not implemented, not planned. The
  underlying `docr` client uses unversioned endpoint URLs throughout,
  so pinning a version means touching every endpoint in a separate
  shard; the unversioned URLs negotiate fine against current
  Docker/Podman. Revisit only if a real playbook actually needs the
  pin.
- `meta:` narrowed further in `0.9.480`: now also supports
  `refresh_inventory` (0.9.479 added `end_host`/`end_play`/
  `clear_host_errors`/`noop`), each ported from real Ansible's own exact
  semantics (`ansible/plugins/strategy/__init__.py`'s `_execute_meta`)
  and live-verified, including the non-obvious ones - `end_play` and
  `clear_host_errors` are genuinely GLOBAL (affect every currently-
  active/every-failed host in the play respectively, even one that
  never itself executes the meta task, e.g. because its own `when:`
  skips that specific task), while `end_host` is per-host only;
  `clear_host_errors` exempts a host from later plays and from the
  run's own exit code, but does NOT resume execution for it in the
  CURRENT play; `refresh_inventory` re-reads a dynamic inventory
  script's output in place, but (real Ansible's own documented caveat,
  also verified live) does NOT add newly-discovered hosts to the
  CURRENT play's own host loop, only to a LATER play's. Implementing
  `end_host`/`end_play` also surfaced and fixed a real, previously
  latent bug: `when:` on any `meta:` task (including the pre-existing
  `clear_facts`/`flush_handlers`) was never evaluated at all - parsed
  and silently dropped - so a when:-gated meta task always ran
  unconditionally regardless of the condition. What's left
  unimplemented: `reset_connection`/`end_batch`/`end_role` still act on
  execution-flow machinery this engine models differently (persistent-
  connection control, `serial:` batching, and role-scoped early-return
  respectively), and are rejected at parse time rather than silently
  accepted and ignored.
- `config`/`inventory_hostnames` lookups - architecturally out of scope
  (would require modeling Ansible's own config-resolution/inventory
  internals, not just a data lookup).
- `win_*` filters - Windows-only, irrelevant to this project's targets.
- `community.crypto`'s remaining modules. **This is no longer the blanket
  scope cut it used to be**: `openssl_privatekey`, `openssl_csr`,
  `x509_certificate` (providers `selfsigned` and `ownca`) and
  `openssl_pkcs12` (`action: export`) are implemented as of `0.9.608`,
  which is what the 13 roles in the corpus that touch this collection
  actually call - joining `openssl_dhparam` and `openssh_keypair`, which
  were already here. They are built on the `openssl` CLI rather than on
  the `dirless/x509-crystal` shard the earlier note pointed at: that
  shard generates whole CA+client bundles in one call and exposes no
  CSR-based issuance, while the CLI reproduces the real modules' file
  formats, extensions and idempotency rules directly (all four were
  differentialed against real community.crypto 3.1.1, both directions -
  neither engine regenerates the other's artifacts).

  Still unimplemented, none of them seen in a role yet: `openssl_publickey`,
  `openssl_privatekey_info`, `x509_certificate_info`, `get_certificate`,
  `luks_device`, and the `acme`/`entrust` certificate providers plus
  `openssl_pkcs12`'s `action: parse` (all of which fail with a clear
  "not supported" message rather than silently doing something else).
  The `*_info` ones are read-only and cheap if a role ever needs them;
  `acme` means speaking ACME to a real CA, which stays out of scope.
- `community.general.vdo` - unimplemented; untestable so far, no real
  role sets a non-empty `vdo_devices`.
- `gluster.gluster.gluster_volume` - unimplemented; causes a cosmetic
  parse-time task-drop vs. real Ansible's "skipping" recap line, not a
  runtime crash.
- `community.general.zypper_repository` - unimplemented; same cosmetic
  parse-time-drop class, no zypper/openSUSE host ever tested.
- `ansible.posix.firewalld` - narrowed considerably in `0.9.478`:
  `zone:` now defaults to the system default zone
  (`firewall-offline-cmd --get-default-zone`), and real Ansible's own
  `permanent`/`immediate`/`offline` validation logic is ported exactly
  (verified against `ansible/posix/plugins/modules/firewalld.py`'s own
  `main()`) rather than requiring `offline: true, permanent: true`
  explicitly. What's left unimplemented is now only the one combination
  real Ansible services over a live D-Bus connection that this plugin
  has no backend for: a genuinely running firewalld daemon (auto-
  detected via `firewall-cmd --state`, real Ansible's own detection
  equivalent) AND an `immediate:` runtime change actually requested (or
  defaulted - real Ansible silently forces `immediate: true` whenever
  neither `permanent:` nor `immediate:` is given). Every other
  combination - which is every combination likely on the containerized/
  no-init-system hosts this project's benchmark rounds target - is
  serviced via `firewall-offline-cmd`, matching real Ansible's own
  auto-fallback. Verified live in a real firewalld 2.3.1 container
  (`firewall-cmd`/`firewall-offline-cmd`), byte-identical `ok=5
  changed=2 failed=0 ignored=1` against real `ansible-playbook` across
  4 scenarios (permanent-only enable, idempotent rerun, defaulted zone,
  and the still-unimplemented bare-defaults-against-no-daemon case
  correctly failing with real Ansible's own exact error message on
  both).

---

For the fixed-bug history (150+ rounds of real-host benchmarking against
production Ansible roles), see `git log`.
