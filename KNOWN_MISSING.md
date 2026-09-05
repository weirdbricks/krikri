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

Two lists, and the split is the point: **Open gaps** is defects with an
unknown or unfinished fix - if you are looking for something to work
on, it is there and it is short. **Deliberate limits** is decisions
already made, with the reasoning attached; nothing there is waiting on
anyone. An item that stops being a defect moves down or gets deleted,
it does not linger at the top. Everything between the two is per-round
narrative, newest first.

**Currently at `0.9.741`.** Vendored `crinja` fork now at tag
`crystal-play-0.9.27` (see `shard.yml`).

---

## Open gaps

Genuinely open defects: something is wrong and the fix is unknown or
unfinished. Everything deliberate lives under "Deliberate limits"
below - keep the two apart, or this list stops meaning anything.

(None.)

---

## Round 306 (general lazy dict-templating closed: fork keys-default flip + combine recursive/list_merge, 0.9.740 -> 0.9.741)

Closed the general-case gap (`LAZY_DICT_TEMPLATING_INVESTIGATION.md`
problem B) empirically rather than via the "deferred evaluation +
type preservation" rewrite the gap's framing implied. A battery of
computed-dict shapes was run through BOTH engines side by side against
real `ansible-core` 2.19 (provisioned playbooks, output-diffed) to find
what actually still diverged. The answer: the type-recovery machinery
added piecemeal since 0.9.700 (render-then-parse-back, structural
Crinja evaluation fallback) already handles the vars pipeline for
every realistic computed-dict shape; what remained were two concrete
divergence classes, both now fixed:

1. **The crinja fork's bare-dict iteration default** (the
   "known remaining divergence, deliberately left reactive" note in
   Round 305): `Value#each`/`raw_each` yielded `(key, value)` tuples
   for a `Hash`, so `dict | list`, `dict | join`, `dict | first`/
   `last`/`min`/`max`/`unique`/`map`/`select`/`reverse` all saw
   tuples where real Ansible sees KEYS (Python's `for k in dict:`
   semantics). Fixed in fork release `crystal-play-0.9.25` (commit
   `81085da8`): keys-only default everywhere, with the one
   load-bearing consumer - the two-variable `{% for key, val in
   dict %}` pairs form - built explicitly by the `for` tag itself
   (real Ansible hard-fails that form; keeping it is the same
   deliberate leniency as Round 305), and `dictsort`/`urlencode`/
   `reverse` building their pairs/reversed-keys explicitly. Fork
   suite: 675 examples, 0 failures.
2. **`combine(recursive=True)` / `list_merge=` silently ignored** in
   BOTH evaluators (FilterEngine's `combine_hash` and jinja_filters.cr's
   Crinja-side `combine`): a recursive deep-merge silently DROPPED
   nested-dict data (returned the override's subtree intact, losing the
   base's sibling keys) and list collisions always replaced. Both now
   implement real Ansible's full `recursive=` deep-merge and all six
   `list_merge=` modes ('replace', 'keep', 'append', 'prepend',
   'append_rp', 'prepend_rp'), verified against real ansible-core 2.19.
   A third latent bug surfaced on the way: `FilterEngine`
   #resolve_expression had no `[...]` array-literal branch, so a dict
   literal with an array value (`combine({'l': [1, 2]})`) resolved the
   value to JSON null - data silently dropped; now parsed recursively.

Verified: full `crystal spec` (2515 examples) and `ameba` (447 files)
clean; every battery shape output-identical to real `ansible-playbook`
live on localhost, including single-var for (keys), `.items()` (pairs),
`| sort` (keys), `dictsort` (pairs), two-var lenient pairs form, and
all the keys-only filter shapes; the two special-cased
`jtyr.nsswitch`/`jtyr.motd` regression specs (0.9.697-0.9.700) pass
untouched. `spec/unit/lazy_dict_templating_spec.cr` pins all of it.

Follow-up verification (independent re-check of the whole round) caught
one formatting divergence the round's own spec had wrongly encoded as
expected: real ansible-core 2.19 converts Python tuples to LISTS at
every rendered-output position (its native-types finalization) -
`{{ (1, 2) }}` renders `[1, 2]`, `{{ d1 | dictsort }}` interpolates as
`[['a', 1], ...]`, not `[('a', 1), ...]`. Fixed at both boundaries:
the fork's `Finalizer#stringify(Crinja::Tuple)` (released as
`crystal-play-0.9.26`, governing raw .j2-text output) and krikri's own
`crinja_value_to_json_any` (the JSON-world crossing the old `else`
branch was stringifying tuples through). The round's dictsort spec
expectation is corrected, plus a new every-output-position regression
spec.

A second follow-up caught the converse, in the one position the
native-types conversion does NOT reach: an explicit `| string` applies
Python's own `str()` BEFORE the tuple->list conversion, so
`{{ d1 | dictsort | string }}` renders `[('a', 1), ('b', 2)]` (brackets
outer, parens inner). Fixed in fork release `crystal-play-0.9.27`
(`Finalizer` grows a python_str mode the `string` filter sets).
Regression specs pin both the fixed inline form and the fork-side
behavior. One residual case this round deliberately left alone - a
tuple-bearing value stored in a var, then `| string`'d later - is
recorded under "Deliberate limits" below (Templating) rather than
here, since it's a decision, not an open defect.

The investigation doc's section-6 sketch is now essentially what
shipped (the `each`/`raw_each` semantic flip it deferred IS the 0.9.25
change, with the pairs support moved into the `for` tag as it
recommended); problem B is closed with no evidence the full rewrite
would have bought anything further.

## Round 305 (PowerDNS.pdns dict-iteration fix, crinja fork release, 0.9.739 -> 0.9.740)

Closed the single-loop-variable dict-iteration shape of this gap
(documented in `LAZY_DICT_TEMPLATING_INVESTIGATION.md` - read that
first; it traces the root cause through the fork and records why a
naive `for`-tag-only patch fails). Fix landed as a REAL release of the
vendored crinja fork, not a `lib/` edit: `weirdbricks/crinja` tag
`crystal-play-0.9.24` (commit `cde6938d`).

Deliberately NOT the design sketch's `each`/`raw_each` semantic flip:
that default (Dictionary yields `(key, value)` tuples) is load-bearing
for the two-variable `{% for key, val in dict %}` pairs form that
`jtyr.nsswitch`/`jtyr.motd` shipped and live-verified on. Instead the
two lossy paths are special-cased in the fork itself:

- `src/lib/tag/for.cr`: exactly ONE loop variable + a raw `Hash`
  collection iterates the dict's KEYS (Python's `for k in dict:`).
  Two-variable form unchanged - `Context#unpack` still splits pairs.
- `src/lib/filter/sort.cr`: a raw `Hash` target sorts its KEYS
  (Python's `sorted(dict)`). `dictsort` and `.items()`-shaped pair
  arrays unaffected (both verified by new fork specs).

This also fixes the previously-unfixable half of the investigation's
section-5 attempt: the `sort()` path lost the "came from a dict" type
information inside the filter before the `for` tag ever saw it, which
is exactly why the earlier `for`-tag-only patch half-worked.

Verified: fork's own suite 666 examples 0 failures; krikri full suite
(2501 examples) and `ameba` (446 files) clean with the new pin;
`jtyr.nsswitch`/`jtyr.motd` regression specs untouched and passing.
Live end-to-end via `krikri-playbook` + `template:` against localhost,
all three shapes matching real Ansible: single-var direct for (keys),
single-var `| sort()` (sorted keys), two-var direct and
`.items() | sort` (pairs). Known remaining fork divergence, recorded
in the fork's PATCHES.md and left reactive: other `to_a`/`each`
consumers (`list`, `map`, `select`/`reject`, `join`, membership) still
see tuples for a bare dict - nothing in the role corpus hits those.
The general lazy-dict-templating gap above stays open, unchanged.

**Addendum**: subsequently re-verified against the actual
`PowerDNS.pdns` role itself (not just the synthetic repro above), live
in a podman systemd container with a real PowerDNS install - `ok=17
changed=7 failed=0 skipped=13` cold and `ok=15 changed=0 failed=0
skipped=13` warm, both an EXACT match to real `ansible-playbook`;
`/etc/powerdns/pdns.conf` byte-identical between engines;
`systemctl is-active pdns` reports `active` on both. See
`ROLES_TESTED.md`'s own row for full timings.

## Round 304 (podman virtualization-facts fix, 0.9.738 -> 0.9.739)

Investigated the open gap round 303 left behind. `detect_virtualization`
(`src/krikri/plugin_helpers/facts_gatherer.cr`) leaned on the external
`systemd-detect-virt` binary as its only real container-runtime signal;
a minimal podman image with no `systemd` package installed has neither
that binary nor `/run/systemd/container`, so detection silently fell
through to "None" - confirmed live by reproducing the exact function
call in isolation inside such a container. Read real Ansible's own
`LinuxVirtual#get_virtual_facts` (`module_utils/facts/virtual/linux.py`,
available locally via the `ansible` apt package) to find the actual
mechanism: PID 1's own `container=` entry in `/proc/1/environ`, which
podman/systemd-nspawn/LXC set unconditionally regardless of what's
installed. Added the same check (new pure `parse_container_env`
helper, unit-tested directly). Live-reverified: `ansible_virtualization_
type=podman`/`role=guest` now match real Ansible even with
`systemd-detect-virt` completely absent. Full spec suite (2501
examples) and full `ameba` (446 files) clean.

---

## Round 303 (dict-iteration `.items()` fix, from a parallel worktree, 0.9.737 -> 0.9.738)

Found and fixed in a separate worktree (`fix-dict-iteration` branch),
merged here after confirmation. `template_action_plugin.cr`'s old
`FOR_ITEMS_METHOD` regex textually stripped `.items()` out of every
`{% for %}` tag and relied on Crinja's own bare `{% for k, v in dict %}`
already yielding (key, value) pairs - a workaround from before the
vendored crinja fork had a real `.items()` method on Hash values. That
stripping was silently WRONG for `.items() | sort` (`jtyr.nsswitch`'s
own `nsswitch.conf.j2`: `{% for key, val in nsswitch_config.items() |
sort %}`) - it sorted the raw dict instead of its item tuples. Fixed by
simply leaving `.items()` alone (removing the regex and its `.gsub`
call) since the fork now evaluates it for real
(`lib/crinja/src/runtime/python_hash_methods.cr`).

Confirmed live (podman/Debian 12) against both roles named in the
"Ansible's lazy dict-templating" open gap below as the original
motivating cases:

- `jtyr.nsswitch` (`.items() | sort`, the shape the old stripping
  workaround got wrong): rendered `/etc/nsswitch.conf` byte-for-byte
  identical to real `ansible-playbook`.
- `jtyr.motd` (`.items()` alone, no `| sort`): rendered `/etc/motd`
  structurally identical (same lines, spacing, ordering) - the one
  difference (`Virtual: YES` vs `Virtual: NO`) traced to an unrelated,
  pre-existing gap, now tracked separately above ("Podman-guest
  virtualization facts not detected").

Full spec suite (2495 examples) and `ameba` clean.

---

## Round 302 (confirming round 301's three fixes, 0.9.736 -> 0.9.737)

Live confirmation pass against round 301's three fixes below (podman
containers with real systemd, one engine per container, roles
re-fetched fresh from Galaxy) - 2 of 3 held up; the third was actually
a regression, found and corrected here.

1. **`kamaln7.swapfile` post-render specials**: confirmed correct.
   Both engines produce the identical `fallocate -l 512MB /swapfile`
   command and fail identically on a container's overlayfs
   (`Operation not supported`, an environment limitation, not an
   engine difference) - `ok=1 changed=0 failed=1` on both.

2. **`json_query` filter**: confirmed correct in isolation against real
   Ansible's own JMESPath output on matching/non-matching queries.

3. **`apt`/`package` implicit cache-update retry: was a regression, not
   a fix.** 0.9.736's gate fired on ANY `E: Unable to locate package`,
   but real Ansible's `apt.py get_cache()` only retries when
   `apt.Cache()` itself raises a `SystemError` mentioning
   `/var/lib/apt/lists/` - a corrupt/unparseable on-disk index, not a
   plain "no candidate for this name" miss on an otherwise-valid
   (even if empty) cache. Confirmed by reading `apt.py` directly and
   reproducing live: `package: {name: w3m, state: present}` against a
   genuinely empty `/var/lib/apt/lists/` - real `ansible-playbook`
   fails outright (`"No package matching 'w3m' is available"`,
   `failed=1`), while 0.9.736 silently installed it instead. Reproduced
   a second time via `buluma.httpd`'s `apache2` install on the same
   condition: real Ansible fails at that exact task (`ok=10 skipped=10
   failed=1`); 0.9.736 ran the whole role to completion. Fixed by
   re-gating `apt_corrupt_lists?` on the actual corrupt-lists signal -
   confirmed by corrupting a downloaded `.lz4` index file and
   reproducing python-apt's exact `SystemError` text via both
   `apt.Cache()` directly and `apt-get install`'s own stderr: `E: The
   package lists or status file could not be parsed or opened.`
   Re-verified live post-fix: the same `w3m`/`buluma.httpd` scenarios
   now fail identically to real Ansible on a plain empty cache, and
   still retry-and-attempt-recovery on genuinely corrupt lists (matching
   real Ansible's own outcome there too, which also fails when a plain
   `apt-get update` can't actually fix already-"Hit" corrupt content).

**Bonus finding, unrelated to round 301**: testing `itigoag.packages`
(which pipes `package_facts:`'s `ansible_facts.packages` through
`json_query`) surfaced that `finish_single_task` treated EVERY
`ansible_facts`-returning module (not just `set_fact`) with set_fact's
own high variable precedence - a play-level `vars: packages: {...}`
was silently clobbered by `package_facts:`'s same-named fact. Real
Ansible's "host facts" precedence tier sits below play vars; only
"set_facts / registered vars" sits above task vars. Fixed by splitting
`@facts` (full store, backs `ansible_facts.*` unconditionally) from a
new `@set_facts` (the subset actually written by `set_fact`, which
alone gets the old high-tier treatment) - `base_context_a_for` now
fills in ordinary gathered facts at the low tier (`||=`, losing to play
vars/host vars/registered vars) while `base_context_b_for` keeps
applying only `@set_facts` unconditionally at the high tier. `meta:
clear_facts` clears both stores together (confirmed via the pre-
existing `cli_spec.cr` cross-host hostvars spec that real Ansible's
clear_facts drops a plain set_fact value too, not just gathered facts).
Regression spec: `cli_spec.cr`'s "keeps a play var winning over an
ordinary fact-gathering module's same-name fact" against the new
`testing/test-fact-precedence-quick.yml` fixture.

---

## Round 301 (clearing three round-300 open gaps, 0.9.735 -> 0.9.736)

Not a benchmark round - a fix pass against the three open gaps the
round 300 campaign documented above. Each fix has its own regression
spec; none were re-verified against a live host (no provisioning for
this pass), so the original round-300 findings remain the live
evidence.

1. **`apt`/`package` implicit cache-update retry on an install-miss**
   (round 312's `Unable to locate package w3m` finding): new shared
   helper `apt_install_with_implicit_cache_retry` in the
   `apt_lock_retry` module wraps every named-package install call site
   in both `apt.cr` (present + latest) and `package.cr`'s own apt
   dispatch, gated on `E: Unable to locate package` in stderr.
   **Corrected in round 302 (0.9.737)**: that gate was wrong - see the
   round 302 narrative above for the real signal and why this shipped
   as a regression, not a fix.

2. **`command`/`shell` free-form specials after a whole-command `{% if
   %}` block** (kamaln7.swapfile finding): `extract_command_special_
   params` is now also run POST-RENDER by the executor
   (`substitute_task_params`, all three task/handler call sites),
   matching real Ansible's render-first-then-parse ordering. Idempotent
   with the parse-time pass - a plain command's specials were already
   stripped at parse time, so the post-render pass only ever fires on
   shapes the parse pass missed.

3. **`json_query` (JMESPath) filter** (itigoag.packages finding): a
   real JMESPath subset engine (`src/krikri/jmespath.cr` - recursive-
   descent parser + projection-aware evaluator over JSON::Any, covering
   the spec grammar: field access, indices/slices, wildcards, flatten,
   filters, multi-selects, pipes, comparisons, `&expr` references and
   the common built-in functions). Registered as `json_query` in BOTH
   filter pipelines (Crinja's `jinja_filters.cr` and the hand-rolled
   `FilterEngine`), per the usual check-both-evaluators rule.

The fourth open gap - general lazy dict-templating - remains open
(the deferred-evaluation rewrite touching both evaluators is still
deliberately not attempted).


---

## Round 300 (120-role Kata campaign, first full local-only round, 0.9.734 -> 0.9.735)

First 120-role marathon run entirely on local Kata VMs instead of
Atlantic.net - one fresh pair per role, up to 4 pairs (8 VMs) run in
parallel on one 16-thread/16GB machine. Two infra-level findings before
any engine bug hunting was possible:

1. **The candidate-role exclusion list was built by scanning only lines
   55-1135 of this file** (the old two-column "Per-role status" table),
   missing every later round's table (round 191 onward, through line
   1859) - top-download-count roles overwhelmingly overlap with what
   prior rounds already tested via the same sourcing method, so 23 of
   the first 24 roles run turned out to be exact duplicates already
   marked clean/fixed. Caught mid-round from a batch of `arillso.*`
   "divergences" that were actually already-known-and-explained
   history; discarded that batch (rounds 2001-2024, one genuinely-new
   role - `ansible-network.network-engine`, clean - kept) and rebuilt
   the exclusion list from the WHOLE file before continuing.

2. **Kata guest VMs had zero internet egress** - `testing/kata/kata-
   host.sh`'s `net_up` gave each guest an address but no default route,
   and there was no host-side NAT rule for the `10.99.0.0/16` range.
   The base image's own apt cache (populated at build time, on the
   host's network) made package *metadata* lookups look like they
   worked, masking this for a while - but any task needing live network
   (an actual package download beyond the image's snapshot, `curl`,
   a GitHub API call) failed identically on both engines, just at
   different points in each engine's own bootstrap order, which looked
   exactly like a pile of real engine divergences until traced back to
   the missing route. Fixed: `net_up` now adds the default route
   BEFORE `ctr run` (kata-agent snapshots the netns's network state
   into the guest once, at boot - a route added after boot is invisible
   to the guest), paired with a host-side `iptables -t nat -A
   POSTROUTING -s 10.99.0.0/16 -o <iface> -j MASQUERADE` rule (not
   automated - `iptables` deliberately isn't in the harness's NOPASSWD
   sudoers list). See `testing/kata/README.md`'s own gotcha #8 and
   updated Prerequisites section.

With both fixed, 31 of 120 roles showed a real divergence (confirmed by
re-running all 31 fresh after the network fix - all 31 reproduced
identically, ruling out network flakiness as the explanation for any of
them). Triaged down to:

- **4 real krikri bugs found and fixed** (0.9.735): `ansible_system_
  vendor` fact entirely missing from `FactsGatherer` (DMI `sys_vendor`,
  found via `sbaerlocher.qemu-guest-agent`/`.ovirt-guest-agent`'s own
  `when: ansible_system_vendor == 'QEMU'`); the `environment` Jinja
  global (real Ansible's Templar always exposes `os.environ` as this
  name) was missing from BOTH independent template-rendering paths -
  `CrinjaRenderer` (the `{{ }}` task-param path) and the entirely
  separate `TemplateActionPlugin` (real `.j2` file rendering) - found
  via `GROG.debug-variable`'s own `{{ environment | to_nice_json }}`
  dump-everything idiom; `lookup('ansible.builtin.fileglob', ...,
  wantlist=True)` (the FUNCTION-call form of a lookup only the FILTER
  form - `map('fileglob')` - previously handled) was entirely
  unimplemented, falling to the "undefined" string fallback, and
  `"undefined" | length > 0` is true - found via `PowerDNS.pdns`'s own
  per-loop-item `when:` guard meant to skip a nonexistent OS-specific
  vars file, which always ran `include_vars:` anyway and failed instead
  of skipping; bare `omit` inside a `when:`/`assert:` comparison
  (`rhsm_username != omit`, the standard "was this optional param
  actually given" idiom) raised "'omit' is undefined" instead of
  resolving to the same `OMIT_SENTINEL` `{{ omit }}` template
  interpolation already special-cased - found via `oasis_roles.rhsm`.
  All four re-verified CLEAN on fresh Kata pairs after the fix
  (`PowerDNS.pdns` improved substantially - 12 more tasks now run
  correctly - but hits a separate, deeper vendored-crinja-fork bug
  further into the same role; see the dict-templating open gap above).
- **2 new open gaps documented** (not fixed - see "Open gaps" above):
  the `command`/`shell` free-form `creates=` stripping breaks when the
  whole command is a `{% if %}...{% endif %}` block (`kamaln7.
  swapfile`); `json_query` (JMESPath) entirely unimplemented
  (`itigoag.packages`).
- **1 new shape of the existing "lazy dict-templating" gap** (see
  above): a single-variable `{% for k in dict %}` yielding `(key,
  value)` tuples instead of just keys, in the vendored crinja fork
  itself (`PowerDNS.pdns`, past the fileglob fix).
- **~24 confirmed NOT bugs**: `jborean93.win_openssh` (a Windows-only
  role run on Linux - same class as `arillso.chocolatey`, both engines
  correctly diverge because the role is inapplicable to this OS);
  `krzysztof-magosa.docker`/`sbaerlocher.domain-join` (real Ansible
  hard-fails at PARSE time on a module removed from a collection -
  krikri doesn't do that upfront validation and proceeds instead, the
  documented "strictness difference" class); `l3d.gitea`/`roles-
  ansible.gitea`/`haxorof.docker_ce` (blocked by `python3-apt` genuinely
  not being installable on this Debian trixie image snapshot -
  independent of the network fix, confirmed by re-testing with real
  internet - not a krikri defect); `stackhpc.drac`/`.os-ironic-state`
  (a `local_action:` task needing passwordless sudo on the CONTROLLER
  itself, which this harness's controller doesn't have - real Ansible
  fails on "sudo: a password is required" locally while krikri
  correctly reports the module unimplemented and skips); and the
  remaining "extra `ok`+1"/"runs further before failing" cluster,
  mostly explained by the two infra findings above once traced through
  individually.

Regression specs: `spec/unit/facts_gatherer_spec.cr` (system_vendor),
`spec/unit/crinja_renderer_spec.cr` (environment global),
`spec/unit/expression_evaluator_spec.cr` (fileglob lookup),
`spec/unit/conditional_evaluator_spec.cr` (omit sentinel). Full suite:
2458 examples, 0 failures.

---

## Round 199 (mrlesmithjr.rabbitmq warm-run delta, kata VM, 0.9.733 -> 0.9.734)

Closed the last long-standing open-gap item (`community.rabbitmq` warm
`changed=2` where real reports 0) on a local kata VM - a real kernel +
systemd is all rabbitmq needs; no cloud pair required. The live host
settled it in one pass, and the "diff what the module actually WROTE,
not the recap counts" lesson was right again: the detection hardening
in 0.9.631 had worked, but three writing-side bugs remained.

1. **rabbitmq_plugin's changed flag was hardcoded true** - the
   nothing-to-do fallthrough returned `changed: true` regardless of
   detection. Detection was fine; the flag never consulted it.
2. **Tags were written as a JSON array** (`set_user_tags user
   ["administrator"]`), which rabbitmqctl stores as the LITERAL tag
   `[administrator]` (list_users shows `[[administrator]]`). The real
   module passes each tag as its own argv. The tag therefore never
   converged and every warm pass rewrote it - that was the "one user
   item".
3. **set_permissions was applied unconditionally** - the real module
   queries `list_user_permissions` and compares (dict equality) before
   acting; and its argspec defaults are `^$`, not `.*`.

Also aligned with the real module: `list -E -m` with exact-line
membership (bare names, one per line) instead of a `list -e`
whole-text grep, and the real disable-others behavior for
state=enabled/new_only=false. Verified live: reset state, cold
changed=2 / warm changed=0 twice, real `ansible-playbook` warm
changed=0 on the same host, and the written state confirmed via
`list -E -m` / `list_users` / `list_user_permissions` (proper single-
bracket tag, exact privs). No unit spec by design - the decision logic
is remote-command-shaped; verified live per the no-real-mutation
convention.

Kata VM timings (not a provisioned pair): py 8.2/4.9s, cr 5.5/2.3s
cold/warm.

Follow-on: `compat/playbooks/44-rabbitmq.yml` adds this module pair to
the compat harness (it had no playbook because the modules didn't exist
when the harness's coverage was built out) - plugin enable/disable and
user create/delete, each with an idempotent rerun, against a throwaway
rabbitmq node started inside the container as the package's `rabbitmq`
user. Both engines rc=0 with byte-identical mid-run and final `/work`
state snapshots.

---

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
  "meaningful fraction" bar is not met.** Per the rule, the full
  native-typing rewrite (deferred evaluation + type preservation
  through the whole vars pipeline, touching both evaluators) remains
  NOT done, and shouldn't be picked up without new data changing that
  verdict.

  **The narrow one-off this entry named as the alternative is done
  (0.9.698).** `ExpressionEvaluator#type_sensitive_comparison?`
  (`expression_evaluator.cr`) special-cases exactly `robertdebock.java`/
  `buluma.java`'s own shape - a `==`/`!=`/`<`/`>`/`<=`/`>=` comparison
  where at least one operand is a bare variable whose own stored value
  is a pure, single-level `{{ other_var }}` indirection (no filters, no
  dotted/bracket access) - and routes it to `ComparisonEvaluator`
  (which already had the necessary type-preserving reparse, `when:
  java_version == 8` already worked correctly before this fix) instead
  of Crinja, whose otherwise-correct string-typed comparison was
  exactly what disagreed with real Ansible's native-typed one. Verified
  live: `{{ java_version == 8 }}` now renders `True`, matching
  ansible-core 2.19; the protected `buluma.bind`
  `bind_python_version == '3'` idiom (a DIFFERENT indirection whose
  underlying value is a genuinely quoted string, not an int) still
  renders `True` too, unregressed. NOT a general fix - `type_debug`,
  `in`-membership, and a string-literal comparison against a
  numerically-indirected variable (`ind == '3'`, which
  `ComparisonEvaluator`'s own pre-existing loose numeric-string
  coercion still gets wrong the same way it already did before this
  session) are untouched; only the documented `X == <int-literal>`/
  `X != <int-literal>` shape is covered.

- **`get_url`/`lookup('url', ...)` can't complete a TLS handshake
  against `subgit.com`.** Found in round 187's 60-role marathon
  (`andrewrothstein.subgit` downloading
  `https://subgit.com/download/subgit-3.3.18.zip`) against the server's
  OpenSSL 1.0.2u at the time. Re-investigated 2026-09 (session
  `session_01Jo7RSGKYc2M9GgsC7na46p`): the theory that this was purely
  "old OpenSSL on the server" no longer holds - the server has since
  moved behind a modern Let's Encrypt-issued cert (CN `tmatesoft.com`,
  a large SNI-shared multi-domain cert) and a bare
  `openssl s_client -connect subgit.com:443 -servername subgit.com`
  from this project's own dev host succeeds cleanly with default
  settings on OpenSSL 3.5.7 - yet the bug still reproduces identically
  (`SSL_shutdown: error:0A000197:SSL routines::shutdown while in init`,
  confirmed live via the built binary). `curl` also still succeeds
  against the same host/path. So the divergence is real and current,
  just not "legacy TLS": something in the ClientHello Crystal's
  `HTTP::Client`/`OpenSSL::SSL::Context::Client` constructs differs
  from what `openssl s_client`/`curl` (same system OpenSSL, same box)
  send, and the server rejects it with a handshake-failure alert.
  Toggled every relevant option Crystal's OpenSSL bindings expose
  (`LEGACY_SERVER_CONNECT`, `ALLOW_UNSAFE_LEGACY_RENEGOTIATION`,
  `NO_TLS_V1_3` to force TLS 1.2, `ciphers=` pinned to curl's own
  negotiated `ECDHE-RSA-AES256-GCM-SHA384`, `security_level = 0`) -
  none changed the outcome, ruling out protocol-version/cipher-list/
  renegotiation-policy as the cause and meaning this isn't fixable
  through the client-side knobs Crystal's stdlib exposes. Root-causing
  the actual ClientHello difference needs a packet-capture-level diff
  (`SSLKEYLOGFILE`/tshark) against `openssl s_client`'s own handshake,
  not attempted here - out of scope for an application-level fix, and
  more likely a genuine Crystal stdlib limitation than something to
  patch around in this codebase. Not fixed.

## Deliberate limits (decided, not defects)

Everything here is a decision someone already made, with the reasoning
attached. Nothing here is waiting on anyone. Do not re-litigate without
new evidence - and if new evidence turns up, move the entry to "Open
gaps" rather than arguing with the note in place.

### Init systems and package managers

- **`service:` on an upstart host** - detection covers systemd, OpenRC
  and SysV (0.9.727, real Ansible's own branches in its own precedence
  order). Upstart is *detected*, so such a host is never silently driven
  as SysV, but not implemented: its enable path writes an
  `/etc/init/<name>.override` whose contents depend on the initctl
  version, and no supported distro still ships it (Ubuntu 14.04, its
  last home, EOL 2019). Fails with a clear "not supported" instead of
  guessing at semantics that cannot be verified live. Revisit only if a
  real round turns up an upstart host.
- **`service_facts:` upstart / chkconfig / OpenRC scans** - systemd and
  SysV (`service --status-all`) are implemented and merged real
  Ansible's way (0.9.728); the other three branches are not. On such a
  host the systemd scan still runs, and an empty result is correctly
  reported *skipped* rather than as an empty `ansible_facts.services`
  dict.
- **`package:` backends beyond apt/dnf/yum** - detection uses the same
  path table and priority as `ansible_pkg_mgr` (0.9.728), so the module
  and the fact a role gates on cannot disagree, but only apt/dnf/yum
  have backends. zypper/pacman/apk/pkgng fail by name ("package manager
  'pacman' is not supported by this engine"). Confirmed live on Arch.
  Same scope question as the zypper entry below.
  - apk is doubly out of reach: Alpine is musl and this engine's plugin
    binaries are glibc-linked, so they cannot execute there at all - the
    upload fails before any module runs. A musl plugin build is the
    prerequisite, not an apk backend.

### Arbitrary Python

- **Role-private custom modules** (a role's own `library/*.py`, outside the
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
  caller sees. Seen live repeatedly, most recently linux-system-roles'
  own `sr_fingerprint` tasks (crypto_policies, journald), where both
  engines otherwise agree.
- **Third-party COLLECTION modules and filters, same cut** (round 199,
  the bodsch.* author's own `bodsch.core`/`bodsch.systemd` collections -
  `bodsch.core.check_mode`, `.facts`, `.type` filter, `.upgrade` filter,
  `bodsch.systemd.journalctl`): real Ansible runs these as ordinary
  Python. A MODULE reference reports "unavailable modules" and skips the
  task; a FILTER reference fails with real Ansible's own "No filter
  named 'x'." (0.9.726) rather than silently passing the operand through
  un-filtered. The cut is unchanged - these roles still diverge by
  design, the failure is just named now. Confirmed against bodsch.
  chrony/monitoring_plugins/redis/monit/logrotate/tomcat/forgejo on
  Ubuntu 22.04; every one calls at least one of these for real logic, so
  this author's roles will keep diverging. Not worth re-testing more of
  them expecting a different outcome.
- **Unimplemented collection modules**: `community.general.
  redhat_subscription` (linux-system-roles.rhc),
  `community.rabbitmq.rabbitmq_plugin/_user` (mrlesmithjr.rabbitmq) -
  rc=4 "unavailable modules" vs real ansible rc=0. Same class as the
  community.crypto notes below.

### Fact caching

- **Only the `jsonfile` backend** (0.9.696, `src/krikri/fact_cache.cr`)
  - by far the most common real-world choice, and the only one worth a
  from-scratch implementation without a client library to lean on.
  `redis`/`memcached` would need real client libraries this project
  doesn't carry; the built-in `memory` backend needs no support at all
  (this engine's in-run `@facts` store already IS that). Revisit only if
  a real role is found relying on a non-jsonfile backend.

### Templating

- **A tuple-bearing value stored in a var, then `| string`'d later,
  renders as a bracketed list instead of a parenthesized tuple**
  (round 306, 0.9.741). Real Ansible's native-types finalization
  converts a Python tuple to a list at every rendered-output position
  EXCEPT when `| string` applies Python's own `str()` first - krikri's
  crinja fork now replicates that exception for the inline case
  (`{{ d1 | dictsort | string }}` correctly renders parens), but a
  tuple crossing INTO a var first (`t1: "{{ (1, 2) }}"`) loses its
  tuple-ness the moment it's stored, since krikri's vars world is JSON
  (no tuple type) - so `{{ t1 | string }}` later gives `[1, 2]` where
  real Ansible gives `(1, 2)`. Recovering that would mean carrying a
  real tuple type through the whole vars pipeline - the same deferred-
  evaluation architecture the general lazy-dict-templating gap's fix
  deliberately avoided - for a shape nothing in the role corpus hits
  (`| string` on a tuple-bearing var read back out of storage). Revisit
  only if a real role is found relying on it.

### Cosmetic differences (both engines fail; only the wording differs)

These change no outcome and no recap. Listed so they aren't re-reported
as bugs, not because anyone intends to fix them.

- **`RemovedActionError`'s message text** is only approximate, and this
  is permanent. Round 307 (`Stouts.django`): the wording was refreshed
  in 0.9.694 to ansible-core 2.17.14's phrasing, but "correct" is a
  moving target across minor releases (this project has hit both 2.17.14
  and 2.19.4 on different hosts), there is no version-targeting concept
  anywhere in this engine to hang a version-aware table off, and
  rc=1/detection is identical either way.
- **`include_vars:` with a failing templated path** (gantsign.oh-my-zsh,
  harness-limited): when the path template can't resolve, this engine
  reports `include_vars: file not found: undefined` where real ansible
  fails a LATER task with "'users' is undefined". Both fail the role;
  the failure point and message differ.
- **`service: use=systemd` forced on a host where systemd is NOT PID 1**:
  real Ansible reports "Service is in unknown state", this engine
  surfaces systemctl's own "System has not been booted with systemd as
  init system (PID 1)". Same outcome, same recap - and only reachable
  via a deliberate `use:` override that contradicts the host.

### Everything else

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
  `s3_object`, IAM, security groups, etc.) and `azure_rm_*` - not
  implemented, not planned. These are a fundamentally different kind of
  module (HTTP calls to a cloud API from the controller, needing real
  request signing/auth, not shell commands run on a managed target) - a
  real API client built from scratch, not "another module that shells out
  to a CLI tool" like everything implemented so far. Revisit only if a
  specific real-world need justifies the investment. (The inventory
  half of this - YAML-defined cloud inventory *plugins* - landed in
  0.9.731, see below.)
- YAML-defined inventory plugins (`plugin:` sources): `host_list`,
  `ini`, `yaml`, `constructed` and `amazon.aws.aws_ec2` are implemented
  (0.9.731, via `src/krikri/inventory_plugins.cr`; aws_ec2 talks to the
  real EC2 API with SigV4 through the vendored `awscr-signer` shard -
  no `aws` CLI or boto3 needed, credentials from the standard
  `AWS_*` environment variables). Deliberate approximations within
  that: the default `hostnames` order is `ip-address`,
  `private-ip-address`, `instance-id` (real Ansible's default is a
  smarter public-DNS-aware chain); constructed `filters` are
  AND-combined `key=value` / bare-key / `*` / `!`-negation entries,
  not real Ansible's richer condition syntax; keyed_groups with a dict
  value make one group per key; a non-empty group-name prefix defeats
  `leading_separator: false` (matching the real plugin's intent, not
  its exact edge-case output). Other collection inventory plugins
  (azure, gcp, openstack, ...) are still not implemented and follow
  the same rule as the cloud modules above.
- More of the same "genuinely unimplemented plugin, referenced only in
  a task this platform never actually reaches" class as
  `community.general.apache2_module` (a genuine core-adjacent gap until
  it was implemented in 0.9.733, verified live against a real
  Debian-family host - see git log), found sweeping 60 new
  roles (rounds 177-179) - same root cause each time (this engine's
  eager parse-time module check counts a reference regardless of a
  gating `when:`, matching real Ansible's own behavior, but the local
  comparison side happens to have the collection installed and never
  hits the check): `zypper` (`weareinteractive.docker` - SUSE-only, out
  of this project's Ubuntu/RHEL scope, not planned),
  `community.docker.docker_compose_v2` (`mrlesmithjr.blocky`),
  `community.general.clustering.consul.consul_acl`
  (`mrlesmithjr.consul` - also demonstrates the "WHICH TASKS RUN
  differs" side of this same gap: real Ansible refuses at parse time
  with zero tasks run, this engine runs the whole play first, ~80s of
  real work, before reporting the same rc=4 - already covered by the
  role-private-custom-modules entry above, not distinct).
- The legacy free-form `action: "<templated module name> key=val ..."`
  task syntax (module name and args packed into one string, with the
  module name itself resolved from a runtime variable like `{{
  ansible_pkg_mgr }}`) isn't parsed at all - this engine treats the
  literal YAML key `action` as the module name itself, reporting
  `unavailable modules: action`. Pre-2.4-era idiom, found in
  `weareinteractive.users_oh_my_zsh` (round 178). Not implemented -
  real-world usage of this exact form is rare and every modern role
  uses `ansible.builtin.<module>:` directly instead.
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
