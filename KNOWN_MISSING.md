# Known Missing / Known Gaps

The goal is 100% behavioral compatibility with `ansible-playbook`,
verified against real runs rather than assumed - not "cover the common
cases." This file tracks what's actually missing today. It intentionally
does **not** carry implementation history or root-cause narrative for
fixed bugs - that detail lives in `git log` commit messages, written at
the same level of detail per commit; search there (e.g. `git log --all
--grep=auth_socket`) rather than in a second, easily-stale copy here.

**Currently at `0.9.224`.**

---

**No known cross-cutting engine gap is open right now** - but that status
is continuously re-earned, not permanent. Each real-host benchmark round
against a new production Ansible role tends to find more (most recently
15 in the `linux-system-roles` round, `0.9.158`-`0.9.171`: depth-unaware
operator parsing that could stack-overflow, block-level `vars:` never
parsed, a missing `d()` filter alias, dict/array literals unsupported
outside a `+` operand, among others - `git log --oneline --grep=
"0\.9\.1[5-7][0-9]" -E` for the full list). Treat "no gap remains open"
as "none is known right now," not as a claim the search is finished.

`0.9.198`-`0.9.209` (a second broader-mix round: `openstack.ansible-
hardening`, `githubixx.ansible_role_wireguard`, `ansible-community.
ansible-vault`): the `ansible-vault` role in particular surfaced a
cluster of related bugs all in the same family - real Ansible's
"recursive re-templating" (a variable whose own value is itself more
Jinja gets re-evaluated wherever referenced) turned out to have **four
separate, independently-buggy plain-lookup fallbacks** across the
engine, each fixed on its own: ConditionalEvaluator's bare `when:`
variable check, ExpressionEvaluator's filter-chain head resolution,
FilterEngine's `default()`-argument resolution, and ComparisonEvaluator's
bare comparison-operand lookup - `git log --oneline --grep="0\.9\.19
[9]\|0\.9\.20[0-9]" -E` for the full list. Also fixed in this round:
an else-less inline-if (`'x' if cond`, no `else`) not rendering as ""
like real Jinja2's `Undefined`; a ternary branch that's a bare `true`/
`false` literal (not a quoted string) resolving to "undefined"; a
parenthesized ternary as a `default()` argument not being unwrapped
before its own `if`/`else` was searched for; Jinja2's `~` string-concat
operator being entirely unimplemented anywhere in the engine; `or`/
`and`/`is` boolean logic not understood inside a plain `{{ }}` span
(only inside a bare `when:`); `copy:` embedding a large file's whole
content as a JSON param string then base64-encoding the *entire config*
a second time for SSH transport, overflowing Crystal stdlib's
`Base64.encode_size` (Int32 arithmetic) for a ~530MB file and crashing
the whole engine rather than failing one task; `copy:` not handling an
existing-directory `dest:` (real Ansible appends `src`'s basename); and
`shell:`'s `executable:` (custom-shell) form naively wrapping the whole
command in `'...'` without escaping the command's own embedded single
quotes, corrupting anything using `cut -d' '`/`tr -d 'x'`-style
pipelines.

`0.9.210`-`0.9.224` (a third broader-mix round: `cloudalchemy.
prometheus`, `cloudalchemy.grafana` - both new monitoring-stack roles,
both now reach `failed=0` with genuinely healthy services, not just a
clean exit code): `resolve_plus_operand`'s own plain-lookup fallback
turned out to be the FIFTH independent copy of the recursive-re-
templating bug (a bare identifier used as a `+`/`~` operand, e.g.
`('linux-' + go_arch + '.tar.gz')`) - `git log --oneline --grep="0\.9\.2
1[0-9]\|0\.9\.22[0-4]" -E` for the full list. Two real engine crashes
found and fixed: a bare quoted-literal fix regressed into wrongly
swallowing a `+`-chain (`'a' + var + 'b'` both start/end with `'`,
mistaken for one literal - fixed immediately after, same round); and a
genuine stack overflow when a single variable's value mixes `{{ }}`
and `{% %}` in the same string (`CrinjaRenderer#prepare_crinja_vars`'s
own pre-render step recursing into itself unboundedly - fixed with a
process-wide recursion-depth cap). Also fixed: `lookup('url', ...)`
entirely unimplemented (plus not following redirects, which is how
GitHub actually serves release-asset URLs in practice); `copy:`
directory-`src:` support entirely unimplemented (a documented scope
cut, real Ansible's own rsync-style trailing-`/` convention now
matched); `copy:`'s own `owner:`/`group:` handling was a **dead no-op
stub** the whole time (comments claimed "not available in Crystal
stdlib," which was simply wrong); `apt:`/`package:`'s own `state:
latest` used `apt-get install --only-upgrade`, which silently skips
(doesn't install) a package that isn't already present - two
independent copies of the same bug, in two different plugins;
`with_fileglob:` templating a list variable rendered the JSON-array
TEXT as one glob pattern instead of one pattern per list element;
`mode: 0770` (unquoted - the way most playbooks write it) got silently
decimal-converted by YAML 1.1's own leading-zero-is-octal rule, then
double-octal-reinterpreted downstream; `is mapping`/`is sequence`
Jinja2 type tests and `is (not) defined` on a dotted path
(`x.y is not defined`) both entirely unimplemented; `to_nice_yaml`
(a real Ansible filter) unimplemented; `ansible.builtin.apt_key`
(deprecated in real ansible-core but still shipped and still used)
unimplemented.

`0.9.172`-`0.9.180`: the `geerlingguy.*` role family (docker, mysql,
postgresql, nginx, php, security - none tried before) found 13 more real
bugs in one round, several engine-wide rather than role-specific -
`git log --oneline --grep="0\.9\.1[7-8][0-9]" -E` for the full list.
Highest-value: **`pre_tasks:`/`post_tasks:` play keywords were entirely
unparsed** (a documented-in-comment, but not previously listed here,
simplification) - silently never ran, no warning; and real Ansible's own
recursive re-templating of a variable whose *value* is itself more Jinja
(common in role defaults, e.g. `nginx_worker_processes: '"{{
ansible_processor_vcpus | default(ansible_processor_count) }}"'`) wasn't
applied when that variable was used inside a real `.j2` template file,
only in plain `{{ }}` task-param substitution - the literal unparsed
`{{ ... }}` text landed in the rendered config file itself. Also fixed:
`lookup('first_found', ...)` resolving `paths:` against the wrong
directory (cwd instead of the current role, both when omitted and when
given as an explicit relative path); a `with_items:` single-element-array
item that merely *embeds* a template misparsed as the unrelated "whole
array is a list template" idiom; `.split(sep)[index]` Python-style
dotted method calls; `dirname`/`basename` filters entirely missing; the
`comment` filter's `decoration=` kwarg ignored; a loop item's own bare
`{{ var }}` value losing its native type (int/bool) once rendered;
`default(fallback, true)`'s boolean form not catching a real falsy
(not just undefined) value; and `postgresql_db`'s `encoding:` over-
validated as a strict SQL identifier when it's actually a safely-quoted
string literal.

`0.9.172` (found rebuilding the perf-benchmark playbook, not a role
round): Jinja2/Python's `range(...)` function-call syntax (`loop: "{{
range(1, 11) | list }}"`) was never recognized - routed to a plain
variable lookup on the literal text `range(1, 11)`, always undefined,
silently running the loop body once with `item` undefined instead of
iterating. Fixed generally (bare `range(stop)`, `range(start, stop)`,
`range(start, stop, step)`, negative step, expression/variable
arguments, with or without a following `| list`).

Narrow, deliberately-scoped items:

- **`meta:`** supports only `clear_facts`. `end_play`/`flush_handlers`/
  `refresh_inventory`/`clear_host_errors` act on execution-flow machinery
  this engine models differently, and are rejected at parse time rather
  than silently ignored.
- **`docker_*` `api_version:`** is deliberately not planned - the
  underlying `docr` client uses unversioned endpoint URLs throughout, so
  pinning a version means touching every endpoint in a separate shard.
  The unversioned URLs negotiate fine against current Docker and Podman.
  Revisit only if a real playbook actually needs the pin.
- **Cloud plugins** (`ec2`, `s3_bucket`, `azure_rm_*`) and inventory
  *plugins* (`aws_ec2.yml` et al.) remain explicitly lowest-ROI and are
  not planned.
- **Role-private custom modules** (a role's own `library/*.py`, outside
  the `ansible.builtin`/`community.*`/etc. plugin set this engine ships)
  aren't executed - there's no generic arbitrary-Python-module runner. A
  task using one is skipped with "Plugin not available" rather than
  crashing the run, but anything downstream that depends on its result
  sees that value as undefined, which can cascade into broader task-
  status divergence from real Ansible. Seen repeatedly benchmarking
  `linux-system-roles`: `sr_fingerprint`, `timesync_provider`,
  `kernel_settings_get_config`, `blivet`.
- **`crystal-mysql`'s wire-protocol driver has no `unix_socket`/
  `auth_socket` auth support** - only `mysql_native_password`/
  `caching_sha2_password`. A role connecting via `login_unix_socket:`
  with no password (a common, real MariaDB/Debian-packaging pattern)
  fails every `mysql_*` plugin call. Real low-level driver work (raw
  socket fd access, plugin negotiation) - not fixed; see `git log --all
  --grep=auth_socket` for the investigation.
- **`to_datetime()`/timedelta arithmetic beyond subtraction** stayed
  narrowly scoped to what real roles have needed so far - revisit if a
  role needs more.
- **`ansible.builtin.deb822_repository`** (real ansible-core module,
  2.15+, for Debian's newer `.sources` repo format) isn't implemented -
  `geerlingguy.docker`'s own "Add or remove Docker repository." task is
  skipped ("Plugin not available"), so the Docker apt repo is never
  added and every downstream `docker-ce` package install fails. A
  reasonably scoped candidate for a future session (signed_by: URL
  download + local keyring storage needs verifying against real
  ansible-playbook's exact semantics first, not assumed).

`postgresql_privs` is the one per-plugin scope-cut list this project
originally tracked that reached **zero open items** (`0.9.84`) - every
`type:` real Ansible's module supports is implemented, including
`function`/`procedure` signatures and `default_privs`. New scope cuts get
found continuously through real-host benchmark rounds against production
Ansible roles instead of from a static pre-planned list; `git log` for
each round's own commits for what it left open, if anything.
