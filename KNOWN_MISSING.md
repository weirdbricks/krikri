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

**Currently at `0.9.860`.** Vendored `crinja` fork now at tag
`crystal-play-0.9.29` (see `shard.yml`).

---

## Unresolvable module/action names: real Ansible's play-load hard-stop, with the graceful-skip boundary drawn by collection (0.9.860)

Closes most of the round71000 open gap (`Aplyca.EC2Describe`,
`bodsch.k0s`). Real ansible-playbook refuses to even start the play the
moment ANY task's module name won't resolve - `[ERROR]: couldn't
resolve module/action '...'`, rc=4, no PLAY RECAP, before Gathering
Facts. This engine's per-task graceful skip (the whole point for a
module simply not yet implemented HERE) couldn't tell that apart from
a module that doesn't exist in real Ansible at all, so it kept
executing every other task - `bodsch.k0s` then failed downstream on an
unrelated "No filter named 'bodsch'" conditional that masked the real
divergence shape entirely. Same bug class as the `ansible.builtin.`
`include:` tombstone (`RemovedActionError`, round 162, 0.9.518), now
generalized.

The distinguishing signal was drawn from live verification against
real ansible-core 2.19.4 on this machine, which settled two things the
old notes were uncertain about: the resolution check is a
playbook-LOAD check there (a `when:`-gated, never-reached offending
task still aborts the whole run - so the check belongs at parse time,
not in the lazy per-task path), and a real-but-unimplemented builtin
(`ansible.builtin.sysvinit`) resolves fine on real Ansible and must
stay a graceful skip here.

`UnresolvedModuleError` (new, same bypass-rescue mechanism as
`RemovedActionError`, raised from `parse_task` and hard-stopping with
real Ansible's exact message and rc=4) fires for exactly two shapes:

1. a name in `REMOVED_MODULE_TOMBSTONES` - `ec2_remote_facts` in its
   bare, `ansible.builtin.`/`ansible.legacy.`- and
   `amazon.aws.`-qualified spellings (real amazon.aws tombstoned the
   FQCN too, verified). Deliberately minimal; widening = adding
   entries, only names unresolvable on EVERY real controller qualify.
2. a collection-qualified name (3+ segments) whose
   `namespace.collection` the engine has zero AVAILABLE_PLUGINS
   modules from (`IMPLEMENTED_COLLECTIONS`, derived from
   AVAILABLE_PLUGINS so the two lists can't drift) - i.e. a collection
   never installed, which real Ansible also fails to resolve.

Everything else keeps the graceful per-task unavailable_module skip -
most importantly an unimplemented module inside a RECOGNIZED
collection, which is far more likely not-yet-ported-here than
nonexistent. The residual gap stays open: a module that genuinely
doesn't exist inside a recognized collection
(`community.general.doesnotexist_xyz`) still skips where real Ansible
hard-stops, indistinguishable without a full upstream module registry.

---

## Quoted-string-literal operand in `or`/`and` short-circuit returned as raw string, not re-evaluated (0.9.859)

Closes the round72000 open gap (`crazikPL.logging`): `when:
(("'rsyslog_elks' in group_names") or rsyslog_use_remote)` - the inner
operand is a legacy-style double-quoted STRING LITERAL (the old-docs
anti-pattern) whose own content merely happens to read like an `in`
test. Real Python's `or` short-circuits to that non-empty (truthy)
string unchanged - never evaluating `rsyslog_use_remote` at all - and
ansible-core 2.19's strict-conditional check then rejects the whole
`when:` ("Conditional result (True) was derived from value of type
'str'"). The hand-rolled evaluator's short-circuit operator instead
re-parsed the literal's own TEXT as live code both when deciding
truthiness (so with 'rsyslog_elks' absent from group_names the literal
read as falsy and the chain fell through to `rsyslog_use_remote`) and
when re-evaluating the deciding operand under strict (which then
returned a clean Bool and never raised) - the same "recursive
templating" bug class `CLAUDE.md` flags as recurring in both
evaluators. The fix is scoped to `evaluate_short_circuit_operator`: an
operand that IS a quoted string literal (parens-unwrapped, escape-
aware - `"a" in x` is still an expression, not a literal) gets Python
string truthiness (`bool(<content>)`, non-empty = truthy) in the
non-strict pass, and a deciding literal operand returns its raw string
value, which the existing strict conditional type check then rejects
with the established message shape. Variables that merely RESOLVE to
strings are untouched (the ANXS.postgresql `and`-chain case keeps
passing), nested short-circuits keep strict=False for intermediate
operands, `ANSIBLE_ALLOW_BROKEN_CONDITIONALS` relaxes to the literal's
own truthiness as real Ansible does, and a bare fully-quoted `when:`
condition (no or/and) keeps its existing path. Regression specs cover
both group-membership outcomes, the undefined second operand (short-
circuit never reaches it), the `ANSIBLE_ALLOW_BROKEN_CONDITIONALS`
relaxation, the falsy-first-operand `and` case, and normal conditionals.

---

## Undefined-left-operand `in` a plain string now hard-errors with real Ansible's TypeError message shape (0.9.858)

Closes the round71000 open gap (`asg1612.gluster` requeue): `when:
"node_1 in hostvars[inventory_hostname]['ansible_nodename']"` with
`node_1` never defined. Real Jinja2 evaluates `x in y` as
`y.__contains__(x)` with the LEFT operand evaluated first, and a plain
Python `str.__contains__` requires its argument to itself be a `str` -
an Undefined marker isn't one (Jinja2 defers the undefined raise to
force time, so the marker itself reaches `__contains__`), so real
Ansible hard-fails the task with Python's own TypeError text
("`'in <string>' requires string as left operand, not
UndefinedMarker`"). The hand-rolled `when:` evaluator's `evaluate_in`
already had the right failure (a strict undefined raise, added after
the round71000 bullet was written) but the wrong message shape
("'node_1' is undefined" surfaced first from the LHS lookup); the fix
swaps in the exact TypeError-shaped message for the undefined-LHS +
plain-STRING-container case only, preserving left-to-right evaluation
order. Deliberately NOT widened: the undefined-in-*list* path (real
Python `list.__contains__` compares by equality and returns False for
an Undefined without raising) and every `raise_undefined=false`
(lenient: changed_when:/failed_when:) caller keep their existing
behavior untouched, per the original bullet's own over-tightening
warning. The Crinja side remains open (narrowed bullet below): under
strict templating it already hard-errors the render, but with Crinja's
own "`node_1` is undefined" message rather than the TypeError shape,
and under the default lenient mode it silently coerces the marker to
`""` (a substring of everything) and returns TRUE - a proper fix means
touching the vendored `crinja` fork's `Operator.contains?`
(tag-pinned in `shard.yml`), not done this round. Regression specs
cover the raise (message shape), the unchanged list path, the
unchanged lenient path, and the defined-LHS string case.

---

## `ansible.posix.acl` implemented: full `getfacl`/`setfacl` parity incl. the `--test` idempotency check (0.9.857)

Closes the round71000 open gap (`claranet.acl`): a task using
`ansible.posix.acl` was previously dropped as "Plugin not available" -
there was no plugin at all. New `plugins/acl.cr` replicates the real
module's full parameter surface (`path`/`name`, `entry:` shorthand vs
`entity:`/`etype:`/`permissions:`, `state: query|present|absent`,
`default:` directory ACLs, `recursive:`/`recurse:`, `follow:`,
`recalculate_mask:`, `use_nfsv4_acls:`), its exact validation error
messages, and its command construction, whose flag ordering (including
`-d` inserted right after the binary name) is ported field-for-field
from `acl.py`. The one subtle piece - real Ansible's idempotency check
- is `setfacl --test`: the would-be result lines end in `*,*` only
when nothing would change, so changed:true is reported exactly when
the tested entry list differs. All shapes were cross-checked against
actual setfacl/getfacl 2.3.2 output (recursive, default, and
already-applied cases), and the pure command/parsing half lives in
`src/krikri/plugin_helpers/acl_command.cr` under unit spec (the spec
sandbox has no ACL-capable filesystem, same split as ufw/iptables).

---

## `is defined` on a dynamically-keyed `hostvars[...]` bracket lookup fixed: strict misses now defer their raise to force time (0.9.856)

Closes the round72000 open gap (`mullholland.motd`): a strict-mode
`HostVarsVars` attribute/subscript miss used to raise a plain
`Crinja::RuntimeError` immediately at lookup time, so `is defined` -
the one construct that is supposed to never fail for a missing
attribute - hard-failed the whole render instead of taking the false
branch. Fixed by returning a `StrictMissingAttribute` (a
`Crinja::Undefined` subclass) from the miss instead of raising there;
it only raises real Ansible's own `HostVarsVars` message when actually
forced (`to_s`/`==`/`<=>`), so `is defined`, `| default(...)`, and
`{% if %}` truthiness checks all see a genuine Undefined and take the
false/fallback path, while a plain `{{ hostvars[h].typo }}` print still
fails the task with the exact same message as before. New specs cover
the `is defined` false case, `| default()`, bare `{% if %}` truthiness,
and the still-true `is defined` case on a present key.

---

## `f500.ufw`'s warm-rerun SSH lockout root-caused: the control-socket directory was pid-scoped, so warm reruns dialed fresh where real Ansible reuses its master (0.9.855)

Round 72000's highest-priority "needs a closer look" item - the krikri-side
Atlantic host going completely unreachable (every task failing with
`ssh: connect ... port 22: Connection timed out`) on the WARM rerun
immediately after the cold run's `ufw default deny incoming` + `ufw
--force enable` (no allow rules) - reproduced live on a fresh Atlantic
pair and root-caused. The lockout itself is the ROLE's real effect and
hits BOTH engines identically: with the cold run's master socket moved
away, real ansible-playbook's own next run is unreachable exactly the
same way (`ok=0 unreachable=1`, fresh dial, `Connection timed out`). The
divergence was never the ufw command construction - it was SSH
CONNECTION REUSE across processes. Real Ansible's ssh connection plugin
uses one stable, pid-independent control-socket directory
(`~/.ansible/cp/<hash>`) with `ControlPersist`, so a second
ansible-playbook invocation minutes after the first rides the first
run's still-alive multiplexed master and never needs a new incoming
connection. krikri's control dir embedded the process pid
(`/tmp/.krikri-playbook-ssh-<pid>/`, 0.9.770's per-process isolation for
the concurrent-batch mux race), so every new krikri process - the warm
rerun included - had to dial fresh, and the ufw firewall blocked it:
`ok=0 failed=2`, the exact round-72000 warm recap, reproduced twice.

Fixed by making the control-socket directory stable across processes
(`/tmp/.krikri-playbook-ssh/`, mirroring real Ansible's own model) while
keeping the per-(user, host, port) socket names - concurrent processes
on different hosts never share a socket, and concurrent clients on the
same host's mux are exactly what real Ansible does and what the ssh mux
protocol is designed for. Verified live on a fresh Atlantic pair with
the fixed build: warm rerun now succeeds via the persisted master
(`ok=4 changed=0`, byte-identical to real Ansible's own warm recap),
plus a 5-iteration two-host concurrency stress (and same-host concurrent
pairs) with zero corruption and zero spurious UNREACHABLEs. Regression
spec pins the pid-independence (`spec/unit/ssh_manager_timeout_spec.cr`).
Two side observations from the same investigation: the 0.9.770-era
per-process dirs were never cleaned up (thousands of stale
`/tmp/.krikri-playbook-ssh-<pid>/` dirs on the control machine - the
stable dir ends that leak; old ones are safe to `rm`); and a
controller-only plugin's transport failure (ssh exit 255 - e.g. this
same lockout hitting `fetch:`'s own existence check) is misreported as
"the remote file does not exist" instead of an unreachable - a small
error-classification gap, not chased further this round. Note the
harness implication: a round that runs f500.ufw (or any host-locking
role) will now keep the krikri host reachable only within
`ControlPersist`'s window, same as real Ansible - both engines'
subsequent runs beyond that window fail identically, which is the
role's own doing, not a divergence.

---

## `Frzk.chrony`'s "task-level vars: leaking" root-caused: the lookup form's no-`paths:` first_found default searched vars/, which real Ansible never does (0.9.853)

Round 72000's "needs a closer look" `Frzk.chrony` divergence
(`include_tasks: "{{ lookup('first_found', findme) }}"` hard-failing
"Included tasks file must be a YAML list: `.../vars/Debian.yml`") was
NOT task-level `vars:` leaking across sibling tasks at all - the
sibling's `findme` was a red herring; the failing task's own `findme`
was correctly in scope the whole time. Root cause: the lookup form's
no-`paths:` default search stack (files/, tasks/, templates/, vars/,
".") included `vars`, so `first_found`'s candidate file `Debian.yml`
(one of the OS-family candidates) matched the role's own
`vars/Debian.yml` - a VARS mapping, not a task list - which the
include then tried to run as tasks. The sibling `findme` shape only
mattered because task 1's `paths: [vars]` file happened to exist with
the same basename; a role with no vars file match would have diverged
differently or not at all.

Probed live against ansible-core 2.19.4 (this project's benchmark
baseline) with a minimal one-candidate-per-probe role: the lookup
form's no-`paths:` search stack is the role's ROOT directory first,
then the role's own `tasks/` dir, then the play basedir (last resort) -
and NOT `files/`, `templates/`, or `vars/` at all (that per-subdir
behavior belongs to the `with_first_found:` KEYWORD form, which picks
its subdir from the task's action name). Two existing
`first_found`-default specs encoded the old wrong premise - the
"geerlingguy.docker idiom with no paths:" spec (geerlingguy.docker
actually specifies `paths: ['vars']`) and a "files/ has priority" spec
whose live check contradicts the probe - both rewritten to the probed
reality, plus new specs for role-root priority and the play-basedir
fallback. Verified live: the full role now reaches and fails at exactly
the same task real Ansible does (local non-root `Permission denied` on
`/etc/chrony`, both engines identical).

---

## Round 72000: 400-role batch (2x Atlantic.net capacity), 10 real bugs (0.9.845-0.9.854)

First batch run entirely Atlantic-only (no Kata, per round 71000's
undiagnosed Kata cgroup boot-failure finding) at 24 hosts/12 pairs -
the account's server limit is 25, not 40, so this stayed under that
rather than doubling host count outright. 400 never-before-tested
roles (leftover candidates from round 71000's own Galaxy top-download
pull, deduped against the now-2114-role table). Final: 263 CLEAN, 57
DIVERGENT, 75 GALAXY_MISSING, 5 TF_APPLY_FAILED (transient Terraform
provisioning failures, unrelated slots/times - requeued and all 5 came
back CLEAN, confirming it wasn't systemic).

All 57 DIVERGENT roles were individually triaged this round (not just
a sample). 10 real bugs found, fixed, and confirmed via live reruns on
fresh Atlantic hosts: `with_subelements:` on `include_tasks:` rejected
outright; `role_path` unresolved inside a static `import_tasks:` path;
`getent`'s `fail_key: false` storing an empty array instead of a real
null; a bracketed multi-item `groups:` list passed raw into
`useradd -G`; `notify:` on an `import_tasks:` line not propagating to
the tasks it inlines; a templated `ignore_errors:` always defaulting
to `false` instead of `true`; `with_nested:` not re-expanding a
templated source list at runtime; Python `.lower()`/`.upper()`
method-call syntax unsupported in `{{ }}` expressions; Crinja losing
string integer-subscript support (`mystr[0]`) entirely on modern
Crystal; and malformed Jinja2 (`{{ var }` with a missing brace)
silently tolerated instead of hard-erroring like real Jinja2's parser.
Each writeup below names the confirming role(s).

Of the rest: most (~30) trace to already-documented scope cuts,
harness/environment gaps (missing Python libs on the harness's real-
ansible-core side, stale Ubuntu-archive-mirror package versions,
Windows-only roles, real Ansible's own module/collection version
mismatches), or a genuinely-unrelated both-fail (missing binary,
missing role dependency). Those aren't re-litigated individually here
- see the per-role rows in `ROLES_TESTED.md`'s round-72000 section for
each one's specific reason. 2 new **open gaps** are documented below
(real, reproducible, root-caused, but not fixed this round - each
names the exact mechanism so another pass can implement it without
re-deriving the diagnosis): a quoted-string re-evaluated as live code;
and `is defined` on a dynamically-keyed `hostvars[...]` lookup raising
instead of returning false. (Two other candidates from the original
triage turned out not to be open gaps after all: `ansible_python_
version` supposedly never populated was a misdiagnosis on
re-investigation - the fact was fine, a Crinja string-indexing
regression was the real cause - and the malformed-Jinja gap got fixed
this round instead of staying open; see the fixes below.) A handful of
roles (`f500.ufw`'s possible SSH-lockout-after-
`ufw enable`, `Frzk.chrony`'s task-level `vars:` leaking across
sibling tasks, the apt-404-on-krikri-host-only pattern seen on 3
different roles) are flagged as **needs a closer look** - real,
reproducible divergences whose root cause isn't fully pinned down yet;
they are tracked in the Open gaps section's own "Needs a closer look"
subsection (where their full writeups live), not in this round's
narrative. (`Frzk.chrony` and `f500.ufw` have since been root-caused
and fixed - the chrony divergence wasn't vars:-leaking at all, and the
ufw lockout was krikri's pid-scoped SSH control-socket directory, not
the ufw commands; see their own sections above.)

- **`f5devcentral.bigiq_move_app_dashboard`/`.bigiq_pinning_deploy_
  objects`**: both hard-failed at parse time (`'with_subelements' is
  not a valid attribute for a TaskInclude`, rc=4, no recap) on a
  completely standard `include_tasks:` looped over
  `with_subelements: [apps, pin]`, where real ansible-core runs it
  fine. `TASK_INCLUDE_VALID_KEYWORDS` had every other with_*
  loop-lookup variant (`with_items`, `with_fileglob`,
  `with_first_found`, `with_dict`, `with_nested`, `with_sequence`,
  `with_indexed_items`, `with_file`) but not this one - a plain
  omission, not a deliberate scope cut. Fixed by adding it to the
  allowlist and adding actual `with_subelements:` parsing to
  `parse_include_tasks` (previously only the generic per-task parser
  handled it, so `item` would have stayed unbound throughout the
  included file even past the allowlist fix - the same bug class
  `with_first_found`'s own earlier fix addressed). Regression spec
  added (`spec/unit/playbook_parser_spec.cr`); live-reverified on
  fresh Atlantic hosts.

- **`infOpen.openjdk-jre`**: hard-failed at parse time
  (`StaticImportUndefinedError`: `'role_path' is undefined`, rc=4, no
  recap) on `import_tasks: "{{ role_path }}/tasks/manage_variables.
  yml"` - a real, if unusual, pattern for a role to make its own
  static-import target independent of wherever it's vendored under.
  `known_vars` (what a static import's own path template may reference
  at parse time) never included `role_path` at all, even though it's
  just this role's own directory and trivially known as soon as
  parsing begins - real ansible-core resolves it immediately and moves
  on (`ok=7`). Fixed by adding `role_path` to `known_vars` in
  `role_loader.cr`, right next to where `role_dir` (the same absolute
  path) was already available for the role's own defaults/vars merge.
  Regression spec added (`spec/unit/role_loader_spec.cr`);
  live-reverified on a fresh Atlantic host.

- **`filviu.activemq`/`.tomcat`**: both share the exact same "env |
  determine if `<user>` exists" -> "setup | create system user" pair
  (`ansible.builtin.getent: {database: passwd, key: "{{ user }}",
  fail_key: false}` then `when: getent_passwd[user] == none`). Real
  Ansible's own `getent` module sets the fact value to `None` for a
  not-found key with `fail_key: false`; this plugin stored an empty
  array instead - never equal to `None` under real Python/Jinja
  equality regardless of emptiness, so `== none` always evaluated
  false and the user-creation task silently skipped on every run,
  cascading into "chown failed: failed to look up user X" on every
  later task that assumed the user already existed. Fixed by mapping
  a not-found key to a real JSON null instead of `[] of String` in
  `plugins/getent.cr`. Updated the existing spec that had asserted the
  old (buggy) empty-array behavior; live-reverified on fresh Atlantic
  hosts (both now `CLEAN`).

- **`kostiantyn-nemchenko.mongodb_exporter`**: `groups: "{{
  mongodb_exporter_system_groups }}"` (a full-value substitution of a
  real 2-item list, on `user:`'s create/`useradd` path) rendered as
  bracketed text (`['mongodb_exporter', 'ssl-cert']`) instead of a real
  array - same shape as the pip `name:` truncation bug two rounds ago.
  Passed straight through to `useradd -G`, that whole bracketed string
  became ONE malformed argument - `useradd` itself then split it on
  the comma INSIDE the quotes, producing two bogus group names and
  failing "group ... does not exist" for both. Fixed by adding
  `UserState.normalize_groups_value` (bracket-aware, mirroring pip's
  own `normalize_name`), used on both the `useradd` (create) path and
  the earlier `groups:`/`append:` fix for an already-existing account
  (round 71000's `bsmeding.docker` fix) - that modify path had the
  identical latent bug, just never triggered by a role yet. Regression
  spec added; verified live in a container (both groups correctly
  assigned, confirmed via `id`).

- **`filviu.activemq`, continued (found on the getent-fix confirm
  rerun)**: past the getent fix above, the role's own "Install
  apachemq" task (`import_tasks: install.yml, notify: restart
  activemq`) never fired its handler at all, even though several of
  `install.yml`'s own inlined tasks (unarchive, deploy config) reported
  changed on the exact same run real Ansible fired it on. `when:`/
  `tags:` on an `import_tasks:` line were already propagated onto each
  task the import statically inlines (round 188's fix); `notify:` was
  never included in that same propagation. Fixed by adding the
  identical propagation for `notify:` in `try_parse_import_tasks`.
  Regression spec added (mirroring the existing `tags:` spec);
  live-reverified (now fully `CLEAN`).

- **`levonet.ci_github_rm_branch`**: `ignore_errors: "{{
  ci_github_ignore_error }}"` (default: `yes`) - `ignore_errors:` is a
  plain parse-time `Bool` (deferring it to runtime would be a bigger
  change), and the old code fell through to `false` for anything that
  wasn't a literal `true`/`yes`/`on`/`false`/`no`/`off` - so this real
  Ansible task (which real Ansible always ignores: `ignored=1,
  failed=0`) instead hard-failed the whole play every single run.
  Fixed with the identical heuristic `parse_become_value` already uses
  for its own templated-value case: a real playbook essentially never
  writes `ignore_errors: "{{ x }}"` to mean "no, don't ignore", so
  defaulting `true` for a `{{`-shaped string is right far more often
  than `false`, and never worse than the previous always-hard-fail
  behavior. Regression spec added; live-reverified (now `CLEAN`).

- **`gantsign.sdkman`**: "create the SDKMAN installation directories"
  (`with_nested: ['{{ sdkman_users }}', [...11 literal dir paths...]]`
  with `sdkman_users: []`, the role's own documented default) produced
  11 bogus `become_user: "[]"` tasks that all failed "is not a valid
  username", instead of the whole loop correctly running zero times
  the way real Ansible's own fully-resolved-before-cartesian-product
  semantics do. The parser's `with_nested` handling only recognized a
  LITERAL YAML list as a real source list; a bare `{{ var }}` string
  entry fell through to a generic "wrap it as one scalar item" branch
  frozen at parse time, before any templating happened - so the
  empty-list variable became ONE item (later rendered at execution
  time to the literal text `"[]"`), paired against each of the 11 real
  directory paths. Fixed by deferring a `with_nested:` array containing
  a templated scalar source to a new `TaskExecutor#resolve_loop_nested`
  (architecturally mirroring `resolve_loop_flattened`'s own defer-
  until-runtime design), wired into all 4 loop-resolution call sites.
  Regression specs added: a unit spec confirming the parser defers
  rather than pins the loop, plus a 3-case integration spec running the
  real compiled binary (full expansion, zero-iteration on an empty
  source, mixed literal+templated sources). Live-reverified on a fresh
  Atlantic host: the bogus failures are gone and the affected task now
  skips identically on both engines.

- **`logdna.logdna`**: `include_tasks: ./package/install_{{
  ansible_os_family.lower()}}.yml` (picking the OS-family install task
  file) rendered as the literal path `install_undefined.yml` instead
  of `install_debian.yml` - real Jinja2's own Python-object method
  calls (a real attribute/method lookup on the underlying Python
  string object, not a standard Jinja *filter*) are fully supported by
  real ansible-core's native Python-based Jinja environment; this
  engine's hand-rolled `{{ }}` evaluator didn't recognize `.lower()`/
  `.upper()` as calls at all and fell through to a generic-
  unresolvable-expression default rendering the literal text
  `"undefined"`. `| lower`/`| upper` (the standard Jinja filter
  spellings) already worked; only the `.method()` call syntax on a
  variable was missing. Fixed by adding a `string_method_case_call`
  helper to `VariableLookup`, matching the dispatch pattern already
  used there for other Python string methods (`.find(substring)`,
  `.strip()`). Regression spec added (covering both `.lower()` and
  chained `.lower().upper()`); live-reverified on a fresh Atlantic host
  (the include now correctly resolves to `install_debian.yml`).

- **`louim.bedrock-site-protect`, re-investigated (the original triage
  misdiagnosed this one)**: `pkg: "{{ passlib_package[ansible_python_
  version[0]] }}"` (and the task name `"...for python {{
  ansible_python_version[0] }}"`) rendered "undefined" - the original
  round-72000 triage assumed `ansible_python_version` was never
  populated at all (it's been set since 0.9.818, well before this
  round; that was an incomplete-grep error, not a real gap). The
  actual root cause: string integer-subscript indexing
  (`mystr[0]`/`mystr[-1]`) through Crinja. The hand-rolled `{{ }}`
  evaluator's own `VariableLookup#index_into` handles this fine, but
  the full-evaluator dispatch is Crinja-first, and the vendored
  Crinja's index-fallback gate (`Value#indexable?`) checks
  `@raw.is_a?(Indexable)` - which `String` satisfied on the Crystal
  versions Crinja was originally written against, but no longer does
  on modern Crystal (`String` was dropped from `Indexable`) - so the
  resolver's already-correct `Value#[]?(index : Int)` String branch
  never got a chance to run. Every `{{ string[0] }}` (variable or
  literal, positive or negative index) silently went to Undefined.
  Fixed by reopening `Crinja::Value#indexable?` to recognize strings
  again (`src/krikri/crinja_string_index.cr`), required from both the
  `.j2`-template path and the `{{ }}` full-evaluator path. Regression
  spec added; live-reverified on a fresh Atlantic host - the role is
  now fully `CLEAN` (converges to the exact same point real Ansible's
  own `'wordpress_sites' is undefined` failure does).

- **`kostiantyn-nemchenko.patroni`**: the role's own
  `postgresql_apt_filename: "{{ __postgresql_apt_filename }"` default
  (a genuine typo in the role, missing one closing brace) was silently
  tolerated - the hand-rolled `{{ }}` scanner found no well-formed
  span, copied the malformed text through verbatim, and the play kept
  going much further (`ok=19`) using whatever leftover/partial value
  resulted, masking the real divergence point. Real ansible-core
  hard-errors at first use (live-verified 2.19.4: "Syntax error in
  template: unexpected '}'" for a stray single `}` inside the span;
  "unexpected end of template, expected 'end of print statement'."
  for a span with no closer at all) and stops right there (`ok=5`).
  Fixed by raising a new `TemplateSyntaxError` from
  `expand_mustache_spans` whenever `find_mustache_close` returns nil,
  with the two real Jinja2 messages distinguished the way Jinja2's own
  lexer does (same quote/nested-brace scan state, so a valid
  dict-literal body like `{{ {"a": 1} }}` and the gantsign.helm
  quoted-literal Go-template argument still parse correctly, and a
  stray `}` in literal text outside any span still passes through
  verbatim, exactly like real Jinja2). Regression spec added (5
  examples, including the two valid-shape no-false-positive cases);
  live-verified against a local playbook reproducing the patroni shape
  (task-level failure with real Ansible's exact message, `ok=0`,
  instead of sailing past). One known shape difference remains: real
  Ansible rejects `command: echo '{{'` at PARSE time ("failed at
  splitting arguments, either an unbalanced jinja2 block or quotes")
  while this engine now fails the task at execution time - both fail,
  only the phase and wording differ.

### Needs a closer look (real, reproducible, not root-caused yet)

One item from this round - the apt-404-on-krikri-host-only pattern seen
on 3 roles - is tracked in the **Open gaps** section's own "Needs a
closer look" subsection above, where the full writeup lives (kept in
one place rather than two). The other two, `f500.ufw` (possible
SSH-lockout-after-`ufw enable`) and `Frzk.chrony` (task-level `vars:`
leaking across sibling tasks), have since been root-caused and fixed
(see their own sections at the top of this file). They were not
root-caused this round and no fixes were attempted for them here.

---

## Round 71000: 200 never-before-tested roles (Galaxy top-download list), 8 real bugs (0.9.837-0.9.844)

First batch since Atlantic.net's server-limit increase (10 -> 25); run at
`--kata-hosts 8 --atlantic-hosts 20`. All 4 Kata pairs hit a new failure
mode this round - `ctr run`/networking succeed, but SSH auth and `ctr task
exec` both fail against the guest with `rpc error ... cgroup.procs ...
Device or resource busy` from the kata-agent - losing 44 roles to
`BOOT_FAILED` with no automatic cross-backend retry in
`krikri-role-tester`. Not root-caused (not an engine bug); those 44 roles
were successfully requeued Atlantic-only (`--backend atlantic`, no
`--kata-hosts`) and all completed cleanly. Given the expanded Atlantic
capacity, Kata is no longer worth defaulting to for these batches -
`krikri-role-tester run ... --backend atlantic --atlantic-hosts N` (no
code changes needed) is now the preferred invocation.

Of 10 DIVERGENT roles from the first 200: 4 real bugs found and fixed
in the original triage pass (below), plus 4 more (also below) found
while confirm-rerunning the fixed roles - progressing past one bug
often exposed the next one downstream on the exact same role, most
notably `claranet.postgresql` (apt-stdout fix -> reached a pip `name:`
list-truncation bug -> reached a `lists_mergeby` unimplemented-filter
gap, three fixes deep on one role) and `bitintheskud.ansible-role-ecs-
agent` (iptables fix -> reached a `file: recurse:` bug, two fixes deep).
Confirmed by a subsequent live full-role rerun: `claranet.postgresql`
now converges to EXACTLY the same point real `ansible-playbook` itself
eventually fails at - byte-identical error message, identical recap on
both engines - the role's own pre-existing `item.when`
string-not-boolean bug, not an engine issue, not chased further;
`amtega.tftpd` is the 5th confirming role for the already-
documented `_check_platform` role-private-module scope cut; `adfinis-
sygroup.icinga2_agent`'s `deb822_repository`/apt-package failure did not
reproduce in an isolated container rebuild (plugin output and apt
resolution both correct) - inconclusive, likely a one-off Atlantic-host
network hiccup; `antmelekhin.windows_exporter` is Windows-only, same
scope cut as `danielweeber.windows_exporter`/`deekayen.chocolatey`;
`Aplyca.EC2Describe` and `bodsch.k0s` are a new open-gap class (below).

The 44 Kata-lost roles were then requeued Atlantic-only (round 71200+,
all completed cleanly, no more `BOOT_FAILED`); of those, 6 more
DIVERGENT: `bodsch.htpasswd` is a role-private `filter_plugins/`
(`| validate`, a custom Python filter) - same already-documented scope
cut as `oasis_roles.system_repositories`'s `filter_plugins/exclude.py`;
`bodsch.promtail` is a 2nd confirming role for the `bodsch.scm.
github_latest` module-resolution open gap above; `aalaesar.install_
nextcloud` and `asg1612.dockerswarm` both fail identically on both
engines for environment/harness reasons (a role dependency
`geerlingguy.php-versions` the test harness's Galaxy install never
fetched; a missing `ipaddr` Jinja filter in the harness's own real-
ansible-core install, same class as the already-documented `buluma.*`
rows) - real divergence masked by different downstream tasks each
engine happens to reach afterward, not evaluated further; `bodsch.
apparmor`'s single differing task (real Ansible found `apparmor`/
`apparmor-utils` already dpkg-installed, krikri's paired host did not,
despite related config files still present on disk) looks like
Atlantic host-image variance between the two paired VMs rather than an
engine bug - warm reruns matched byte-for-byte on both engines
afterward. One new open gap found (below): `asg1612.gluster`.

- **`bcook254.adguardhome`**: warm rerun always reinstalled the AdGuardHome
  binary instead of detecting it was already the right version. The
  role's own idempotency check is `when: __result is failed or __result.
  stdout is not search(adguardhome_version)` - the `search(...)` test's
  argument is a bare variable reference, not a quoted literal.
  `ConditionalEvaluator`'s `is match(...)`/`is search(...)` handling ran
  the pattern argument through `unquote_literal` alone, which only strips
  quotes and passes an unquoted word through UNCHANGED as literal text -
  so the regex became the literal string "adguardhome_version" instead of
  the variable's actual value (e.g. "v0.107.63"), could never match real
  `--version` output, and `is not search(...)` was permanently true.
  Fixed by routing the pattern argument through `evaluate_value` (already
  used for the left-hand side just below it), which resolves both quoted
  literals and bare variable references correctly. Regression spec added
  (`spec/unit/conditional_evaluator_spec.cr`).

- **`bitintheskud.ansible-role-ecs-agent`**: warm rerun always re-ran the
  role's second `iptables:` task (`match: tcp`, a NAT REDIRECT rule for
  the ECS agent's IAM-roles-for-tasks proxy) instead of detecting it
  already existed - and, worse, live reproduction in a `--cap-add=
  NET_ADMIN` container showed the underlying `iptables -A`/`-C` calls
  were failing outright every time (`Couldn't load match 'at'`), meaning
  the NAT rule was never actually being created on the target host at
  all, not just misreported. `IptablesCommand.construct_rule` had `"-mat"`
  instead of `"-m"` for the `match:` param - GNU iptables' getopt_long_only
  parses a bare `-mat` as `-m` with its value glued on (`at`), tries to
  load a nonexistent "at" match extension, and errors on both the `-C`
  existence check and the `-A` apply. `apply_rule` in `plugins/iptables.cr`
  doesn't check `remote_exec`'s exit code on the apply path, so the
  failing `-A` was silently reported as `changed: true`/"Rule applied"
  every run, forever, without ever actually applying it. Fixed the flag
  typo; the silent-exit-code gap on `apply_rule` is not addressed (all
  other iptables call sites in this round matched real Ansible, so
  narrower than the systemic fix would suggest - noted here rather than
  widened speculatively). Regression spec added
  (`spec/unit/iptables_command_spec.cr`).

- **`bsmeding.docker`**: `groups:`/`append:` on an EXISTING user did
  nothing - the role's own "Ensure docker users are added to the docker
  group." (`ansible.builtin.user`, `groups: docker, append: true`
  against `root`) always reported unchanged, even on the very first
  run, and `root` was never actually added to the `docker` group at
  all. `plugins/user.cr`'s `#modify` path (used for any account that
  already exists, as opposed to `#create`'s `useradd`) built its
  `usermod` flags from uid/group(primary)/shell/home/comment only -
  `groups:`/`append:` were read in `#create` (`useradd -G`) but never
  even looked at in `#modify`, so adding an existing user to a
  supplementary group was silently a no-op regardless of `append:`.
  Fixed by reading current group membership from `getent group`'s own
  4th (member-list) field per line - mirroring real Ansible's own
  `grp.getgrall()` + `name in g.gr_mem` check, rather than `id -Gn`,
  which would also fold in the user's PRIMARY group and wrongly count
  it as "already a member" - and adding `-G`/`-a -G` to `usermod` when
  the requested/current sets differ. No spec added - real
  useradd/usermod mutation is out of unit-spec scope by design (same
  class as apt/dpkg below); verified live by rebuilding the plugin and
  running it directly against a fresh Debian trixie container: `root`
  added to a fresh `docker` group on the first run (`changed: true`,
  confirmed via `getent group docker`), idempotent on the second.

- **`claranet.postgresql`**: cold run diverged early - real Ansible's own
  `ansible.builtin.apt` module always registers `stdout`/`stderr` (the
  raw `apt-get` invocation output, `""` when nothing ran) even on
  success, and the role's own "Drop the automatically created cluster
  after installation" task depends on it: `when: ... in
  _postgresql_packages_installation_res.stdout` (checking apt's own
  postinst-trigger output for whether installing the postgres package
  auto-created a cluster). `plugins/apt.cr`'s success path for
  `handle_install` never passed `stdout:`/`stderr:` to `PluginResult` (only
  the failure path did), so the `when:` failed outright ("object of type
  'dict' has no attribute 'stdout'") instead of evaluating the condition
  like real Ansible does. Fixed by capturing the install command's
  stdout/stderr and passing them through on the success path too. No
  spec added - real apt/dpkg mutation is out of unit-spec scope by
  design (see this repo's own `CLAUDE.md`); verified live by rebuilding
  the plugin and running it directly against a fresh Debian trixie
  container, confirming a real install now returns non-empty `stdout`.

- **`claranet.postgresql`, continued (found on the apt-stdout-fix
  confirm rerun)**: past the apt fix above, `name: "{{
  _postgresql_dependencies_pip_packages }}"` (a full-value Jinja
  substitution of a real 2-item list variable, as opposed to a literal
  YAML `name:` list - which the parser upstream already comma-joins
  into a plain string before `plugins/pip.cr` ever sees it) rendered as
  bracketed text (`['psycopg2', 'ipaddress']`), and `normalize_name`'s
  `else raw` branch returned that bracketed text UNCHANGED for any list
  with more than one entry (only the size==1 case was unwrapped) -
  `#install` then comma-split THAT text naively, truncating everything
  after the first item's own internal comma into one bogus "package"
  (`"['psycopg2'"`), and pip errored "Invalid requirement" instead of
  ever installing anything. Fixed by joining the already-parsed list
  with commas for the >1-item case too. Regression spec added
  (`spec/integration/pip_spec.cr`, `state: absent` so no real install
  runs); verified live locally.

- **`bitintheskud.ansible-role-ecs-agent`, continued (found on the
  iptables-fix confirm rerun)**: past the iptables fix above, warm
  rerun still showed one spurious `changed` - `file:`'s `recurse: true`
  (owner/group/mode 0755 on `/etc/ecs`) reported `ok`/"Directory
  attributes updated" even though a later task in the same role writes
  `/etc/ecs/ecs.env` with a different mode. `handle_directory`'s
  `changed` was decided from `update_attributes_if_needed` on the
  TOP-level path alone - it never looked at anything nested - so the
  recursive apply (gated on `changed`) never even ran once the
  directory's own attributes already matched. `recurse: true` was
  effectively a no-op whenever the top directory happened to already be
  correct, silently leaving stale nested files wrong forever. Fixed by
  adding `recursive_attributes_need_update?`, which walks the same tree
  the existing recursive apply already does, checked whenever the
  top-level path itself doesn't already account for a change.
  Regression spec added (`spec/integration/file_spec.cr`); verified
  live locally (a directory already at the right mode with one nested
  file NOT at the right mode now correctly reports `changed: true` and
  fixes the nested file).

- **`bitintheskud.ansible-role-ecs-agent`, continued again (found on
  the file-recurse-fix confirm rerun)**: past the recurse fix above,
  the very next task ("Create ecs environment file", `copy:` on
  `/etc/ecs/ecs.env` inside the directory the previous task just fixed)
  still reported `ok` on warm instead of `changed`, even though the
  file's mode WAS actually being corrected on disk each run (confirmed
  via direct plugin invocation and a debug build) - not a stale-read/
  batching artifact (ruled out: reproduced identically with
  `--no-batching` and via direct compiled-plugin invocation, no
  playbook involved at all). Root cause: `copy.cr`'s (and
  `template.cr`'s, same shape) identical-content early-return path
  calls `apply_file_attributes(dest)` to reconcile a stale mode/owner/
  group, but hardcoded `changed: false` regardless of whether that
  reconciliation actually changed anything - so any task shape where an
  attribute gets re-broken between runs (this role's `file: recurse:`
  immediately followed by `copy:` on a file inside that tree) silently
  fixed the file while permanently under-reporting `changed`. Fixed by
  having `apply_file_attributes` return whether it actually changed
  anything (compares `File.info` before/after), threaded through both
  identical-content return paths in both plugins. Regression specs
  added (`spec/integration/copy_attribute_reconcile_spec.cr`: a bare
  mode-only reconcile for both `content:` and `src:` forms, plus the
  exact `file: recurse:` -> `copy:` sequence end to end); verified live
  locally against the original two-task repro (both tasks now correctly
  report `changed` on the run where the mode actually flips back and
  forth, matching real Ansible).

- **`claranet.postgresql`, continued again (found on the pip-fix
  confirm rerun)**: past the pip fix above, `community.general.
  lists_mergeby(list, 'key')` (merging autotune/global/extra PostgreSQL
  config-option lists by their shared `option` key, later lists
  winning on collisions - real Ansible's own `combine()` semantics
  applied per-item) was entirely unimplemented in both evaluators (the
  hand-rolled `FilterEngine`, used for this exact `loop: "{{ ... }}"`
  task-param shape, and the vendored Crinja renderer, for a `.j2`
  template using the same filter). Implemented in both: `FilterEngine`
  gained a `lists_mergeby`/`list_mergeby` (the pre-3.x alias) case
  reusing `combine_hash`'s existing recursive-merge/list-merge-mode
  logic, plus a `community.general.`-prefix strip in the FQCN-handling
  dispatch (matching the existing `ansible.utils`/`ipaddr` carve-out);
  `jinja_filters.cr` gained the matching Crinja-side filter. Regression
  specs added (`spec/unit/lists_mergeby_spec.cr`: two/three-list merges,
  both name spellings, the FQCN form, `recursive=`/`list_merge=`,
  missing-key/non-dict error cases, a variable-reference merge key);
  verified live locally against the role's own exact chained-filter
  `loop:` expression (three source lists, later lists correctly winning
  collisions, non-colliding items passing through unchanged).

---

## `inmotionhosting.monit`'s open lead closed: `in`/`not in` against the `vars` magic dict did a substring search instead of a key lookup (0.9.836)

The role's own "Remove nonexistent services" task filters
`monitored_services` down to only the services whose backing variable
(`apache_daemon`, `mysql_daemon`, etc.) was actually defined by the
playbook: `when: item.var_name not in vars or lookup('vars', item.
var_name) is not string or lookup('vars', item.var_name) == 0`, where
`vars` is real Ansible's own magic dict of every variable in scope.
None of those backing variables are defined in this benchmark, so real
Ansible removes every entry and the later "Install service configs"
loop runs zero iterations.

`ConditionalEvaluator#evaluate_in`'s container resolution had no
special case for a Hash-valued container - `#evaluate_value`'s own
return union (String | Int64 | Bool | Nil | Array(String)) has no Hash
case at all, so `vars` fell through to `#json_any_to_value`'s `else ->
value.to_s` branch and got stringified into one big compact-JSON dump
of every variable in scope. `evaluate_in`'s generic `container.
includes?(item.to_s)` then did a raw SUBSTRING search over that whole
dump instead of a real key lookup - and `monitored_services` (itself
one of the vars in scope) holds the literal string "apache_daemon"
nested inside its own value, so `'apache_daemon' in vars`
substring-matched and came back true even though "apache_daemon" is
not itself a variable name. `not in vars` inverted to false, nothing
got removed, and "Install service configs" then failed all 5 templates
with `'apache_daemon' is undefined` instead of skipping cleanly.

Fixed by resolving the container expression via `VariableLookup#resolve`
first and, when the raw result is a Hash, doing a real
`.has_key?(item)` test instead of falling through to the lossy
string/array path - every other `in`/`not in` shape (string substring,
array membership) is untouched. Regression spec added
(`spec/unit/conditional_evaluator_spec.cr`); verified live via an
extracted repro matching the role's exact task shape (all 5 services
now correctly removed, "Install service configs" now correctly skips
instead of failing).

---

## `geerlingguy.kubernetes`'s changed-count gap root-caused and fixed: the python3-apt auto-install was emulated as a per-invocation behavior instead of a persistent host mutation (0.9.835)

The last confirmed open gap from the 97-role re-verification round: the
role's own `apt: {update_cache: true}, when: kubernetes_repository.changed`
task reported `ok` on krikri where real Ansible reported `changed`
(cold `changed=4` vs `changed=5`, everything else identical). The
0.9.831-era investigation had ruled out the round-30001 bug class but
concluded wrongly that an earlier role task "already triggers real
Ansible's python3-apt auto-install, so both engines should be on the
WITH-python3-apt mtime-diff path here" - which is true of real
Ansible's HOST and false of this engine's, and that distinction is the
whole bug.

Real Ansible's apt module probes for the python3-apt bindings at module
start and, when missing, auto-installs them (`apt-get update` prefetch,
then `apt-get install -y python3-apt`, then respawn) - a real, PERSISTENT
host mutation. On the krikri host nothing ever installed python3-apt,
so krikri's `python_apt_present?` probe stayed false on EVERY apt task,
and the round-30001 emulation rule ("absent → cache-refresh reports
changed=false unconditionally") kept applying forever, while real
Ansible's host moved to the mtime-diff path after its very first apt
task. By the cache-refresh task, real Ansible's freshly-added pkgs.k8s.io
repo indexes genuinely moved the lists mtime → changed=true; krikri was
still on the absent path → ok. The earlier "both engines should be on
the same path" premise confused which HOST was being described.

Fixed by implementing the auto-install faithfully: a new shared helper
(`AptLockRetry#apt_auto_install_python_apt`) runs the same two commands
real Ansible does (prefetch skipped only when the task explicitly said
`update_cache: false`, per apt.py's own guard), wired into both
`plugins/apt.cr` (module start) and `plugins/package.cr`'s apt
cache-refresh-only path (real `package:` delegates to the apt module,
which auto-installs the same way). The install succeeding makes every
later probe pass, so the with-bindings mtime-diff path takes over
naturally - and the round-30001 first-invocation semantics are preserved
exactly, since the respawned module's own mtime window opens entirely
AFTER the prefetch in both engines. Check mode never performs that
mutation - it refuses instead (a new shared
`apt_check_mode_python_apt_refusal` helper, matching the message
apt.cr's own update-cache block already used), on both call sites, since
`package:` delegates to the same apt module on apt hosts. Regression
specs added for both helpers; verified live end-to-end on a fresh Kata
pair (round 70002): cold AND warm recaps now byte-identical between
engines (`ok=9 changed=5 failed=1 skipped=2` cold, `ok=8 changed=0
failed=1 skipped=3` warm, both). Times: cold py 42.8s vs cr 31.4s; warm
py 13.0s vs cr 1.9s.

---

## `RedHatOfficial.rhel8_pci_dss`'s early-stop divergence root-caused and fixed: a ternary's filter-chain branch stringified as Python-repr, not JSON (0.9.834)

`ROLES_TESTED.md`'s "not yet root-caused" row (`ok=20 skipped=96` on
krikri vs real Ansible's `ok=87 skipped=2236` - the whole rest of this
large STIG role never ran) traced to one task: `Set gpgcheck=1 for each
yum repo`, whose `loop:` source is `'{{ repo_grep_results.stdout |
regex_findall(''(.+\.repo):\[(.+)\]\n?'') if repo_grep_results is not
skipped else [] }}'` - an inline ternary whose CHOSEN branch is itself
a filter chain producing a real Array (a list of `[repo_path, section]`
pairs), not a scalar literal.

`ExpressionEvaluator#evaluate`'s ternary handling delegated the whole
expression to Crinja's plain `render!`, which stringifies a container
result through Crinja's own Python-repr `Finalizer`
(`[['a.repo', 'sec1'], ...]`, single-quoted - not valid JSON) instead
of this codebase's JSON-compact `VariableLookup#format_value`, the
format every loop-template caller's render-then-`JSON.parse`-back
round trip depends on (`resolve_loop_template`'s own
`parse_list_result`). The failed parse fell through to the
array-wrapped scalar fallback, and the WHOLE unparsed repr string
became ONE loop item instead of the real list - `item[0]` then indexed
into a String, "'item[0]' is undefined", hard-failing the task (real
Ansible's own equivalent iterates two items and continues). The
existing code comment claiming every construct near this dispatch
(`boolean_logic?`, comparisons, ternary, etc.) is "provably
scalar-only" turned out to be wrong specifically for ternary, whose
chosen branch can be an arbitrary sub-expression - the other
constructs genuinely are scalar-only and were left untouched.

Fixed with a new `render_via_crinja_container_safe` helper: computes
the value via Crinja's structured `evaluate_value!` first, and only
reroutes through JSON-compact formatting when the result is actually
an Array/Hash - every scalar and genuinely-undefined case (including
an else-less ternary's missing branch, which must render as `""`, not
the literal text "undefined") keeps the original `render_via_crinja`
stringification untouched. Regression specs added
(`spec/unit/expression_evaluator_spec.cr`,
`spec/integration/loop_ternary_filter_chain_spec.cr`, the latter
extracting the role's exact shell/regex shape). The role itself
(a very large STIG hardening role) has not yet been re-run end to end -
the specific failing task is confirmed fixed via the extracted repro,
matching the role's exact loop source byte-for-byte.

---

## `levonet.ci_github_pr_description`'s open lead closed: `length` filter tolerated `None` instead of failing (0.9.833)

`FilterEngine#length_of` (the hand-rolled `{{ }}` evaluator, not
Crinja) returned `0` for a `null`/`None` input, letting a task pass
that real Ansible's own `length` filter (Python's `len()`) fails
outright with `"object of type 'NoneType' has no len()"`. Found via
`levonet.ci_github_pr_description`'s own recap divergence. The
Crinja-side path was already correct (Crinja's `Value#size` already
raises `TypeError` for a non-sized `Nil` target, just with different
text - not chased further since it already fails the task, matching
real Ansible's pass/fail shape). Fixed by raising the identical
message from `length_of`'s `Nil` branch. Regression spec added
(`spec/unit/filter_engine_spec.cr`).

---

## Round 30001's apt `update_cache:` premise re-verified live - still correct, no code change (0.9.831)

Investigating `geerlingguy.kubernetes`'s small `changed` divergence
raised a scare: an initial live test (adding a genuinely new apt
source, then `update_cache: true`) showed real Ansible reporting
`changed: true` on a host apparently WITHOUT `python3-apt` - seemingly
contradicting round 30001's core finding ("without python3-apt, real
Ansible always reports `changed: false` here regardless of mtime
movement"), which both `apt.cr`'s original fix AND the `robertdebock.
update_package_cache` fix shipped a few commits ago (0.9.826) build on
via the shared `apt_cache_refresh_changed?` helper.

Re-verified round 30001's EXACT original methodology (delete a tracked
lists file + age the `/var/lib/apt/lists` directory mtime) on a
genuinely fresh, untouched Kata VM with `python3-apt` freshly confirmed
absent: real Ansible reported `changed: false` again, reproducing round
30001's finding precisely. The earlier contradicting result was a
test-isolation mistake, not a real behavior change - that test reused a
VM across several playbook runs, and an earlier task had silently
triggered real Ansible's own python3-apt auto-install, so the
"contradicting" run was actually exercising the WITH-python3-apt
mtime-diff path the whole time, not the absent-python3-apt path it
appeared to be.

Conclusion: round 30001's rule stands, `apt.cr`/`package.cr`'s shared
`apt_cache_refresh_changed?` logic is correct as shipped, no revert
needed. `geerlingguy.kubernetes`'s own small `changed` divergence was
something else - root-caused and fixed in 0.9.835 (see the narrative
above): the missing piece was the python3-apt auto-install's persistent
host mutation, which the rule's own premise assumed away.

---

## `buluma.checkmk_agent` regression root-caused and fixed: a become/connection failure was overridable by failed_when: false (0.9.831)

A `become:`/connection-level failure (no module ever ran, so there's no
result JSON to reinterpret - a missing sudo password, an unknown
`become_user`, a crashed or missing plugin binary, a nonzero SSH exit)
was routed through `apply_changed_failed_when` exactly like a genuine
module result, so a task's own `failed_when: false` silently suppressed
it and the play continued. Real Ansible's own equivalent - verified live
against ansible-core 2.19.4 - aborts the WHOLE PLAY as `fatal:` in this
case, unconditionally; `failed_when:` never even gets a chance to run,
because there's no module result for it to reinterpret in the first
place. Found via `buluma.checkmk_agent`'s own "Download check_mk_agent
installer (deb)" task (`delegate_to: localhost, failed_when: false`,
inheriting the play's `become: true`) - a sudo password requirement on
the controller (the harness host, not the play's remote target) failed
real Ansible outright while this engine happily continued.

Fixed by tagging every "no real module result" synthetic `PluginResult`
(`plugin_manager.cr`'s local/remote execution-failure and
JSON-parse-failure branches, `plugin_daemon.cr`'s batch equivalent) with
a `_connection_failure` marker, and having `apply_changed_failed_when`
skip both `changed_when:`/`failed_when:` entirely when it's set -
`ignore_errors:` (a genuinely different, still-untouched mechanism) is
unaffected. Regression spec added
(`spec/integration/connection_failure_unignorable_by_failed_when_spec.cr`,
using an unknown `become_user` rather than a missing sudo password so
the failure is deterministic on any machine's own sudoers config).
Live-reverified against the real role on a fresh Kata VM: `ok=14
changed=5 failed=1`, matching real Ansible's `ok=14 changed=6 failed=1`
baseline (now correctly aborting at the same task, cold and warm).

---

## `buluma.selinux` regression root-caused and fixed: selinux: silently no-op'd instead of failing when SELinux isn't installed (0.9.830)

`plugins/selinux.cr` treated a missing `/etc/selinux/config` as "SELinux
not compiled in, report a harmless no-op" - a deliberate design choice
per its own comment, meant to let `os_hardening`-style roles "cleanly
apply to both EL and Debian-family hosts." Checked directly against
`ansible.posix.selinux`'s own module source: this is simply wrong. The
real module has no such special case anywhere - `if not os.path.isfile
(configfile): module.fail_json(msg="Unable to find file {0}".format(
configfile), details="Please install SELinux-policy package, if this
package is not installed previously.")` fires unconditionally,
regardless of distro. Found via `buluma.selinux` on a Rocky 9.6 host
missing the SELinux-policy package (not even a Debian host - the
"EL vs Debian" premise didn't even hold for the case that surfaced it):
real Ansible failed with that exact message and this plugin silently
reported success instead.

Fixed by matching real Ansible's behavior and message text exactly. No
regression spec added - the plugin hardcodes the real `/etc/selinux/
config` system path (not parameterized), so a spec can only safely
exercise the failure branch on a host that genuinely lacks the file,
which isn't a safe assumption for a shared dev/CI machine; verified
live instead (a fresh Kata Rocky VM with no SELinux-policy package
installed) pre/post-fix.

---

## Correction: `linux-system-roles.logging`'s "distro-mismatch" reclassification was itself wrong - real regression, now fixed (0.9.829)

The 0.9.826-era reclassification below ("not a regression at all... the
documented custom-local-module scope cut") was wrong on the facts: it
assumed `sr_fingerprint` was simply unsupported cross-distro, the same
class as `timesync_provider`'s own shell-script form. It isn't - both
`linux-system-roles.logging` AND `.storage` AND `.timesync` ship
`library/sr_fingerprint.py`, a plain, self-contained, new-style
(`AnsibleModule`-based) Python module with no unusual dependencies -
exactly the shape 0.9.819's own `PythonModuleRunner` feature claims to
support. It should have worked. Investigating why it didn't found THREE
independent, compounding bugs, all in the arbitrary-Python-module path
0.9.819 added and nothing had exercised since:

1. **`python_module_runner.cr`'s `find_source`** derived the role's root
   directory from `role_files_dir` (only ever set when the role ships a
   `files/` subdirectory - none of these three roles do), instead of
   the always-set `task.role_path`. A role missing `files/` could never
   resolve its own `library/*.py` at all, silently falling back to
   "unavailable modules" for every module reference - exactly what
   looked like a distro-scope cut resurfacing.
2. **`plugins/py_module.cr`** passed a new-style module's args via an
   `ANSIBLE_MODULE_ARGS` environment variable - real ansible-core 2.19's
   own `basic.py` (`_load_params` / `_internal/_debugging.load_params`,
   the fallback path any module hits when run outside the real
   AnsiballZ wrapper, exactly this plugin's situation) doesn't read that
   env var at all. It reads a JSON blob from STDIN, wrapped as
   `{"ANSIBLE_MODULE_ARGS": {...}}` - failing with "Failed to decode
   JSON module parameters." otherwise. This alone would have broken
   EVERY new-style role-private module this engine has ever tried to
   run, once (1) let it find one.
3. **`task_batcher.cr`** had no exclusion for an `unavailable_module`
   task at all, so a batched `sr_fingerprint:`/`blivet:` task failed
   with "Plugin binary not found: sr_fingerprint" - the batch script
   builder assumes every step is a normal uploaded plugin binary, with
   no notion of the py_module runner's own dynamic-source dispatch.
4. (Found finishing the storage repro, not logging's) **`python_module_
   runner.cr`'s `typed_value`** couldn't parse a magic var like
   `ansible_play_hosts_all` when a task passed it straight through as an
   arg - real lists/dicts sometimes render as Python-repr text
   (single-quoted), not valid JSON, the same class of shape this
   codebase already special-cases elsewhere (`package.cr`'s own
   `parse_package_names`) but `typed_value` never got the fallback.

Fixed all four. Regression specs added/updated
(`spec/unit/python_module_runner_spec.cr`). Live-reverified: `linux-
system-roles.logging` now reaches byte-identical `ok=30 changed=2
skipped=51 failed=0` on a fresh Kata VM, matching real Ansible exactly
(was `ok=28 skipped=53`). `linux-system-roles.timesync` (Rocky) improves
from `ok=23` to `ok=25` against real Ansible's `ok=26` - the remaining
1-task gap is `timesync_provider`, a shell-script (not Python) custom
module genuinely out of this runner's scope, not a regression.
`linux-system-roles.storage` (Rocky) gets much further than before
(`sr_fingerprint` and the package-install step both now succeed) but
still ultimately fails: its own `blivet:` module imports a custom
`ansible.module_utils.storage_lsr` package this engine doesn't bundle -
a new, separate, larger scope gap (arbitrary-module-utils bundling, not
just arbitrary-module execution), documented under "Deliberate limits"
below rather than tackled here.

---

## `brunobenchimol.certbot_dns` regression root-caused and fixed: a meta/main.yml dependency's inline var override leaked play-wide (0.9.828)

Fourth of the 12 confirmed regressions to get fixed. The recap shape
(krikri's `ok` one higher, `skipped` one lower than real Ansible) looked
enough like the ORIGINAL pre-0.9.682 `import_role: when:` bug that the
initial triage assumed that fix had regressed - it hadn't; the existing
`import_role_when_expansion_spec.cr` still passes unchanged, and this
was a completely different, unrelated bug that happened to nudge the
same two counters in the same direction.

Diffing the role's own two full run logs task-by-task found the ACTUAL
single differing task: `brunobenchimol.certbot_dns`'s own last task,
"Remove cron job... `when: not certbot_auto_renew`", ran on krikri
(`ok`) but was correctly skipped by real Ansible. Both
`brunobenchimol.certbot_dns` and its `meta/main.yml` dependency,
`geerlingguy.certbot`, default `certbot_auto_renew: true` - but that
dependency is declared with an inline override
(`- role: geerlingguy.certbot, certbot_auto_renew: false, ...`), scoped
by real Ansible to that ONE dependency's own tasks only.

Root cause in `role_loader.cr`'s `load_role`: when a role is loaded with
`play_scope: true` (every `roles:` entry and `meta/main.yml`
dependency), its `role_vars` - built by merging this ONE invocation's
own override vars onto its plain `vars/main.yml` content - gets
contributed wholesale into `play.all_role_vars`, a bag every LATER task
in the play can see (this play-wide visibility is correct and
intentional for a role's own plain `vars/main.yml`/`defaults/main.yml`
content - see the surrounding comment - just not for a one-invocation
override). So `geerlingguy.certbot`'s dependency-scoped
`certbot_auto_renew: false` ended up visible to `brunobenchimol.
certbot_dns`'s own later task, which should have seen its own
`defaults/main.yml`'s `true`.

Fixed by capturing a separate `own_vars` snapshot (freshly loaded from
`vars/main.yml`, before `invocation_vars` merge) and contributing THAT
to `play.all_role_vars` instead of the invocation-tainted `role_vars` -
mirroring how `own_defaults` already re-loads fresh from disk for the
exact same reason, two lines below. Regression spec added
(`spec/integration/role_dependency_when_spec.cr`). Live-reverified
against the real role on a fresh Kata VM: `ok=8 changed=5 skipped=40`,
matching real Ansible's original baseline exactly.

---

## `buluma.bind` regression root-caused and fixed: systemd's is-enabled check didn't replicate real Ansible's -l quirk on aliased units (0.9.827)

Third of the 12 confirmed regressions to get fixed (after `linux-system-
roles.logging` turned out not to be one). Took two live Atlantic Ubuntu
22.04 hosts and quite a bit of digging to pin down: `bind9.service` is a
systemd `Alias=` of `named.service`, and `systemctl enable bind9`
genuinely refuses on real Ubuntu 22.04 ("Refusing to operate on alias
name or linked unit file") - confirmed by running the exact command
manually on both a real py-driven and a real krikri-driven host.
Initially this looked like it should fail identically on both engines
(and did, when run manually) - but real `ansible-playbook` itself
reported success. Instrumenting ansible-core's own `systemd.py` module
live (patched in a debug line via `ANSIBLE_LIBRARY`, bare non-FQCN
module name to make the override apply) found the real mechanism: real
Ansible's own `is-enabled` check runs `systemctl is-enabled '<name>' -l`
(the `-l`/long flag) and only treats the result as "not enabled" when
its stdout string-equals EXACTLY `"enabled-runtime"`, `"indirect"`, or
`"alias"` - but `-l` makes an ALIASED unit's output multi-line
(`"alias\n  /path/to/named.service\n  /path/to/bind9.service\n"`),
which never equals the bare string `"alias"`. So real Ansible's own
check falls through to "already enabled" for an alias and never calls
`enable` on it at all - an accidental quirk (the code's own comment,
"Let systemd handle the alias as we can't be sure what's needed",
suggests a different intent), but it's the real observable behavior
that determines whether the enable-refusal error is ever reached.
`plugins/systemd.cr`'s own `enabled?` used a single-line `is-enabled`
(no `-l`) and a strict `== "enabled"` check - correctly saw the bare
"alias" and (reasonably, by itself) tried to enable anyway, hitting the
refusal real Ansible's own multi-line quirk happens to dodge.

Fixed by replicating real Ansible's exact (if quirky) `-l` + string-
comparison logic, factored into a new `SystemdEnabledState` module
(`src/krikri/plugin_helpers/systemd_enabled_state.cr`, same pattern as
`AptLockRetry`) so a unit spec can exercise the pure decision logic
without a real `systemctl`. Regression spec added
(`spec/unit/systemd_enabled_state_spec.cr`). Live-reverified end to end
on a real Atlantic Ubuntu 22.04 host: a clean `bind9` install+enable
now converges with `changed=1 failed=0`, matching real Ansible.

---

## `linux-system-roles.logging`'s "regression" reclassified: distro-mismatch, not a code issue (no version bump) - SUPERSEDED, see the 0.9.829 correction above: this reclassification was itself wrong

Investigating the 12 confirmed regressions in fix-priority order,
`linux-system-roles.logging` turned out not to be a regression at all:
its `rc=4 ok=28 skipped=53` vs real Ansible's `rc=0 ok=30 skipped=51`
gap is entirely the role's own "Record role success fingerprint" task,
which uses a custom Python module (`sr_fingerprint`) shipped in the
role's own `library/` dir - the same documented custom-local-module
scope cut `linux-system-roles.timesync`'s own row already describes
(confirmed live via the round's own saved `cold_py.out`: real Ansible
runs the task `ok`, krikri can't). The original round-159 `✅ Fixed`
verification was on Rocky/RHEL, where this branch either isn't taken or
resolves differently; this regression round happened to test Ubuntu.
The actual `include_role: vars:` cross-reference fix from round 159 is
unaffected and still correct - no code change needed here, just a doc
correction (see "Open gaps" and `ROLES_TESTED.md`).

---

## `robertdebock.update_package_cache` regression root-caused and fixed: package: update_cache: true hardcoded changed:true for apt (0.9.826)

Second of the 12 confirmed regressions from the round below to get
fixed. `plugins/package.cr`'s `update_cache_only` (the `package:
{update_cache: true}` path with no `name:`) hardcoded
`changed = package_manager == "apt"` - unconditionally true for apt,
regardless of whether the cache was actually stale. Real Ansible's own
apt module's `changed` here depends on python3-apt's presence and
whether the cache mtime genuinely moved (round 30001's `apt.cr` fix,
verified live back then and untouched since) - this OS-agnostic
module's own independently-implemented apt dispatch never got that fix
and reproduced the exact same false-`changed` bug class round 30001
already closed once, in a different file.

Fixed by extracting `apt.cr`'s own `cache_mtime`/`python_apt_present?`
into the shared `AptLockRetry` module (already `include`d by both
`apt.cr` and `package.cr`) as `apt_cache_mtime`/
`apt_python_apt_present?`, plus a new `apt_cache_refresh_changed?`
combining them the way `apt.cr`'s own before/after comparison already
did - one implementation backing both plugins now, closing off the
whole "duplicate apt logic silently drifts" bug class this and the
`evrardjp.keepalived` fix above both fell into. `apt.cr` itself now
calls the shared helpers too (its own `cache_mtime`/`python_apt_present?`
are thin wrappers, kept for call-site compatibility). Regression spec
added (`spec/unit/apt_lock_retry_spec.cr`) since, unlike the apt-get
exit-code fix above, this logic is cleanly unit-testable via a stubbed
`exec_remote`. Live-reverified on a fresh Kata VM: `changed: false` on
both a fresh-mirror run and a rerun (no python3-apt present, matching
real Ansible's own always-false-without-python3-apt semantics).

---

## `evrardjp.keepalived` regression root-caused and fixed: package: state:latest never checked apt's exit code (0.9.825)

First of the 12 confirmed regressions from the round below to get fixed.
Root-caused live: provisioned a fresh Atlantic Ubuntu 22.04 host directly
(outside the round-tester, kept alive for inspection) and reproduced the
exact failure with a minimal isolated task. `dpkg -l keepalived` on the
host confirmed the package was never actually installed, despite krikri
reporting `changed: true, "Package keepalived upgraded to latest"`.

Real cause: `apt-get install -y keepalived` failed with exit 100 (a
stale-mirror 404 on a resolved dependency, `libsnmp-base` - genuinely
environmental, not an engine bug) - but apt prints its "N upgraded, M
newly installed" summary line during dependency RESOLUTION, before any
package is actually fetched, so that line was still sitting in stdout
with a nonzero count when the later fetch failed. `plugins/package.cr`'s
`handle_apt`'s `state: latest` branch parsed that summary line to decide
`changed`/`failed` and never checked `upgrade_result[:exit_code]` at
all - the exact "changed but never installed" bug class that `apt.cr`'s
own `handle_latest` already guards against (found there via
`cloudalchemy.grafana`), but this OS-agnostic module's independently-
implemented duplicate never got the same fix. Fixed by adding the same
exit-code check `apt.cr` already has. Live-reverified on the same host:
post-fix, the identical scenario now correctly reports `failed: true`
with apt's real error text instead of a false `changed: true`. No
regression spec added - reproducing a genuine apt-get fetch failure
needs a real host with a broken package dependency, the same
practical-limits case `apt_install_with_implicit_cache_retry`'s own
untested corrupt-lists retry path is in; verified live instead, per this
file's own convention for that class of bug.

---

## 97-role fixed/divergence re-verification round finds 12 real regressions, after a version mixup was caught and corrected (round 65100-65510+, 0.9.823 -> 0.9.824)

Re-ran every role in `ROLES_TESTED.md` marked `✅ Fixed` (94 roles) or
`❌ DIVERGENCE` (3 roles) against the current build, via
`krikri-role-tester`, split into an 83-role Ubuntu batch (round
65100-65182) and a 14-role Rocky 9.6 batch (round 65200-65213) since
`--os` is a per-run flag, not per-role. 71 CLEAN, 20 DIVERGENT, 6
GALAXY_MISSING (role no longer resolves on Galaxy - unrelated to the
engine).

**Version mixup, caught and corrected:** a second session was working
directly in this same checkout concurrently (not an isolated worktree,
contrary to what was assumed at the time) and rebuilt `bin/
krikri-playbook` mid-round with its own uncommitted WIP changes. The
Ubuntu batch (round 65100-65182) ran against the real, released
`0.9.823`; the Rocky batch (round 65200-65213) unknowingly ran against
that other session's uncommitted `0.9.824` WIP build, not a real
release. That WIP work (an `include_vars:` strict-path-templating fix,
two CLI alias flags, and a corrected `RemovedActionError` message - see
the fix-phase commit below) was reviewed, its formatting fixed, `crystal
spec` and `./build.sh` re-run clean, and committed+pushed as `79270d9a`
(the real `0.9.824`). Every one of the 20 divergent roles was then
**re-run a second time** against this properly-committed build (Ubuntu
recheck: round 65300-65314; Rocky recheck: round 65400-65404; two
stragglers retried again at round 65500+) specifically to separate real
regressions from artifacts of the mid-round binary swap.

Of the 20 original divergences, **12 reproduced deterministically across
both independent runs** and are confirmed real regressions - see "Open
gaps" above for the detail on each: `evrardjp.keepalived`,
`robertdebock.update_package_cache`, `linux-system-roles.logging`,
`buluma.bind`, `brunobenchimol.certbot_dns`, `linux-system-roles.storage`
(Rocky), `linux-system-roles.timesync` (Rocky), `buluma.selinux` (Rocky -
inverted, real Ansible fails where krikri succeeds), `buluma.
checkmk_agent` (also inverted), `kyl191.openvpn`, `geerlingguy.
kubernetes`, `linux-system-roles.network` (Rocky). None have been
root-caused or fixed yet - this round was triage only, no engine code
changes. One more, `buluma.confluence`, only completed on a third
attempt (the first two hit SSH_TIMEOUT) and shows a small divergence -
not yet confirmed by a second successful run.

The second run **cleared two of the original 20** that turned out to be
run-to-run noise, not regressions: `diodonfrost.amazon_codedeploy` (the
original `rc=126` was a one-off plugin-upload glitch - CLEAN on retry)
and `inmotionhosting.wordpress` (the original `ok=110` vs `ok=120` gap
did not reproduce - the retry landed at `ok=26`/`ok=26` on both engines,
closely matching; this huge role's own external-download-heavy early
tasks appear to have high run-to-run variance that swamped any real
signal in the first pass). Two remain genuinely inconclusive because
real Ansible itself couldn't reach the host either time (reboot/SSH
flakiness on the py side, not an engine comparison at all): `mrlesmithjr.
change-hostname`, `robertdebock.selinux`. The rest reproduce
already-documented, non-regression behavior (GitHub-403/rate-limit or
long-build-timeout flakiness, or the known `delegate_to: localhost`
ssh-reupload limitation) - full breakdown in "Open gaps" above.

Two previously-known `❌ DIVERGENCE` roles (`gantsign.gitkraken`,
`andrewrothstein.cassandra-cluster` - both a parse-time strictness
difference where krikri used to proceed further than real Ansible's
own rejection) now come back CLEAN: both engines reject the playbook
identically at parse time. Whatever tightened krikri's parse-time
strictness between the original round and now closed this gap as a
side effect - not chased further here, but worth noting in case a
future session wants the specific commit.

`ROLES_TESTED.md` rows for the 12 confirmed regressions (plus
`buluma.confluence`'s single-data-point divergence) have been
updated to reflect the new divergence, with the correct version
attribution (0.9.823 for the Ubuntu-batch findings, the properly
committed 0.9.824 at `79270d9a` for the Rocky-batch and all re-checked
findings).

---

## KNOWN_MISSING cleanup: the three cosmetic-difference entries re-examined (0.9.824)

Two of the three entries under "Cosmetic differences" below turned out
to be fixable after all, verified live against a locally-installed
ansible-core 2.19.4 with minimal repros; the third was already accurate
and only needed its last gap closed:

- **`RemovedActionError`'s message text is now byte-identical to real
  ansible-core 2.19.4** (rc and detection were already). The old text
  (`[DEPRECATED]: ansible.builtin.include has been removed. ...`) was
  the 2.16-era tombstone wording; 2.19.4 actually prints `The
  'ansible.builtin.include' action plugin has been removed. Use
  include_tasks or import_tasks instead. This feature was removed from
  ansible-core in a release after 2023-05-16.` - built by
  `plugins/loader.py`'s `_find_fq_plugin` from the
  `ansible_builtin_runtime.yml` tombstone plus
  `_display_utils.get_deprecation_message_with_plugin_info`'s tail. The
  "moving target" objection stands as a description of history (2.16,
  2.17 and 2.19 all worded it differently) but is no longer a reason to
  stay approximate: 2.19.4 is the version this project verifies
  against, so the text now matches it exactly, and the parser specs pin
  the full string.
- **`include_vars:` with a failing templated path** - the real
  divergence was never "message wording". Live-verified against 2.19.4:
  when the path template references an undefined variable, real Ansible
  fails the include_vars task ITSELF ("Error while resolving value for
  '_raw_params': 'users' is undefined", rc=2), and for the
  `lookup('first_found', params)` form with an unresolvable nested
  candidate (`files: ['{{ ansible_facts.os_family }}.yml',
  'default.yml']`, no gathered facts) it fails the task with "object of
  type 'dict' has no attribute 'os_family'" rather than falling through
  to `default.yml`. This engine used to render the path leniently -
  either reporting `include_vars: file not found: undefined` (failing
  the task for the wrong reason) or, worse, silently loading the empty
  `default.yml` fallback and letting a LATER task fail with "'x' is
  undefined". The old entry's claim that "real ansible fails a LATER
  task" was an artifact of the harness round it came from (there the
  role's `users` var, not the include_vars path, was the undefined
  thing). Fixed by making include_vars's own path substitution strict
  (both the direct and looped forms) plus a strict pre-pass over the
  RAW task-vars values the path expression references (they are
  deep-rendered leniently at context-build time, before a strict check
  could see them), and by rendering first_found lookup candidates
  strictly (honoring the lookup's own `skip: true`). Same cause-text
  convention as every other module's undefined-arg failure (`'users'
  is undefined`) - real Ansible's "Finalization of task args ... "
  wrapper is the 2.19 presentation layer this engine already drops
  everywhere else. The happy path is unchanged (verified: the right
  os_family file still loads).
- **CLI flag surface**: `--inventory-file` (real Ansible's own
  deprecated spelling of `-i`/`--inventory`) and `--vault-pass-file`
  (alias of `--vault-password-file`) were the only two real
  ansible-core 2.19.4 flags missing from `--help`; both now parse. The
  flag list is otherwise identical, and the only accepted-but-inert
  flags remain the deliberate ones documented below.

---

## The last "architecturally out of scope" lookup was neither (0.9.826)

`lookup('inventory_hostnames', pattern)` - the standard cross-group
orchestration idiom (`delegate_to: "{{ lookup('inventory_hostnames',
'kube-master[0]') }}"`, templating a peer list, running one task against
another group's members) - was implemented, closing the last open
lookup-plugin gap. The "Deliberate limits" entry had it (and `config`,
already implemented since round 190) as requiring "modeling Ansible's
own config-resolution/inventory internals"; reading the real lookup
plugin's source showed it needs neither: it builds a throwaway
InventoryManager purely from variables['groups'] and runs the standard
host-pattern machinery over THAT. The `groups` magic var was already in
every task's vars context, so the whole implementation lives in
ExpressionEvaluator against the existing vars - no plumbing. Ported
faithfully from lib/ansible/inventory/manager.py (comma/colon terms,
`&`/`!` modifiers, fnmatch over groups then hosts, `~`-regexes,
inclusive `[A:B]` subscripts, empty result as a real `[]`, query()
returning the list form), differentially verified pattern-by-pattern
against the locally-installed ansible-core 2.19.4
(inventory_hostnames_lookup_spec.cr pins all 12). `groups` gained its
missing `ungrouped` key on the way. Remaining known divergence: the
wantlist/query list-in-msg rendering class shared with every other
list-valued lookup (`["a","b"]` vs real Python's `['a', 'b']`),
pre-existing and documented under Deliberate limits.

---

## Scope-cut re-examination batch: one of the three "cuts" wasn't a cut at all, two were stale entries, one was real (0.9.825)

Picking up the "Deliberate limits" list, the three cuts with the
strongest live evidence behind them were re-examined; only one actually
needed code:

- **`ansible.mariadb.mariadb_db`/`mariadb_user` (fauust.mariadb,
  round6002)** - implemented, but not by porting: pulling both
  collections' actual sources showed ansible.mariadb's modules are
  functionally byte-identical forks of the already-implemented
  community.mysql `mysql_db`/`mysql_user` (same argument spec, same
  wire-protocol implementation, same CLI dump/import flags and failure
  messages), so they resolve through `MODULE_ALIASES` onto the existing
  plugin binaries - the same call `raw:` -> `shell:` already made.
  Both the FQCN spellings and the bare short names resolve; a
  parse-time spec (`ansible_mariadb_alias_spec.cr`) pins that no
  "uses unimplemented plugin" warning can come back. The supported
  surface is the existing mysql plugins' surface (which was already the
  corpus's subset); ansible.mariadb-only extras (`salt:`,
  `resource_limits:`, `password_expire:`, `locked:`, `attributes:`)
  share the mysql plugins' own documented not-implemented list.
- **`community.docker.docker_compose_v2` (mrlesmithjr.blocky)** -
  genuinely unimplemented, now ported natively
  (`plugins/docker_compose_v2.cr`): `up` (always detached) /
  `down` / `restart` / the two-phase `up --no-start` then conditional
  `stop`, flag-for-flag from the real module's `get_up_cmd`/
  `get_down_cmd`/`get_restart_cmd`/`cmd_stop`, with `changed` computed
  from the command's own stderr events (only "working" statuses count -
  that is what makes a warm `state: present` converge to `changed=0`),
  the real module's file/version/project-dir validation messages, and
  check mode via `--dry-run`. Verified structurally by specs that need
  no daemon; the live up/stopped/absent idempotency spec
  (`docker_compose_v2_spec.cr`) pends cleanly where the docker-compose
  provider cannot reach a daemon and needs a real-host confirm run
  (mrlesmithjr.blocky) before the cut counts as fully closed.
- **Legacy free-form `action:` task syntax** - NOT implemented this
  round because it was already implemented (round 192: free-form
  string form, dict form, and the runtime-templated module name), and
  the Deliberate-limits entry had simply drifted. Deleted rather than
  re-implemented. Same for most of the "Unimplemented collection
  modules" bullet: `community.rabbitmq.rabbitmq_plugin/_user` and
  `community.general.redhat_subscription` were natively ported in
  round 196 (0.9.631) and both roles re-verified clean afterwards -
  only `ansible.mariadb.*` in that bullet was still real.

`ROLES_TESTED.md`'s rows for `fauust.mariadb` and `mrlesmithjr.blocky`
still describe the pre-fix runs; both need a confirm-phase re-run
before their status changes.

---

## RHEL-round gap triage: all 3 open gaps root-caused and fixed (0.9.818 - 0.9.823)

Each of the three open gaps from round 65000+ got a root cause and a
fix, verified live against Kata Rocky 9.6 VMs:

- **`@group` package syntax** was never a dnf limitation - the OS-
  agnostic `package:` plugin's `single_name` flag only treated a
  space-free string as one atomic name, so the loop item
  `@Development tools` fell into the legacy multi-name path, reached
  `dnf install` unquoted as two tokens, and dnf rejected "tools".
  Fixed by treating any `@`-prefixed name as atomic, quoting every
  parsed name element individually, making `dnf group list installed`
  matching case-insensitive (comps metadata capitalizes `Development
  Tools`; the spec doesn't), and dropping the now-dead `shell_name`
  helper. Confirmed live: `andrewrothstein.gcc-toolbox` cold run
  installs the group, warm run converges to `changed=0`.
  **0.9.823 follow-up**: the multi-element list shape
  (`["gcc", "@Development tools"]`) was NOT actually fixed by the
  0.9.818 pass despite the commit message's claim - `name:` from a
  literal YAML list arrives here comma-joined
  (`playbook_parser.cr`'s `stringify_value`), so `parts` correctly
  split `["gcc", "@Development tools"]` apart, but the final `names`
  array was re-derived by space-splitting the ALREADY-joined `name`
  display string instead of using `parts` directly - refragmenting
  the group right back into `["gcc", "@Development", "tools"]` and
  reproducing the exact original "Unable to find a match: tools"
  bug. Confirmed both ways live on a fresh Kata Rocky 9.6 VM (fails
  with the pre-0.9.823 code, installs + converges to `changed=0`
  with it) - found during review before merging this branch.
- **`pip:` pip3 discovery**: real Ansible's `_get_pip` first runs pip
  as `python3 -m pip` whenever the target interpreter can `import
  pip` and only PATH-searches a `pip3` binary as a fallback; this
  engine hard-required the binary via `which` (which minimal hosts
  don't even ship). Discovery now mirrors `_get_pip`'s order
  exactly (absolute `executable:` trusted as-is, bare `executable:`
  PATH-checked, then pip-module, then `pip3`), via
  `sh -c 'command -v ...'` so hosts without `which` still work.
- **`geerlingguy.postgresql`'s service-start failure**: not a
  service/daemon bug at all. The role's
  `postgresql_auth_method: "{{ ansible_fips | ternary('scram-sha-256',
  'md5') }}"` flows into pg_hba.conf, and `ansible_fips` was simply
  never gathered - the ternary rendered the literal text "undefined"
  into every host line, and postmaster refused to start with `invalid
  authentication method "undefined"` while every earlier task looked
  healthy. Fixed by gathering `ansible_fips` as a genuine JSON bool
  (true iff /proc/sys/crypto/fips_enabled reads exactly "1", real
  Ansible's FipsFactCollector shape; a "False" string would be truthy
  under Jinja2 and flip ternary onto the FIPS branch everywhere).
  Confirmed live: full role run on a fresh Kata VM finishes
  `ok=27 changed=9 failed=0 skipped=11` - byte-identical to real
  ansible-playbook's recap from the round.

---

## Scope-cut clearing batch: five deliberate limits turned into implementations (0.9.818 -> 0.9.822)

Five entries from "Deliberate limits" below had each accumulated live
evidence against their own "revisit only if" clauses, so they were
implemented (each in its own commit; the per-item detail is in the
commit messages and the specs):

- **`ansible.utils`'s ipaddr filter family** (`ipaddr`, `ipwrap`,
  `ipv4`, `ipv6`, `ipsubnet`, `ipmath`, `next_nth_usable`,
  `previous_nth_usable`, `network_in_network`, `network_in_usable`,
  `ip4_hex`) - every query mirrored against the installed
  ansible-core 2.19.4 + ansible.utils + netaddr 1.3.0 probed live,
  including the version's own bugs (queries not in the plugin's query
  map error with the real "unknown filter type"; `::1 | ipaddr('ipv4')`
  really is `0.0.0.1/32`). One shared core serves both templating
  engines.
- **Role-private `library/*.py` custom modules run on the target with
  the target's own python3** through a new py_module plugin (the same
  transport every other plugin uses) instead of being skipped - third
  party COLLECTION modules remain the cut. An unavailable module's
  params are now parsed at parse time (they are the module's argument
  dict), and a python module behind a false `when:` still skips and
  never pollutes the exit code.
- **firewalld immediate changes against a live daemon** go through
  `firewall-cmd` (a D-Bus client - no binding work needed); requests
  split into runtime/permanent contexts like the real module, and a
  `target:` operation in the immediate context now FAILS with the real
  module's "Zone operations must be permanent..." (previously silently
  serviced offline - more lenient than real Ansible).
- **hostvars attribute misses raise in Crinja renders** under strict
  templating, matching real Ansible's HostVarsVars wrapper (real
  Ansible's exact failure text verified live on both engines); the
  strictness rides on the hostvars value itself, so plain dicts stay
  lenient even under strict.
- **`openssl_publickey_info` and `openssl_csr_info`** - the two
  remaining "read-only and cheap" community.crypto modules; both result
  shapes mirrored field-by-field against real community.crypto 3.1.1.

---

## 200-role regression round finds 4 latent bugs (0.9.814 - 0.9.817)

Ran a 200-role regression round (queue drawn from `ROLES_TESTED.md`'s
previously-"✅ Fixed" roles, to check for reversions) via
`krikri-role-tester`. All 4 real findings turned out to be pre-existing,
previously-undiscovered bugs the broader role selection happened to
exercise for the first time - not reversions of anything that used to
work (each affected role's earlier fix addressed a *different* bug
earlier in the same role, before ever reaching the code path below):

- **`file:`'s state=file rejected any non-regular-file path** ("Path
  exists but is neither a regular file nor a directory"), including Unix
  sockets - `robertdebock.docker`'s own "Change group for docker socket"
  handler failed against a real `/var/run/docker.sock`. Real Ansible's
  `get_state()` defaults every non-directory, non-symlink path to "file"
  and applies owner/group/mode via chown/chmod, which work on any inode
  type. Fixed by dropping the regular-file restriction (0.9.814).
- **`ansible_product_version` (a DMI fact) was never gathered at all** -
  `robertdebock.bios_update`'s own rescue: block references it in a
  debug: msg, which real Ansible resolves fine but this engine raised
  "'ansible_product_version' is undefined". Fixed by reading
  `/sys/class/dmi/id/product_version`, same "NA" fallback as the
  existing `ansible_system_vendor` DMI fact (0.9.815).
- **`changed_when:`/`failed_when:` couldn't see the task's OWN
  `stdout_lines`/`stderr_lines`** - `register_result` adds these fields
  to a registered variable for LATER tasks, but `apply_changed_failed_when`
  built its own eval_context from the raw, un-augmented plugin result.
  `buluma.netdata`/`mrlesmithjr.netdata` both hit this identically on
  their "install | Use netdata dependencies installation." task's
  `changed_when`. Fixed by sharing the augmentation logic between both
  call sites (0.9.816).
- **`loop_control.index_var` never reached an included file's own
  tasks** - `run_include_tasks_once`/`run_include_role_once` propagated
  the loop item and `loop_var` into each included task's own vars, but
  never `index_var`. The including task's own name/vars: rendered fine
  regardless (masking the gap), until `riemers.gitlab-runner`'s own
  `config-runner.yml` referenced the index directly and got
  "'runner_config_index' is undefined". Fixed by also copying
  `index_var`'s bound value, in both the include_tasks and include_role
  loop paths (0.9.817).

All 4 confirmed fixed via a fresh confirm round (0.9.817) against real
`ansible-playbook`: `robertdebock.bios_update`/`.docker`,
`mrlesmithjr.netdata`, and `riemers.gitlab-runner` byte-identical cold
and warm on both engines. `buluma.netdata`'s confirm run hit an
unrelated, real `netdata-installer.sh` exit-1 failure further into the
role (a genuine build/resource issue on this specific ~24-minute-build
role, already documented as environment-sensitive) - the actual fixed
task ("install | Use netdata dependencies installation.") itself
succeeded identically to real Ansible; real Ansible's own cold run for
this confirm didn't even finish within the harness's 900s timeout, so
there's no valid comparison at the later step anyway.

Also found (not a krikri-playbook bug): `testing/kata/kata-host.sh`'s
`force_down` leaked orphaned qemu/virtiofsd processes on teardown,
eventually filling the control machine's `/dev/shm` and causing every
LOCAL `ansible-playbook` run to fail instantly with an unrelated-looking
"No space left on device" - registering as a wall of false DIVERGENT
results in the first regression-round attempt. Fixed in the harness
(`2281c8fd`), unrelated to krikri-playbook's own version.

---

## The last open gap closed: `lookup('community.general.random_string', ...)` implemented (0.9.812 -> 0.9.813)

Closed the long-standing open gap (juju4.pocketid, round 60151): the
lookup was entirely unimplemented and silently resolved to the literal
string `"undefined"`, which the role's `secret:` then wrote to disk as
the real secret - cold recaps were byte-identical (`ok=23 changed=14
failed=0 skipped=7` both engines), so nothing looked broken while the
value on disk was the sentinel text. `ExpressionEvaluator` now
implements the lookup with the real plugin's full option set and
pipeline: pool built from the `upper`/`lower`/`numbers`/`special`
flags (all default true), `ignore_similar_chars`/`similar_chars`
filtering, `override_all`/`override_special` pool replacement,
`min_numeric`/`min_lower`/`min_upper`/`min_special` guaranteed-
minimum characters drawn FIRST in the real plugin's fixed order,
remainder filled from the full pool, shuffle skipped when `seed=` is
given (the real plugin's documented quirk - seeded output keeps min_*
characters clustered at the front), then optional `base64` encoding.
The fully-qualified `community.general.` name is stripped to the bare
name the same way `ansible.builtin.` already was, and the real
plugin's empty-pool raise ("Available characters cannot be None,
please change constraints" - which fires even at zero remaining
count) is mirrored exactly. Regression specs in
`spec/unit/expression_evaluator_spec.cr` (FQCN + variable kwargs
base64 shape, default length, seed reproducibility, min_* guarantees,
empty-pool raise).

---

## The dotted-index "undefined"-string collision closed with a real undefined type (0.9.811 -> 0.9.812)

Closed the long-standing open gap: a real string value that happens to
equal the literal text "undefined" was misread as a genuinely undefined
reference on dotted numeric-index access (`s2.stdout_lines.0` after
`command: printf 'undefined'` + `register: s2` - juju4.pocketid, round
60151), failing the task under strict-undefined where real Ansible
renders the string, while the bracket form `s2.stdout_lines[0]` was
always fine. Root cause: `ExpressionEvaluator`'s String return type
represents "no value" as the sentinel text itself, and the
strict-decision seam re-checked its own rendered output against that
same comparable string. The fix threads a real `Undefined` marker type
(`variable_substitutor/undefined.cr`) through that seam:
`ExpressionEvaluator#evaluate_or_undefined` returns `Undefined::INSTANCE`
only when the render was the sentinel AND the undefined-typed
structural resolver (`VariableLookup#resolve`, nil on a miss) also
finds no value - never a string comparison - and
`Krikri.expression_resolves_to_undefined?` (strict chained-subscript
raise) and `dict_chain_key` (dynamic dict-key rendering, which also
upgrades a real "undefined"-keyed dict's error message to real
Ansible's attribute-miss wording) both consume it. Shapes `resolve`
can't parse degrade to the old behavior, not to a regression.
Regression specs in `spec/unit/undefined_sentinel_collision_spec.cr`
(dotted/bracket, strict/lenient, and genuinely-undefined-still-raises).

---

## A crash found investigating the unarchive: fix, unrelated to it (0.9.810 -> 0.9.811)

`TaskExecutor#inline_copy_source_content`'s `Dir.exists?(src)` check for a
controller-local `copy:` (no `remote_src:`) crashed the ENTIRE binary
with an unhandled `File::AccessDeniedError` when `src:` names a path this
process can't even stat (found live, by accident, while building a test
fixture for the unarchive: fix below: a `copy:` task pointed at a path
under `/root` while running as a non-root controller user). Real Ansible
fails just that one task with a permission error; every OTHER exists/
size check in this same function already had a `rescue` (the very next
line, `File.size(src) rescue nil`) - `Dir.exists?` was the one call that
didn't. Fixed by rescuing it the same way and falling through to the
already-rescued size check and the module's own src-open attempt, which
produce the normal per-task failure instead. No unit spec - the crashing
path only triggers for a REMOTE (non-`ansible_connection=local`) host,
which `inline_copy_source_content` itself early-returns for on local
connections, and `PluginSpecHelper` (this repo's plugin-level spec
harness) always runs locally - verified live instead (a real remote
Kata-host playbook run went from an unhandled-exception crash trace to a
clean `failed: [...]` task).

## `unarchive:` warm-rerun open gap closed: Uid/Gid differs as non-root (0.9.809 -> 0.9.810)

Re-root-caused `juju4.polarproxy`'s own divergence (RHEL-family round
60152) live against a fresh Rocky 9.6 Kata host with the real PolarProxy
tarball, since the original round's Atlantic.net host was torn down
before the exact `tar --compare` output could be captured. Reproduced
exactly: extracting as a non-root `become_user:` (matching the role's own
task, which sets `mode: '0755'` and `remote_src: true` but no owner:/
group:) and running `tar --compare` produces `Uid differs`/`Gid differs`
lines for every file, alongside the already-handled `Mode differs`.

Root cause: real Ansible's own `TgzArchive#is_unarchived` (unarchive.py)
only treats a Uid/Gid-differs line as meaningful when `is_unarchived`
itself is running AS ROOT (`if run_uid == 0 and not
self.file_args['owner'] and OWNER_DIFF_RE...` - note the `run_uid == 0`
half, not just the owner:/group: check the previously-fixed round-134
exemption already covered). Extracting as a non-root user can never set
arbitrary file ownership anyway - every extracted file ends up owned by
the extracting user regardless of what the archive itself records - so a
Uid/Gid mismatch against the archive's embedded owner is neither a real
change nor fixable, and real Ansible ignores it entirely in that case.
`tar_changed?` (`plugins/unarchive.cr`) never checked the extracting
user's own uid, so it treated every such line as meaningful regardless,
making any `remote_src: true` unarchive task with no owner:/group: given
permanently non-idempotent under `become_user:` to a non-root account -
true of essentially every real-world release-tarball install role. Fixed
by gating the Uid/Gid exemptions on `LibC.getuid == 0`, matching real
Ansible's own check exactly. Live-reverified on a fresh Rocky 9.6 Kata
host: `ok=4 changed=4` cold, `ok=4 changed=0` warm - byte-identical to
real ansible-playbook's own recap on the same host. Regression:
`spec/integration/unarchive_spec.cr` (a `tar --owner=/--group=` fixture
that fakes a foreign embedded owner without needing real root to build).

## `imntreal.smallstep_ca` open lead closed: `/dev/tty` + `lookup('password', '/dev/null')` (0.9.808 -> 0.9.809)

The round-60300-60499 open lead ("`step ca init` fails with *error
allocating terminal: open /dev/tty*") turned out to be **two** independent
defects stacked on each other. Both are fixed; the role now runs
end-to-end and is idempotent.

- **`lookup('password', '/dev/null')` returned the empty string** - and
  this, not the tty, is what actually broke the role. `/dev/null` is real
  Ansible's own documented idiom for "generate a fresh random password and
  do NOT persist it"; its password lookup plugin special-cases that exact
  path for both the read-back and the write. Both of this engine's
  independent lookup implementations (`ExpressionEvaluator#
  evaluate_password_lookup` and `JinjaFilters.password_lookup`) had only
  the generic "file exists -> read it back" branch, and `/dev/null` does
  exist and reads as `""`. The role's CA and provisioner passwords come
  from exactly that idiom, so it wrote two EMPTY password files, and
  `step ca init --password-file=<empty>` then fell back to prompting for a
  password interactively - which is why it wanted a terminal at all. Real
  ansible-playbook never reaches the prompt because its password files are
  never empty. Fixed in both implementations. Regressions:
  `spec/unit/expression_evaluator_spec.cr` and
  `spec/unit/crinja_renderer_spec.cr` (the two evaluators do not share
  code, so the case is pinned in each).
- **No `/dev/tty` for anything a `command:`/`shell:` task spawns.** Real
  ansible-core's ssh connection plugin requests a remote pty for ordinary
  module dispatch (`ssh.py`: `if not in_data and sudoable and use_tty:
  args = ('-tt', self.host, cmd)`, and `sudoable` is True for everything
  except its internal `dd`-based put_file/fetch_file helpers), so the whole
  remote process tree there has a controlling terminal. Confirmed live on
  ansible-core 2.19.4 against a Rocky 9.6 Kata host: with default config a
  remote `echo x > /dev/tty` succeeds, and with `ANSIBLE_PIPELINING=True`
  (which sets `in_data`, suppressing `-tt`) the same task reports
  `/dev/tty: No such device or address` - i.e. real Ansible's own default
  is the tty-present behavior. `SSHManager` passes no `-t`/`-tt` anywhere
  and deliberately still doesn't: that same channel carries every plugin's
  JSON `PluginResult` on all three transports (one-shot exec, the `bash -s`
  batch script, and the length-prefixed persistent-daemon pipe), and a pty
  merges stderr into stdout, can translate LF to CRLF, and changes
  buffering - a result-protocol corruption risk for all 107 plugins rather
  than for the one that needs a terminal. Fixed instead entirely on the
  target, inside the plugin process: new
  `src/krikri/plugin_helpers/controlling_tty.cr` manufactures its own pty
  (`posix_openpt` -> `setsid` -> `TIOCSCTTY`) so the process and everything
  it spawns has a controlling terminal, while stdin/stdout/stderr stay
  exactly the pipes the transport handed over. `command:` and `shell:` call
  it before spawning; it is idempotent (the persistent daemon serves many
  tasks from one process and acquires at most one), a no-op when a terminal
  already exists (local connection from a real shell), and silently leaves
  today's behavior in place if any step fails. The pty master is drained
  and discarded - real Ansible's equivalent bytes end up mixed into ssh's
  stdout and are thrown away when the module JSON is parsed out of it -
  and the slave is put in non-canonical mode with `VMIN=0`/`VTIME=0` so a
  read of `/dev/tty` returns immediately rather than blocking. That last
  part is best-effort: a program that puts the terminal into raw mode
  itself (`step` does) can still block waiting for input it will never get
  - exactly as it does under real Ansible's `-tt`, verified live (a real
  `ansible-playbook` task reading `/dev/tty` hits its own task timeout).
  Live-verified on a fresh Rocky 9.6 Kata host, both directions: the role
  fails at `Initialize CA` before the fix and runs clean after
  (`ok=28 changed=19` cold, `ok=26 changed=0` warm), and a purpose-built
  21-task `command:`/`shell:` no-regression play (multi-line stdout with
  separate stderr, byte-exact base64 comparison of both streams, a 16k-line
  stdout, `argv:`/quoted args, `stdin:`, a 1 MB write to `/dev/tty`, and an
  `isatty(stdout)` check) passes identically under krikri-playbook and real
  ansible-playbook, and under krikri on all three transports (default
  batching, `--no-batching`, `--persistent-daemon`). Regression:
  `spec/unit/controlling_tty_spec.cr` covers the plugin-side half; the
  transport half (no pty requested, results uncorrupted across the three
  paths) has no spec and is verified live instead, same convention as the
  real dpkg/apt/crontab-mutation cases.

## Two RHEL-family open leads closed: template include-path + set_fact self-reference (0.9.807 -> 0.9.808)

- **A `{% include %}`/`{% extends %}` path given relative to the ROLE ROOT
  (e.g. `{% include 'templates/base.j2' %}` from a template that itself
  lives directly in `templates/`) wasn't found.** `TemplateActionPlugin`'s
  Crinja loader searchpath climbed from the including template's own
  directory up to and including the role's `templates/` root (fixed for
  the sibling-file case in round 196), but never added the role root
  itself - real Ansible's Jinja2 loader searches both. Found via
  `smlloyd.authselect` (RHEL-family round 60487): `RedHat-9-user-
  nsswitch.conf.j2` (living directly in `templates/`) does `{% include
  'templates/base-user-nsswitch.conf.j2' %}`, which only resolves if the
  loader also searches the role root. Fixed by adding the templates root's
  parent directory to the searchpath. Live-reverified against the actual
  role on a fresh Rocky 9.6 Kata host: the role now runs to completion
  (`ok=7 changed=2` cold, idempotent `changed=0` warm) instead of failing
  at the template task. Regression: `spec/integration/
  template_include_search_path_spec.cr`.
- **A `set_fact:` task's own `changed_when:`/`failed_when:` couldn't see
  the fact that same task had just set.** `apply_changed_failed_when`
  evaluates against `vars_context` plus a `register:` result if any, but a
  `set_fact:` result's own newly-set facts (carried under
  `ansible_facts`, see `SetFactActionPlugin`) were only merged into
  `vars_context` by the caller AFTER this function returns - real Ansible
  evaluates `changed_when:` against a context that already has them. Found
  via the same `smlloyd.authselect` live run once the template bug above
  was fixed: `set_fact: {authselect_current_profile: ...}` with
  `changed_when: ... or authselect_current_profile != ...` raised
  `'authselect_current_profile' is undefined` where real Ansible resolves
  it. Fixed by merging a set_fact result's `ansible_facts` into the
  evaluation context before evaluating `changed_when:`/`failed_when:`.
  Regression: `spec/integration/set_fact_changed_when_self_reference_spec.cr`.

## Perf/security hardening batch from a parallel worktree (0.9.797 -> 0.9.806)

Ten commits developed in a sibling worktree (`remaining-fixes` branch),
reviewed and merged into `main`: plugin binaries now stage under a
per-connecting-user directory (mode 0711, ownership/symlink-verified before
use) instead of one shared predictable `/var/tmp` path - closes a
CVE-2014-3498-class local-tampering issue. `set_fact` results are now kept
for the whole run instead of being reset per play, matching real Ansible's
precedence (a two-play repro against ansible-core 2.19.4 confirmed play 2
should see play 1's `set_fact`, not a same-named `vars:` entry). A
mutually-templated variable pair (`a: "{{ b }}"` / `b: "{{ a }}"`) now fails
the one task cleanly instead of crashing the whole process. Perf-only:
per-loop vars-context rebuilding and a `vars_files` cache leak fixed, the
expression/regex memoization caches are now bounded instead of growing
without limit over a long run, `apt:`/`package:` batch their `dpkg-query`
into one round trip instead of one per package, `user:` reads `/etc/shadow`
once per task instead of up to three times, directory-inventory sources are
parsed once instead of per-lookup, and three divergent copies of a
dotted-path hash walker are down to one shared implementation. Full spec
suite clean (2651 examples, only the pre-existing Docker-daemon-required
integration failure, unrelated) after the merge.

## Round 60300-60499: RHEL-family 200-role batch (0.9.795 -> 0.9.797)

200 previously-untested Galaxy roles (sourced live from Galaxy's own API,
ranked by download count, cross-checked against every role name already in
`ROLES_TESTED.md`) run against Rocky 9.6 via `krikri-role-tester`, split
across the Kata and Atlantic.net backends concurrently. 146 CLEAN, 46
DIVERGENT, 8 GALAXY_MISSING. Full per-role detail and timings are in
`ROLES_TESTED.md`'s own round table - this narrative covers only the two
real engine bugs found and fixed, plus new open leads.

- **`dnf:`/`yum: state: latest` failed outright on a not-yet-installed
  package.** `handle_update` (shared by both plugins via
  `PluginHelpers::RpmPackage`) unconditionally shelled out to
  `dnf/yum update <name>` for every requested name regardless of whether it
  was already installed - `update` only ever applies to an already-present
  package, so a fresh `dnf update temurin-21-jdk` on a host that's never
  had it hard-fails ("No match for argument", "No packages marked for
  upgrade") where real Ansible's dnf module treats `state: latest` as
  "install if absent, else upgrade" and succeeds. Found via
  `alvistack.openjdk` (round 60420). `package.cr`'s own separate dnf/yum
  dispatch already had this right (its own comment names an earlier,
  independently-fixed instance of the identical bug class in `apt.cr`) -
  only the standalone `dnf.cr`/`yum.cr` plugins' shared helper had the
  live bug. Fixed by reusing the same `classify_install_packages`/
  `run_install_batch`/`run_update_batch` helpers `handle_install` already
  used correctly, routing "not installed" to an install batch instead of
  an update batch. Live-reverified on a fresh Rocky 9.6 Kata host: installs
  cleanly, idempotent warm rerun (`ok` not `changed`). No unit spec (real
  dnf mutation against a live package manager, same class as the existing
  apt-mutation exemption) - verified live instead.
- **A blank `enablerepo:`/`disablerepo:` value crashed the task instead of
  being a no-op.** `build_dnf_options` passed an empty string straight
  through as a bare `--enablerepo=` flag, and dnf's resulting `Error:
  Unknown repo: ''` didn't match the existing unknown-repo-tolerance retry
  (`/Unknown repo: '([^']+)'/` requires at least one character inside the
  quotes) - so the task hard-failed instead of the retry stripping the
  flag and continuing, which is what happens for a NAMED unknown repo
  (the buluma.elasticsearch_curator fix this retry exists for in the
  first place). Real Ansible's dnf module simply omits a blank repo name
  entirely. Found via `gabops.cron` (round 60447, an `enablerepo:` sourced
  from a var that resolves empty on this role's default path). Fixed by
  skipping blank entries in `build_dnf_options` before they ever reach the
  command line. Live-reverified on a fresh Rocky 9.6 Kata host.
- **New open leads, not fixed this round** (see `ROLES_TESTED.md`'s round
  table for the exact role/evidence):
  - `levonet.ci_github_pr_description`: real Ansible's `length` filter
    fails on a `None` input; krikri's own `length` filter appears to
    tolerate it and lets the task pass instead of failing the same way.
  - `smlloyd.authselect`: a `.j2` template's relative include/extends path
    resolves under real Jinja2 but Crinja's `FileSystemLoader` reports it
    not found - a template-search-path gap in `CrinjaRenderer`.
  - `inmotionhosting.monit`: a looped task's indirect variable lookup by
    name (`item.var_name` used to reference e.g. `apache_daemon`) resolves
    under real Ansible but is reported undefined here - likely an
    `ExpressionEvaluator` indirect-lookup gap.
  - Several roles (`inmotionhosting.mysql/.apache/.php_fpm`,
    `geerlingguy.php-tideways`, `GROG.fqdn`, `criecm.common`,
    `CTL-Fed-Security.freeipa-client`, `lenovo.lxca-config`,
    `RedHatOfficial.rhel8_pci_dss`) diverged but weren't individually
    root-caused this round - flagged in `ROLES_TESTED.md` for a follow-up
    pass rather than guessed at here.
- Confirmed, not new: `local_action:`/`action:` not being parsed (already
  an open gap above) hit again via `xlab_si.nuage_remove_entity`/
  `.nuage_create_entity` - 3rd and 4th confirming roles, no new evidence
  needed. Role-private custom Python modules/filter plugins (already a
  deliberate limit below) hit again via `amtega.*`'s own `_check_platform`
  and `wcm_io_devops.conga_*`'s own `conga_facts` (both already documented
  under `wcm_io_devops.aem_dispatcher` in `ROLES_TESTED.md`) and
  `oasis_roles.system_repositories`'s own `filter_plugins/exclude.py`.

## Round 60200: security/robustness review batch (0.9.795)

A broad review pass across plugins and the executor core, unrelated to
the RHEL-family round above - reviewed, verified live (build + full
`crystal spec` + several manual repros against a real Kata host), and
merged in from a parallel worktree. Highlights:

- **Shell-injection fixes**: `user:`/`plugin_helpers/user_state.cr`
  quoted every value (`comment:`/`shell:`/`home:`/`groups:`/etc.) via a
  new shared `Shell.single_quote` instead of `String#inspect` (which
  does NOT escape `$`/backticks) - a `comment: 'a$(cmd)b'` used to run
  `cmd` as root. Verified live: the payload now lands as literal GECOS
  text, no command execution. Same `shell_single_quote` treatment
  extended to `service:`/`file:`/`cron:`'s own remote_exec calls.
- **Predictable-tmpfile races**: `cron:`'s crontab install, plugin
  local-staging (`plugin_manager.cr`), and async job status
  (`async_jobs.cr`) all moved to `Random::Secure`-named temp files with
  atomic rename and 0600/0700 perms - a local user could previously
  pre-create/symlink a numerically-predictable path.
- **A genuine YAML-inventory bug**: only the top-level `all:` group was
  ever parsed - a legal inventory file whose top-level key is a plain
  group name (`webservers: {hosts: ...}`, no `all:` wrapper) silently
  produced an empty inventory. Now iterates every top-level mapping key.
- **A dispatcher hang**: an exception escaping `execute_task` inside the
  per-host worker-pool fiber used to never signal completion back to
  the dispatcher - the whole run hung forever instead of aborting.
- **`run_once:` pinned to `@hosts.first`**: if that host was
  unreachable/halted, a `run_once:` task never ran anywhere. Now
  elected on first arrival among active hosts.
- **`until:`/`retries:` silently dropped on a looped task** - the
  loop-items branch returned before the until: branch was ever reached;
  each loop item now retries independently, matching real Ansible.
- **Filter/templating correctness**: `min`/`max` now compare natively
  (numbers by value, strings lexicographically) instead of coercing
  every item through `numeric()` (`['b','a'] | min` returned `'b'`);
  `sum([1,2,3])` stays an int (`6`, not `6.0`) unless a float is
  involved; `default(True)` (Python's capital-T spelling) now honored;
  a quote-aware operator split fixes `!=`/`==` embedded inside a quoted
  operand being misparsed as the comparison itself; `join()` no longer
  raises `TypeCastError` on a non-string list element.
- **`package:`'s `state: latest` + `check_mode`**: `dnf check-update X
  || yum check-update X` swallowed dnf's exit-100 (falls through to the
  yum branch, whose own exit code then wins) - a pending update
  reported "already at latest" in check mode.
- **`apt:`'s `state: latest` + `check_mode`**: `grep -i upgrade`
  matched the always-present "N upgraded, M newly installed..." summary
  line of `--simulate` output, so check mode never converged to `ok`.
- **`copy:`**: identical-content short-circuit skipped `mode:`/`owner:`/
  `group:` reconciliation entirely (a content-matching file with the
  wrong mode stayed wrong forever); directory copy used a
  hidden-file-excluding glob, silently dropping dotfiles (`.env`,
  `.gitignore`, `.ssh/`) that real Ansible's `os.walk` includes.
- **`file:`**: `state: touch` check-mode verdict was unconditionally
  "changed" instead of mirroring the real run's `attrs_changed ||
  times_changed`; `state: absent` used `File.exists?` alone, which
  follows symlinks and so never removed a dangling one (real Ansible
  removes broken symlinks too).
- **Signal-killed child processes**: `Process::Status#exit_code` raises
  for a signal-terminated process - both `ssh_manager.cr` and
  `local_executor.cr`'s `run_with_timeout`/SIGKILL paths used to crash
  on this instead of reporting a result; mapped to the conventional
  128+signal value.
- **SSH transport**: `ConnectTimeout` was missing from the scp/rsync
  command lines entirely (only the interactive-ssh path had it); scp/
  rsync failures now include actual stdout/stderr in the raised error
  instead of a bare "failed to upload/download".
- **`inventory_parser.cr` perf**: two O(n²) host-dedup loops
  (`existing.name == host.name` linear scans) replaced with `Set`-based
  dedup; a `.sort!` on the memoized group-index cache was mutating the
  cache's own array in place.
- **`playbook_parser.cr` perf**: the ~110-entry `special_keys` array
  (plus two `.map` copies) was rebuilt from scratch on every single
  parsed task - hoisted into a `Set` constant built once at load.
- **`gather_facts:`/`delegate_facts:`/`run_once:`** now accept the same
  string-boolean forms (`"yes"`/`"no"`/etc.) `become:` already did via
  `parse_become_value`, instead of requiring a literal YAML boolean.
- **`group_by:`/`set_stats:`** (controller-side, no plugin binary) were
  missing from the same skip-list `reboot:` and the `debug:`-family
  action plugins already have - would have crashed the first time
  either ran on a non-local host ("Plugin binary not found").
- Removed a stray `STDERR.puts "MULTI-PROPAGATE..."` debug line that
  had been shipping in every real run's output.

---

## Round 60100: a filtered `with_items:` source stringified instead of flattening (0.9.794)

`geerlingguy.php`'s own `with_items: ["{{ php_conf_paths | flatten }}",
"{{ php_extension_conf_paths | flatten }}"]` (RHEL-family round 60100):
`deep_render_item`'s "whole input is one bare `{{ }}` expression,
preserve native type" fast path only recognized a bare/dotted VARIABLE
reference (`VariableLookup#resolve`), not one carrying a filter chain -
a source that's a single expression but has `| flatten` fell through to
the generic substitute path and got stringified, same as any mixed
literal-plus-expression text would. with_items's own built-in one-level
flatten only ever unwraps a real `Array`, so it silently no-op'd on the
now-stringified list, and `item` ended up bound to the whole
stringified one-element list instead of its single scalar path -
`file: {path: "{{ item }}", state: directory}` then reported `changed`
on an already-correct directory every single run (broken idempotency),
where real Ansible's actually-flattened, actually-scalar `item`
reported `ok`. Fixed by evaluating the filter chain through the
existing expression evaluator and re-parsing the result as JSON when it
looks like a list/dict, mirroring `resolve_loop_template`'s own
filter-chain fallback for the single-with_items-string case. New
integration spec verifies both the flattened item values and
idempotency (second run reports `changed=0`).

---

## Round 60113: `notify:` on `include_tasks:`/`include_role:` wrongly accepted (0.9.793)

The round-194 `TASK_INCLUDE_VALID_KEYWORDS` allowlist fix (see its own
entry above) deliberately kept `notify` on the accepted list "not one
any role in ROLES_TESTED.md currently depends on behaving the ansible
way" - `juju4.ansible_role_mattermost`'s own `include_tasks:
selinux.yml` with a `notify:` on the include line itself (RHEL-family
round 60113) is exactly that predicted case. Verified directly against
real ansible-core 2.19.4's own `TaskInclude.VALID_INCLUDE_KEYWORDS` /
`IncludeRole.VALID_INCLUDE_KEYWORDS` (neither lists `notify`) rather
than assumed, then removed it from the allowlist - a task's own
`notify:` elsewhere (including inside an included file) is unaffected,
only the include directive line itself notifying anything is now
correctly rejected with `'notify' is not a valid attribute for a
TaskInclude`, rc=4.

---

## Round 60105: `conflicting action statements` had the wrong exit code (0.9.792)

`jdauphant.ssh-config`'s `shell:`+`always_run:` task (the same
conflicting-action-statements parser abort documented in an earlier
round) exited 1, not real Ansible's own rc=4 for this class of error -
`playbook_parser.cr` raised the shared `RemovedActionError` for it,
which is correct for the removed-action-PLUGIN case (`include:`, real
Ansible's own rc=1) but wrong here: ModuleArgsParser's "conflicting
action statements" is a genuine PARSER error. Split into its own
`ConflictingActionStatementsError` (rc=4), propagated through all three
of `RemovedActionError`'s existing per-task/per-play/import bypass
sites the same way. The existing regression spec for this case had
never itself been verified live and asserted the wrong exit code
(1) - corrected along with the fix.

---

## Round 60128: `sysctl:` broke on a space-separated value (0.9.791)

`juju4.harden_sysctl`'s own `net.ipv4.ip_local_port_range: "32768 65535"`
task failed the live `sysctl -w` call - `apply_kernel_value` built
`sysctl -w name=value` with `value` unquoted, so a space-separated value
split into two shell words; sysctl set only the first token and then
choked on the second as a bogus bare key ("invalid syntax"), failing the
whole command where real `ansible.posix.sysctl`'s own quoted write
succeeds. Fixed by shell-quoting the value (`Process.quote`). New spec
re-applies the key's own current live value (read from `/proc/sys`
first) so it's a verified no-op against the real kernel rather than a
mutation needing undone - `pending!`s on a non-root spec run or a
missing `/proc/sys` path, verified live as root against a Kata Rocky
guest instead (see git log).

---

## Round 60086: `package:` rejected `state: installed`/`removed` (0.9.790)

First round run against the new Rocky/RHEL-family Kata+Atlantic backend
(200 roles, `ROLES_TESTED.md`). `bertvv.rh-base`'s `package: state:
installed` task failed with this engine's own "Invalid state: installed.
Must be present, absent, or latest" instead of installing - the generic
`package:` module (`plugins/package.cr`) never normalized the
`installed`/`removed` aliases real Ansible's package/dnf/yum modules
document (`state: absent, installed, latest, present, removed`); `dnf:`/
`yum:` already did this correctly via their shared `RpmPackage#normalized_state`
helper, `package:` just never called it. Fixed by normalizing at the top
of `package.cr#execute`, same as the RPM-family plugins. 2 new specs
(check_mode, no real package manager assumed for the "not installed"
side).

Also fixed the round's own environment, not the engine: the new Rocky
kata image's `dnf install` baked NetworkManager's podman-build-time
resolver into `/etc/resolv.conf`, meaningless inside the kata guest's
real static network - every dnf op on a booted Rocky guest failed DNS
resolution, which made `juju4.upgrade_pkgs`'s `until:`-guarded package
install hang past the harness's 15-minute timeout where real Ansible
failed fast. See `testing/kata/README.md`'s Rocky section for the fix
(a boot-time tmpfiles.d symlink, since a Containerfile `RUN` write to
that exact path doesn't survive the build - podman bind-mounts its own
resolv.conf over it for `RUN`'s duration and excludes it from the
committed layer).

---

## Round 50000: the "partial" scope cuts closed - community.crypto info modules, meta: end_batch/end_role/reset_connection, the service use=systemd message (0.9.789)

Worked through the items KNOWN_MISSING itself called cheap or
message-level, leaving only the ones with real architectural reasons to
stay:

- **`openssl_privatekey_info`, `x509_certificate_info`,
  `openssl_publickey`, `get_certificate` implemented; `openssl_pkcs12`
  grew `action: parse`** (new plugins under `plugins/`, sharing the new
  `src/krikri/plugin_helpers/x509_cert_info.cr` parser - both info
  modules need the same field set, so it lives once, driven by the
  `openssl` CLI like every other crypto plugin here). Field shapes were
  matched against the real modules' own sources (community.crypto
  3.1.1, installed locally): the sorted list extensions, the OpenSSL LN
  name vocabulary, ASN.1 TIME validity spelling, all-algorithms
  colon-hex fingerprints, `can_load_key`/`can_parse_key`/
  `key_is_consistent` trio, and `action: parse`'s converter semantics
  (private key first, then certificates). One deliberate divergence:
  `extensions_by_oid` (x509_certificate_info) is omitted - it needs an
  ASN.1 decoder this tree does not carry. Values wider than Int64 (RSA
  moduli, ECC coordinates, big serials) render as exact decimal strings
  instead of JSON numbers - this engine's result world is JSON::Any
  (Int64 at widest), and truncating digits would be worse than a
  string. 26 new integration specs; every return field differentialed
  against real Ansible output on generated key/cert material.
- **`meta: end_batch`, `end_role`, `reset_connection` implemented**
  (previously rejected at parse time as "execution-flow machinery this
  engine models differently"). `end_batch` is exactly end_play here -
  its one distinguishing behavior, ending only the current `serial:`
  batch, is meaningless while serial batching isn't modeled (verified
  against ansible-core 2.19.4's own strategy code: both call
  iterator.end_host for every play host; only end_play additionally
  raises AnsibleEndPlay, whose handling ends THIS play only).
  `end_role` (ansible-core 2.18+) skips the calling role's remaining
  tasks silently for the executing host - no banners, no recap
  counters, play tasks after the role keep running - keyed on the role
  INVOCATION (a fresh token per dynamic include_role: run; a looped
  include_role whose first item ends the role still runs the second
  item in full - verified live against 2.19.4, byte-identical task
  flow). end_role outside any role aborts the run with real Ansible's
  own parse-time error and rc=4 ("Cannot execute 'end_role' from
  outside of a role" - helpers.py's load_list_of_tasks; the check sits
  in krikri-playbook.cr's flattened-task walk, since this engine
  attaches role attributes only after parsing). `reset_connection`
  drops the host's persistent connection state (resident plugin daemons
  via the new `SSHManager.reset_connection`, plus the ssh
  ControlMaster socket underneath each) and, like real Ansible's META:
  vv-only result, counts in no recap bucket. Regression specs in
  `spec/integration/cli_spec.cr` (the old "reset_connection is not
  supported" assertion now pins frobnicate instead).
- **`service: use=systemd` forced on a non-systemd host now fails with
  real Ansible's "Service is in unknown state"** (systemd_service.py's
  own degenerate-status branch; verified byte-identical against
  ansible-core 2.19.4 inside a systemd-installed-but-not-PID-1
  podman container) instead of surfacing systemctl's own runtime
  error - the last of the three cosmetic-differences entries, now
  deleted from that list.
- **Left alone, deliberately:** `-M/--module-path` (honoring it means
  an arbitrary-Python-module runner - the long-standing scope cut),
  `RemovedActionError`'s wording (a moving target across
  ansible-core releases, no version-targeting concept exists), the
  firewalld D-Bus `immediate:` path (needs a real D-Bus client), and
  the remaining community.crypto modules (`luks_device` - needs
  cryptsetup state modeling; `acme`/`entrust` providers - real CA
  protocols; `openssl_pkcs12` export's `encryption_level:
  compatibility2022`; the `*_csr_info`/`crl` family - nothing in the
  corpus or docs above asked for them).

---

## Round 45000: `ConditionalEvaluator` compile-time filter-name validation (0.9.788)

Closed the last open gap: `jriguera.configdrive` (round 20014). Real Jinja
resolves every filter name referenced ANYWHERE in a `when:` expression when
it compiles the template - before any `and`/`or` short-circuiting happens -
so `when: X is defined and not X is none and Y|success and ...` with `X`
undefined hard-fails on the unknown `|success` filter (an Ansible 1.x filter
removed from modern ansible-core) even though the first clause is already
`False` and a lazy evaluator would never reach it. `ConditionalEvaluator`
previously discovered filters lazily while evaluating operands, so this
silently skipped instead. Fixed with a quote-aware byte-level pre-pass
(`ConditionalEvaluator.validate_filter_names`) that scans the whole
condition string for `| filtername` references up front and validates each
against a name registry covering both engines that can resolve one -
`FilterEngine::KNOWN_FILTER_NAMES` (kept in sync with its `#apply` dispatch
by a spec that runs every listed name through it) and Crinja's own filter
library (`CrinjaRenderer.known_filter?`) - raising the same
`UnknownFilterError` a reached clause already raises. Deliberately does NOT
validate `map()`/`select()`'s own inner filter-name arguments, since real
Jinja resolves those at runtime, not compile time - an unreachable one is
genuinely never an error there (regression-tested). 10 new specs cover the
buried-vs-reached cases, quoted-string/regex-literal false-positive
avoidance, `ansible.builtin.`-prefixed names, and Crinja-only filter names.
Live-reverified the actual role on a fresh Kata pair: byte-identical
recaps both engines, cold and warm (`ok=7 changed=3 failed=1 skipped=3`
cold, `ok=7 failed=1 skipped=3` warm) - `skipped` was 6 vs 3 before this
fix - and the identical underlying error text ("No filter named
'success'.") on both.

---

## Round 44000: `file:` module's `recurse:`/default-`state:` semantics fixed (0.9.787)

Closed the last remaining `dev-sec.nginx-hardening` open gap. Real Ansible's
`file` module (`additional_parameter_handling` in `file.py`) does not default
`state:` to `"file"` unconditionally: with no `state:` given, the default is
the path's CURRENT type (file/directory/link) when it exists at all, or -
only when the path is genuinely absent - `"directory"` if `recurse: yes` else
`"file"`. Separately and unconditionally, real Ansible then hard-fails
`recurse: yes` against anything that doesn't resolve to `"directory"` -
"recurse option requires state to be 'directory'" - live-verified this
applies whether `state:` was explicit or defaulted, and regardless of the
path's existing type. This engine previously defaulted unconditionally to
`"file"` for any existing path, never checked the recurse/directory
requirement at all, and failed outright when the path was missing (breaking
`dev-sec.nginx-hardening`'s own `file: {path: /etc/nginx, mode: o-rw,
recurse: yes}` against a host without nginx installed). Fixed by resolving
`state:` from the path's real on-disk type (`resolve_state`), and adding the
missing recurse/directory validation. Live-reverified: an existing file with
`recurse: yes` and no `state:` now fails with the identical message on both
engines; an existing directory or a genuinely missing path still succeeds
identically. Re-ran the actual reporting role on a fresh Kata pair:
byte-identical recaps both engines, cold (`ok=2 changed=1 failed=1`) and warm
(`ok=2 failed=1`) - the originally-failing task now creates `/etc/nginx`
correctly on both, and both fail identically at the same later, unrelated
task.

---

## Round 43000-43201: strict-undefined dict-subscript misses fixed (0.9.786)

Closed the deferred `igor_nikiforov.etcd` / `lablabs.rke2` strict-undefined
class and re-verified `rvm.ruby` end to end, all three live on fresh Kata
pairs against ansible-core 2.19.4:

- **`igor_nikiforov.etcd` FIXED.** A dict-subscript miss on a resolvable
  chain (`etcd_config['data-dir']`) inside the loop-source list now fails
  the task the way real Ansible's strict module-arg/loop templating does -
  "object of type 'dict' has no attribute 'data-dir'" - instead of
  rendering the literal string "undefined" and mkdir-ing directories named
  "undefined" to a warm rc=0. Round 43000: byte-identical recaps both
  engines, cold (ok=4 changed=3 failed=1) and warm (ok=4 failed=1).
- **`lablabs.rke2` FIXED.** `meta/argument_specs.yml` `default:` expressions
  are now templated strictly (real Ansible templates the ENTIRE spec when
  finalizing the validate_argument_spec call args - live-verified that it
  fails even with the option passed explicitly). rke2's ternary/filter
  defaults needed a compound-expression scan (`scan_strict_expression_refs`)
  beyond the bare-ref/chained checks; its failure now lands on the same
  task with the same message ("object of type 'dict' has no attribute
  'masters'"). Round 43200: identical recaps both engines, cold and warm
  (ok=1 failed=1).
- **`rvm.ruby` re-verified - no krikri gap.** With the host's Kata
  NAT/egress restored, a fresh differential with the role's
  `rvm1_user: ubuntu` default worked around (`-e rvm1_user=root`) because
  that user doesn't exist on a Debian Kata host and real Ansible fails at
  the role's second task on the become/temp-file-ownership quirk:
  - the "gpg-keyserver-fetch failure" originally noted against krikri is an
    ARTIFACT - with working internet, both engines fail the exact same
    keyserver loop with the exact same per-item errors
    (pool.sks-keyservers.net "Server indicated a failure" - the SKS pool is
    decommissioned; pgp.mit.edu "No keyserver available";
    keyserver.pgp.com timeout), and both run the role's rvm.io fallback;
  - it exposed ONE real (small) gap, fixed: krikri's `command:` module
    didn't expand a leading `~` in the executable path
    (`command: '{{ rvm1_rvm }} autolibs ...'` with
    `rvm1_rvm: ~/.rvm/bin/rvm` - real Ansible's
    `AnsibleModule.run_command(expand_user=True)` expanduser's it, this
    engine failed with "Error executing process: '~/.rvm/bin/rvm'").
  - remaining ok/changed recap difference in the final differential
    (py ok=7 changed=4 vs cr ok=8 changed=3) traces to one flaky external
    keyserver item (pgp.mit.edu failed under py, succeeded under cr) -
    environmental, not engine semantics.

Model verified live against 2.19.4 before implementing: a dict-subscript
miss behaves like strict-undefined - raises in module args and bare
`when:` use, SKIPS on `is defined`/`| default()` - with the attribute-error
message for bracket AND dot forms; a task-level `when:` is evaluated BEFORE
the loop list is templated (`when: false` + undefined loop item → plain
skip; `when: item is defined` → skip; `when: true` → fail). Handler and
include_tasks loop-item rendering is deliberately left lenient (strict:
false at those call sites - no failure plumbing there yet); the main
looped-task flow is strict with real-Ansible when:-before-loop ordering.

---

## Open gaps

Genuinely open defects: something is wrong and the fix is unknown or
unfinished. Everything deliberate lives under "Deliberate limits"
below - keep the two apart, or this list stops meaning anything.

- **Unresolvable module/action names: hard-stop now covers the two
  provably-unresolvable shapes (0.9.860); a missing module inside a
  RECOGNIZED collection still gracefully skips, where real Ansible
  hard-stops.** `Aplyca.EC2Describe` (`ec2_remote_facts`, a module
  removed from ansible-core years ago) and `bodsch.k0s`
  (`bodsch.scm.github_latest`, an uninstalled collection module) both
  round71000: real `ansible-playbook` refuses to even start the play
  (`[ERROR]: couldn't resolve module/action '...'`, rc=4, no PLAY RECAP
  at all) the moment it can't resolve ANY task's module name, before
  Gathering Facts even runs. Fixed (0.9.860, `UnresolvedModuleError`,
  generalizing `RemovedActionError`'s round-162 mechanism): parse-time
  hard-stop - real Ansible's exact message text and rc=4, no tasks run -
  for exactly two shapes, verified live against ansible-core 2.19.4
  (including that a `when:`-gated, never-reached offending task still
  aborts the whole load): (a) a tombstoned-removed name
  (`REMOVED_MODULE_TOMBSTONES`: bare/`ansible.builtin.`/`ansible.legacy.`/
  `amazon.aws.`-qualified `ec2_remote_facts` - widen by adding entries,
  only names unresolvable on EVERY real controller qualify), and (b) a
  collection-qualified name (3+ dot-separated segments) whose
  `namespace.collection` the engine has zero AVAILABLE_PLUGINS modules
  from (`IMPLEMENTED_COLLECTIONS`, derived from AVAILABLE_PLUGINS so the
  two can't drift) - i.e. a collection never installed, which real
  Ansible also fails to resolve. Everything else keeps the graceful
  per-task unavailable_module skip: crucially, an unimplemented module
  inside a RECOGNIZED collection (`community.general.xyz`,
  `ansible.builtin.xyz`, `amazon.aws.xyz`, ...), which is far more
  likely a not-yet-ported module than a nonexistent one. **The
  remaining known gap:** a module that genuinely doesn't exist inside a
  RECOGNIZED collection (`community.general.doesnotexist_xyz`) still
  skips gracefully where real ansible-core 2.19.4 hard-stops with the
  same "couldn't resolve" error (verified live) - indistinguishable
  from a not-yet-implemented module without a full upstream module
  registry this engine doesn't keep; telling those apart would need
  shipping per-collection module manifests. Also verified live: a real
  but unimplemented builtin (`ansible.builtin.sysvinit`) resolves fine
  on real Ansible and must stay a graceful skip here - hard-stopping
  every unresolvable name would break the project's whole
  graceful-degradation value proposition.
- **Crinja-side `in`-a-plain-string with an undefined left operand
  still diverges (hand-rolled `when:` side fixed, 0.9.858).** The
  original round71000 gap (`asg1612.gluster`: `when: "node_1 in
  hostvars[inventory_hostname]['ansible_nodename']"` with `node_1`
  never defined, real Ansible hard-failing with "'in <string>'
  requires string as left operand, not UndefinedMarker") is fixed in
  the hand-rolled `when:` evaluator - see the 0.9.858 narrative above.
  What remains is the vendored-Crinja side (real `.j2` template files,
  `{%` blocks): real Jinja2 raises the TypeError there, while this
  fork's `Operator.contains?` silently coerces an Undefined marker to
  `""` (a substring of everything) under the default lenient mode and
  returns TRUE, and under `StrictTemplating` hard-errors with
  Crinja's generic "`node_1` is undefined" instead of the TypeError
  shape. Fixing either means modifying the vendored `crinja` fork
  itself (tag-pinned via `shard.yml`, so a fork release), plus care
  not to break the lenient mode's broader empty-string-coercion
  conventions - not done this round.

### Needs a closer look (real, reproducible, not root-caused yet)

Promoted from round 72000's triage so they don't get buried as later
rounds accumulate. Real, reproducible divergences whose root cause
isn't fully pinned down yet:

- **The apt-404-on-krikri-host-only pattern across 3 roles**
  (`lfit.lf-dev-libs`, `lfit.mono-install`, `markosamuli.pyenv`,
  round 72000): all
  three show the identical shape - `apt-get install` fails with `404
  Not Found` fetching specific `.deb` files from
  `us.archive.ubuntu.com`, on the krikri-side Atlantic host only; the
  real-Ansible-side host (same task, same package versions, a
  different physical VM) succeeds. Each individual instance is
  plausibly just mirror-timing flakiness between two independent hosts
  hitting a live, mutable public mirror at slightly different moments
  - but three separate confirming roles in one round is enough to flag
  as a pattern worth a closer look (e.g. whether krikri's apt cache-
  update sequencing differs from real Ansible's own timing in some way
  that makes a stale index more likely) rather than dismissing each as
  independent bad luck.

Found via the 97-role fixed/divergence re-verification round and
double-checked with a second independent re-run of every divergence
against the properly committed `0.9.824` (commit `79270d9a`) - see the
narrative entries below for the full story, including why the first
pass's version numbers were unreliable. Each item below reproduced
**deterministically across two independent fresh-host runs**, which is
why these are listed as confirmed rather than merely suspected:

- **`linux-system-roles.storage`** (Rocky 9.6): partially fixed (see
  the narrative below) - `sr_fingerprint` now runs correctly, but the
  role's own `blivet:` module needs a custom `module_utils.storage_lsr`
  package this engine doesn't bundle, a new, separate, larger scope
  gap (see "Deliberate limits" below) than the regression this row
  originally reported.
- **`kyl191.openvpn`**: NOT a regression - root-caused. The single
  differing task is real Ansible's own `package_facts:` module failing
  outright ("Could not detect a supported package manager... or the
  required Python library is not installed") because `python3-apt`
  isn't installed on this Kata image - `ignore_errors: true` lets the
  play continue, but the role's own fallback task
  ("Ensure packages fact exists", gated on the fact never having been
  set) then runs on real Ansible and is skipped on krikri, since
  krikri's own native (non-Python) `package_facts:` implementation has
  no such dependency and succeeds where real Ansible's does not. Not
  fixable in any meaningful sense - replicating it would mean
  deliberately breaking krikri's `package_facts:` to match a missing
  runtime dependency on real Ansible's own interpreter, not a real
  behavioral gap.

Single-data-point, not yet confirmed by a second run: `buluma.
confluence` finally completed on a third attempt (the first two hit
SSH_TIMEOUT) with a small divergence (`ok=27/changed=8/skipped=6` real
Ansible vs `ok=26/changed=7/skipped=7` krikri) - close to but not
exactly the historical `ok=25` baseline; worth a repeat run before
treating as confirmed.

Not regressions - ruled out by the second run: `diodonfrost.
amazon_codedeploy` (came back CLEAN on retry - the original `rc=126`
was a one-off plugin-upload glitch), `inmotionhosting.wordpress` (the
huge `ok=110` vs `ok=120` gap from the first run did not reproduce - the
second run landed at `ok=26`/`ok=26` on both engines, matching closely;
the role's own external-download-heavy early tasks appear to have high
run-to-run variance that swamped any real engine signal in the first
pass). Inconclusive - real Ansible itself couldn't reach the host both
times (reboot/SSH flakiness, not comparable either way):
`mrlesmithjr.change-hostname`, `robertdebock.selinux`. Not regressions -
matches already-documented behavior: `buluma.forensics` (known
`delegate_to: localhost` ssh-reupload limitation), `xanmanning.k3s`
(known GitHub-403/rate-limit flakiness on the real-Ansible side; krikri's
own early stop at the same point both runs may be worth an isolated
repro someday but is low priority), `buluma.netdata` (known
long-build-role timeout/resource flakiness), `linux-system-roles.logging`
(the entire `ok=28` vs `ok=30` gap is the role's own custom
`sr_fingerprint` module from its `library/` dir - the same documented
scope-cut `linux-system-roles.timesync`'s own row already describes;
this round happened to hit it on Ubuntu instead of the Rocky host the
original fix was verified on - confirmed live via `cold_py.out`, not a
regression in the actual `include_role: vars:` fix). `buluma.confluence` hit
infra flakes (SSH_TIMEOUT) on both attempts to re-test it - still no
real data either way.

The three gaps found via the 100-role RHEL (Rocky 9.6) regression round
(round 65000+, distinct from the round above) are all root-caused and
fixed - the fix-phase narrative for each lives in the 0.9.818/0.9.823
commit messages. `pip:`'s pip3-discovery fix (mirroring real Ansible's
own `_get_pip` order: `python3 -m pip` when the interpreter can `import
pip`, PATH search for the `pip3` binary only as a fallback) is
confirmed live (0.9.823 review pass): a fresh Kata Rocky 9.6 VM with
`python3-pip` installed but its `pip3` script moved off PATH still
installs a package correctly via the `python3 -m pip` fallback, and
fails with real Ansible's own "Unable to find any of pip3 to use"
message on the pre-fix code in the identical scenario. The original
divergent role (`geerlingguy.supervisor` on Atlantic's Rocky 9.6
image specifically) itself has still not been re-run end to end,
though the underlying discovery-order bug it hit is now directly
confirmed.

---

## Round 30001: apt `update_cache:` false-`changed` root-caused and fixed (0.9.785)

Closed the long-standing `apt: {update_cache: true}` false-`changed` divergence
(`claranet.users` round 20037, `ckaserer.tftp` rounds 20008/41000) by finally
root-causing it live on a fresh Kata VM, and the answer is not what the
0.9.782-era mtime-diff analysis assumed:

- **The CLI-vs-library discrepancy was a red herring.** A fresh Kata VM's
  `apt-get update` CLI does NOT bump `/var/lib/apt/lists`'s mtime on an
  all-Hit (nothing-to-fetch) run - verified by running it twice back to back
  and stat-ing between; the mtime only moves when something is actually
  fetched (a `Get:` line). So the before/after mtime-diff krikri has used
  since 0.9.782 IS a faithful "did anything get fetched" signal for the CLI
  path, and on hosts WITH python3-apt it matches real Ansible exactly
  (re-verified: forced-fetch + python3-apt present → both engines
  `changed=True`; all-Hit rerun → both `ok`).
- **The real mechanism: real Ansible's python3-apt auto-install prefetch.**
  On hosts WITHOUT python3-apt (every fresh Kata VM), apt.py can't run at all
  until it auto-installs python3-apt and respawns the module under an
  interpreter that can see it - and the auto-install step runs a full
  `apt-get update` FIRST (the "Updating cache and auto-installing missing
  dependency" path). The respawn then re-reads the cache mtime entirely AFTER
  that prefetch, so a cache-refresh-only invocation reports `ok` even when the
  prefetch genuinely fetched new lists. Verified live: delete a lists file +
  age the dir mtime, real Ansible fetched (mtime moved) and still reported
  `changed=False` while python3-apt was absent, `changed=True` once present.
- **The fix** (`plugins/apt.cr`): probe the same two interpreters real
  Ansible probes (`/usr/bin/python3`, `/usr/bin/python`) for the `apt` module.
  Without python3-apt, run the update but keep `changed=false` for the
  sole-operation case regardless of mtime movement (emulating the prefetch's
  invisible-to-its-own-measurement window); with it, keep the existing
  mtime-diff logic. Also mirrors real Ansible's check-mode refusal on
  python3-apt-less hosts (fails with the same "python3-apt must be installed
  to use check mode" message - byte-identical live). One asymmetry was left
  in place here, deliberately at the time: real Ansible's first run
  *installs* python3-apt, so its SECOND run switches to mtime-diff
  semantics, while krikri never installed it and stayed on the
  prefetch-emulation path. **Superseded in 0.9.835** - that asymmetry turned
  out to be observable after all (geerlingguy.kubernetes; see the 0.9.835
  entry above), and krikri now performs the same real install. The check-mode
  refusal described here is unchanged, and is exactly why that install is
  skipped under `--check` (both in `apt:` and in `package:`'s
  cache-refresh-only path).

---

## Round 20000-20037 confirm batch (re-run of the 38 round-10000 divergences against the fully-fixed build, 0.9.782 -> 0.9.784)

Triaged the remaining items from the confirm batch. `deekayen.chocolatey` (Windows-only, same
class as `jborean93.win_openssh`) and `gekmihesg.openwrt` (real `ansible-playbook` itself crashes
with an internal Python unpacking error on this role - upstream role/ansible-core incompatibility,
krikri gets further than real Ansible does) are not krikri bugs. Also not krikri bugs:
`AerisCloud.disk` (both engines ultimately hit the same "Conditional result (False) was derived
from value of type 'list'" role bug - krikri's divergent recap counters are purely a side effect of
`disk_config` being an unimplemented custom module, already a known/deliberate gap) and
`brianshumate.consul` (real Ansible fails on the CONTROLLER's own PEP-668 externally-managed-
Python-environment lockout trying `pip install --user netaddr` - a dev-machine environment issue,
not a role or engine bug; krikri has no equivalent pip-into-controller step in that code path so it
gets further, then fails later for an unrelated, genuine role-config reason:
`consul_group_name must be included in groups`).

- **`ansible_facts['virtualization_type']` reported the raw `container=X` env value instead of
  the generic literal "container"** (`juju4.auditd`, round 20015): a Kata VM's guest environ
  happened to carry `container=docker` (a leftover of the base rootfs having been built via
  `podman build`/Containerfile, even though Kata boots a real, non-containerized guest kernel) -
  krikri reported `virtualization_type=docker`, matching the role's `when: ... virtualization_type
  == "docker" ...` guard and skipping its entire "Not in container" block outright (recap
  `ok=14 changed=6 skipped=41` vs py's `ok=17 changed=4 failed=1 skipped=4` - a huge swing from one
  bad fact). Real Ansible's own `LinuxVirtual#get_virtual_facts` (`module_utils/facts/virtual/
  linux.py`) only gives `container=lxc`/`container=podman` their own specific virtualization_type;
  every other non-empty `container=` value normalizes to the generic literal string `"container"` -
  it is never captured or reused verbatim. `FactsGatherer#parse_container_env` was doing exactly
  that verbatim reuse. Fixed by returning the literal `"container"` for any container= value other
  than lxc/podman. Regression spec updated in `spec/unit/facts_gatherer_spec.cr` (the old test
  actually encoded the bug, asserting `"systemd-nspawn"` back verbatim). Live-verified against the
  same Kata image with a standalone repro playbook: krikri now matches real ansible-playbook's
  `virt_type=container` exactly and enters the block the same way.

- **`ansible_facts['lsb']` was only ever set when `/etc/lsb-release` existed, instead of always
  being a (possibly empty) dict** (`githubixx.ansible_role_wireguard`, round 20012): a Debian host
  with neither `lsb_release` nor `/etc/lsb-release` installed left `ansible_facts['lsb']` entirely
  undefined for krikri, so `when: ansible_facts['lsb'] is defined and ansible_facts['lsb']['id'] ==
  "Raspbian"` short-circuited to skip; real Ansible's `LSBFactCollector.collect()`
  (`facts/system/lsb.py`) unconditionally does `facts_dict['lsb'] = lsb_facts` even when
  `lsb_facts` stayed `{}`, so `is defined` is True there and it hard-fails evaluating the second
  clause instead (`'dict' object has no attribute 'id'`). Fixed by always setting
  `ansible_facts["lsb"]`, defaulting to an empty hash. No unit spec - real /etc/lsb-release reads
  have no controlled-input entry point yet (same "live smoke test only" exception as
  `detect_virtualization`'s own spec); live-verified with a standalone repro against a fresh Kata
  VM - krikri now fails the same task real Ansible does (recap `failed=1` either way), closing the
  divergence even though the exact error text differs.

---

## Round 10000-10149 (150-role overnight krikri-role-tester round, 0.9.772 -> 0.9.774)

First round run overnight, unattended, via `krikri-role-tester` with both backends concurrently (4 Kata pairs + 4 Atlantic.net pairs). 86 roles continued the existing `testing/kata/round_new_authors/shortlist120.txt` (picking up where round 6008-6019 left off); 64 more were freshly sourced from the Galaxy API (`order_by=-download_count`), filtered against every role already in `ROLES_TESTED.md`. Final tally: 92 CLEAN, 35 DIVERGENT, 19 BLOCKED, 4 GALAXY_MISSING.

**Two harness-level findings before any engine bugs, same "false divergence" class as the plugin-upload race documented above:**

1. **The Kata test image shipped with a completely empty apt cache** - its `Containerfile` ran `rm -rf /var/lib/apt/lists/*` after its own build-time install step (the usual Docker image-size practice), so every fresh VM needed an explicit `update_cache: true` to find ANY package at all; a plain `apt-get install` failed identically to krikri on a fresh VM, confirmed live. Since most roles' first install task doesn't set `update_cache:`, whichever of the two per-role VMs happened to install successfully first (a coin flip, not a real engine difference) determined whether the pair showed CLEAN or DIVERGENT. **Fixed**: kept the cache populated (`testing/kata/Containerfile`), rebuilt the image mid-round. Everything before this fix (roughly rounds 10000-10080) should be re-verified before trusting an apt-related DIVERGENT from that range.
2. **16 of the 19 "BLOCKED missing engine run" results are not real** - both engines correctly reject a role using ansible-core's removed `ansible.builtin.include` action at PARSE time (same class as the pre-existing "removed `include:` action" note in round 6000-6007 below), but `krikri-role-tester`'s own SUMMARY-parsing can't extract PLAY RECAP counters when neither engine ever reaches a play, so it defaults to BLOCKED instead of CLEAN. A `krikri-role-tester` tooling gap, not a krikri-playbook gap - worth fixing in that project, not here.

**Two real engine bugs found and fixed (0.9.774):**

- **`delegate_to: <host>` + `delegate_facts: true` targeting a host never seen before crashed the ENTIRE process** (`xe0nic.ansible_vprotect_server`): `@facts`/`@set_facts` are only pre-seeded for the play's own hosts; the first fact ever delegated to an arbitrary host name (not necessarily in inventory) raised an unrescued `Missing hash key` `KeyError` in `merge_ansible_facts`, losing every other host/task the run would otherwise have completed - not just failing the one task, the way real Ansible's own delegate-facts handling does. Fixed with lazy `||=` init. Regression spec: `delegate_to_localhost_spec.cr`.
- **A `loop:` source referencing an unimplemented filter crashed the ENTIRE process** (`oasis_roles.system_repositories`, whose role ships its own `filter_plugins/exclude.py` - real Ansible loads role-local Python filter plugins automatically, a genuine, understood scope limit this engine doesn't attempt to close): `resolve_loop_items_or_raise` only rescued `UndefinedVariableError`, so `FilterEngine::UnknownFilterError` propagated unrescued out of `Executor#run` - "Unhandled exception: No filter named '...'." The identical shape in a NON-loop task param already failed gracefully (task-level `failed:`, not a crash) - only the `loop:` resolution path was missing the rescue. Fixed by also converting `UnknownFilterError` to the same `WhenEvaluationError` degrade-to-failed-task path. Regression spec: `cli_spec.cr` + `testing/test-loop-unknown-filter.yml`.

The remaining 33 divergences and the `lablabs.rke2`/`xanmanning.k3s`/`kyl191.openvpn`/`igor_nikiforov.journald`/`evrardjp.keepalived` items already resolved separately this round are NOT yet fully triaged by root cause here - see `git log` for what's been fixed so far; a full dedup pass (one fix per shared root cause, per this file's own workflow) is still pending.

---

## Round 6008-6019 (second krikri-role-tester round / stability check, 8 new-author roles, 0.9.761)

One new open gap (`file:` on a missing `recurse:` target, above) plus a third real bug found in
the `krikri-role-tester` harness itself: `Cmd.run` passed its env to `Process.new` without
`clear_env: true`, so Crystal's default merge-onto-parent-env behavior let this control machine's
own ambient `ANSIBLE_CACHE_PLUGIN`/`ANSIBLE_CACHE_PLUGIN_CONNECTION` leak into every engine
subprocess regardless of `Cmd.engine_env`'s stripping - poisoning real ansible-playbook's fact
cache (keyed by the harness's generic, round-independent `pyhost` alias) with a stale interpreter
path from an unrelated earlier host, false-failing 4 of the round's 8 Kata roles identically on
both engines. Fixed with a regression spec; those 4 roles re-run clean after clearing the poisoned
cache. See `ROLES_TESTED.md` for full per-role detail.

---

## Round 6000-6007 (first krikri-role-tester round, 8 new-author roles, 0.9.761)

No new krikri-playbook defects. First round driven by the new `krikri-role-tester`
Crystal harness (`../krikri-role-tester`, replaces the old shell drivers) instead
of by hand - the harness itself had two real bugs (a `Process#wait` race that
crashed the first attempt outright, and Atlantic.net teardown silently failing to
destroy - leaking every prior round's Atlantic.net pair, not just this one's),
both fixed there with regression specs before this round's numbers were
collected. Of the 8 roles: 2 clean, 4 hit ansible-core's removed `include:`
action (real ansible-playbook fails identically, not a krikri bug), 1 hit a
missing `ansible.mariadb` collection, 1 (`r_pufky.pihole`) hit `ansible.utils`'s
`ipaddr` filter - both folded into the existing unimplemented-collection bullet
under Deliberate limits above. See `ROLES_TESTED.md` for full per-role detail.

---

## Round 307 (lookup('first_found') default search order, 0.9.741 -> 0.9.742)

Found doing a stale-entries sweep of `ROLES_TESTED.md`'s `❌ DIVERGENT`
rows: `ipr-cnrs.glpi_agent`'s `include_tasks: "{{ lookup('first_found',
params) }}"` (no `paths:` at all) resolved against this engine's
`files/templates/vars/.` default order and matched `vars/Debian.yml`
(a same-named file that exists for an unrelated reason) instead of the
role's own `tasks/Debian.yml`, then failed trying to run it as a tasks
list ("Included tasks file must be a YAML list").

Read real Ansible's own `DataLoader#path_dwim_relative_stack`
(`ansible/parsing/dataloader.py`, available locally via the `ansible`
apt package) to find the actual default: with no `paths:`, it searches
`<role_root>/files/<name>` first, then - only because the calling task
lives in a role's `tasks/` dir - the RAW `<role_root>/tasks/<name>`
directly; `vars/`/`templates/` are not part of the no-`paths:` default
at all (verified live against ansible-core 2.14.18, this project's
benchmark baseline - a synthetic repro against the HOST's ansible-core
2.19.4 showed a *different*, stricter default with no implicit search
at all, so this is version-sensitive; 2.14.18 is what the corpus is
actually benchmarked against). Fixed by inserting `tasks` into
`default_first_found_paths` right after `files`
(`expression_evaluator.cr`), leaving the existing `templates`/`vars`/
`.` fallbacks in place for whatever already-tested scenarios rely on
them beyond the literal no-`paths:` case.

Verified: full spec suite (2518 examples) and `ameba` (447 files)
clean; two new regression specs (files/ priority over tasks/, tasks/
found before vars/); live-reverified the actual `ipr-cnrs.glpi_agent`
role end to end (podman/Debian 12, ansible-core 2.14.18) - both
engines now recap identically (`ok=6 changed=1 failed=1 skipped=0`),
failing at the same later task on `glpi-agent` genuinely not being
available in this repo (environmental, not an engine bug).

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

### Unimplemented community.general filter long tail (usage-audited, watchlist not backlog)

- The dict-key filters (`keep_keys`, `remove_keys`, `replace_keys`,
  `dict_kv`, `groupby_as_dict`), the `lists_*` family
  (`lists_union`, `lists_difference`, `lists_intersect`,
  `lists_symmetric_difference`), `accumulate`, `counter`, `crc32`,
  `version_sort`, `random_mac`, `unicode_normalize`, `from_csv`,
  `from_ini`/`to_ini`, `from_toml`/`to_toml`, `json_diff`,
  `json_patch`, `hashids`, `reveal_ansible_type`, the
  `to_<time-unit>` family, and `to_prettytable` are all unimplemented.
  They ARE reachable by a role (that is how `lists_mergeby` was found,
  0.9.843), but a Sourcegraph audit of public GitHub YAML (2026-09)
  showed real-world usage is almost nil: hits are dominated by the
  collection's own docs/tests, the PacktPublishing Ansible book repo's
  vendored copy, and vbotka/ansible-examples (a filter-tutorial repo by
  the filters' own contributor); excluding those, the only real-role
  hits found were one `version_sort` (splunk-platform-automator), one
  `keep_keys` (kubespray's test-infra image-builder), one `counter`
  (IBM's samples repo), and zero for `dict_kv`/`groupby_as_dict`/
  `remove_keys`/`replace_keys`/`lists_*`. Calibration: the same search
  for `dict2items` matches hundreds of genuine roles. Decision: none of
  these go in a backlog on spec; each gets implemented on first live
  hit by a benchmark role, like `lists_mergeby` was (0.9.843).
- **ansible-core builtins** are effectively fully covered - the only
  builtin names absent are `random`, `rejectattr` (deliberately
  excluded from `KNOWN_FILTER_NAMES`, see the dispatch comment),
  `groupby`, and the Windows-only
  `win_basename`/`win_dirname`/`win_splitdrive`.

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

- **Arbitrary-Python-module support is scoped to role-private
  `library/*.py` sources** (plus the playbook-adjacent `library/`): a
  module with a resolvable source now RUNS on the target with the
  target's own python3 through the py_module plugin (0.9.819, see the
  scope-cut clearing batch above) - previously skipped with a
  parse-time warning (seen live repeatedly via linux-system-roles'
  `sr_fingerprint`, `timesync_provider`, `kernel_settings_get_config`,
  `blivet`). What remains cut: a module reference with NO library
  source anywhere (still parse-time-warned, still exits 4 for a
  reachable one since 0.9.558 - real Ansible's own code for refusing a
  playbook it can't resolve a module for) and every THIRD-PARTY
  COLLECTION module (the bullet below) - those live inside installed
  collections on the comparison side, not in the playbook tree the
  runner can see. The exit-status half stays divergent for source-less
  modules: WHICH TASKS RUN differs (real Ansible refuses at parse time
  and runs nothing; this engine runs the rest of the play), not the
  exit status a caller sees. **0.9.829 update**: the feature's own
  role-root resolution, argument-passing protocol, and task-batching
  interaction were all independently broken since 0.9.819 introduced it
  (see the round-narrative correction above) - fixed, and confirmed live
  for a self-contained module (`sr_fingerprint`, no unusual imports).
- **A role-private module importing its OWN custom `ansible.module_
  utils.*` package is still out of reach** (found via linux-system-
  roles.storage's `blivet:`, which does `from ansible.module_utils.
  storage_lsr.argument_validator import validate_parameters` -
  `storage_lsr` isn't a real ansible-core module_utils package, it's
  bundled alongside `blivet.py` the same way real Ansible's AnsiballZ
  wrapper bundles a role/collection's own `module_utils/` tree into the
  zipapp so the import resolves). This engine's py_module runner
  uploads and runs only the ONE module source file with no such
  bundling, so any module reaching for a sibling `module_utils` package
  fails with a plain Python `ModuleNotFoundError` instead of running.
  Fixing this needs finding and packaging the role/collection's own
  `module_utils/` tree alongside the module source (a real, but
  larger, follow-on to the single-file case above) - not attempted
  here.
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

  (The bullet that used to live here - `community.general.
  redhat_subscription`, `community.rabbitmq.rabbitmq_plugin/_user`,
  `ansible.mariadb.mariadb_db/_user` - is gone: the first two were
  natively ported back in round 196/0.9.631 but this entry was never
  updated (mrlesmithjr.rabbitmq and linux-system-roles.rhc have been
  re-verified clean since), and ansible.mariadb's modules turned out to
  be functionally identical forks of the already-implemented
  community.mysql ones - aliased onto them as of 0.9.825, see the
  scope-cut re-examination narrative at the top.)

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
- **A dotted/bracketed attribute miss on a NON-hostvars object stays
  lenient in `.j2` template renders** (`crinja_strict_undefined.cr`
  only makes `Resolver#resolve`, the bare-name lookup, strict). The
  hostvars case - the one live divergence against this cut
  (`mrlesmithjr.ansible_consul_client`, RHEL-family round 60175:
  real Ansible's `HostVarsVars` raises `object of type 'HostVarsVars'
  has no attribute 'ansible_enp0s8'` where a lenient render produced an
  empty value) - is closed as of 0.9.821 via the hostvars-specific
  strict path the original note called for (see the scope-cut clearing
  batch above). The blanket cut stays: `Resolver.resolve_with_hash_
  accessor` is also the fallback for method-call dispatch and this
  engine's own fact-coverage gaps, so a non-hostvars dict miss remains
  lenient even under strict templating, deliberately.

### Cosmetic differences (both engines fail; only the wording differs)

These change no outcome and no recap. Listed so they aren't re-reported
as bugs, not because anyone intends to fix them. (The section's two
former entries - `RemovedActionError`'s message text and
`include_vars:` with a failing templated path - were re-examined and
closed in 0.9.824; see the round narrative at the top.)

### Everything else

- **`ansible-playbook`'s CLI flag surface is fully covered by name, and
  all but one flag is now behavioral.** `--help` lists every flag real
  ansible-core 2.19.4 does, including its own long aliases
  (`--inventory-file`, `--vault-pass-file`).

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
  `community.general.clustering.consul.consul_acl`
  (`mrlesmithjr.consul` - also demonstrates the "WHICH TASKS RUN
  differs" side of this same gap: real Ansible refuses at parse time
  with zero tasks run, this engine runs the whole play first, ~80s of
  real work, before reporting the same rc=4 - already covered by the
  role-private-custom-modules entry above, not distinct).
- The legacy free-form `action: "<templated module name> key=val ..."`
  task syntax - REMOVED from this list in 0.9.825: it had been
  implemented since round 192 (both the `action: <module> [k=v ...]`
  free-form string, its `{module: ..., args: {...}}` dict form, and the
  runtime-templated module name resolved via
  TaskExecutor#resolve_templated_action) and this entry was simply
  never deleted. `weareinteractive.users_oh_my_zsh`'s shape is covered
  by playbook_parser.cr's ACTION_DIRECTIVE_KEYS branch.
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
  unconditionally regardless of the condition. 0.9.789 added the last
  three (see round 50000 above): `end_batch` behaves exactly like
  `end_play` while `serial:` batching isn't modeled, `end_role` does
  role-scoped early return keyed on the role invocation, and
  `reset_connection` drops the host's daemons + ssh ControlMaster
  socket. Every action in real Ansible's `meta` module's choices list
  is now supported.
- `config`/`inventory_hostnames` lookups - **removed from this list in
  0.9.826, both halves stale**: `config` had been implemented since
  round 190 (buluma.multi's wantlist loop) without the entry being
  updated, and `inventory_hostnames` turned out to need no inventory
  plumbing at all - the real lookup plugin builds its throwaway
  InventoryManager purely from variables['groups'] and runs the
  standard host-pattern machinery over THAT, and the `groups` magic var
  was already in every task's vars context. Ported
  (ExpressionEvaluator#lookup_inventory_hostnames): comma/colon terms,
  `&`/`!` modifiers, fnmatch over group names then host names,
  `~`-regexes, `[N]`/`[A:B]` subscripts (inclusive end), empty result
  as a real `[]`, and query() returning the list form - all 12 pattern
  cases differentially verified against the locally-installed
  ansible-core 2.19.4 (inventory_hostnames_lookup_spec.cr). `groups`
  also gained its missing `ungrouped` key (real Ansible's own magic-var
  shape). Known shared limitation: a wantlist/query list result renders
  `["a","b"]` in debug msg where real ansible-core prints Python's
  `['a', 'b']` repr - the same pre-existing class lookup('config',
  ..., wantlist=True) already had.
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
  neither engine regenerates the other's artifacts). The info/read-only
  half joined in 0.9.789 (see round 50000 above): `openssl_privatekey_info`,
  `x509_certificate_info`, `openssl_publickey`, `get_certificate`, and
  `openssl_pkcs12` `action: parse`.

  Still unimplemented, none of them seen in a role yet: `luks_device`,
  the `acme`/`entrust` certificate providers, `openssl_pkcs12` export's
  `encryption_level: compatibility2022`, and the CRL/revocation family
  (all of which fail with a clear "not supported" message rather than
  silently doing something else); `acme` means speaking ACME to a real
  CA, which stays out of scope. (The `*_info` read-only half -
  `openssl_publickey_info`, `openssl_csr_info` - is implemented as of
  0.9.822, see the scope-cut clearing batch above.)
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
  explicitly. The last combination -
  a genuinely running firewalld daemon (auto-detected via
  `firewall-cmd --state`, real Ansible's own detection equivalent) AND
  an `immediate:` runtime change requested or defaulted - used to fail
  with "not implemented"; it is serviced through `firewall-cmd` (the
  D-Bus client CLI) as of 0.9.820, and a `target:` operation in the
  immediate context now fails with the real module's "Zone operations
  must be permanent..." like real Ansible instead of being silently
  serviced offline. Verified live in a real firewalld 2.3.1 container
  (`firewall-cmd`/`firewall-offline-cmd`), byte-identical `ok=5
  changed=2 failed=0 ignored=1` against real `ansible-playbook` across
  4 scenarios (permanent-only enable, idempotent rerun, defaulted zone,
  and the still-unimplemented bare-defaults-against-no-daemon case
  correctly failing with real Ansible's own exact error message on
  both).

---

For the fixed-bug history (150+ rounds of real-host benchmarking against
production Ansible roles), see `git log`.
