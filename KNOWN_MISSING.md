# Known Missing / Known Gaps

The goal is 100% behavioral compatibility with `ansible-playbook`,
verified against real runs rather than assumed - not "cover the common
cases." This file tracks what's actually missing today. It intentionally
does **not** carry implementation history or root-cause narrative for
fixed bugs - that detail lives in `git log` commit messages, written at
the same level of detail per commit; search there (e.g. `git log --all
--grep=auth_socket`) rather than in a second, easily-stale copy here.

**Currently at `0.9.371`.**

---

`0.9.371` (part 3 of the scope-cut pass) - `archive:`'s `attributes:`
(chattr(1) flags, unconditional, fails on a real chattr error - verified
against real AnsibleModule's own `set_attributes_if_different` source)
and `seuser:`/`serole:`/`setype:`/`selevel:` (SELinux context via
`chcon`, verified against real AnsibleModule's own `selinux_enabled()`/
`set_context_if_different` source to correctly no-op entirely when
SELinux isn't enabled on the target at all, matching real Ansible's own
confirmed behavior - checked here via `/sys/fs/selinux/enforce`'s
existence; the chcon-invocation shape itself on an actually-SELinux-
enabled host is implemented per `chcon(1)`'s documented flags but not
live-verified, no such host available in this project's usual Ubuntu/
Debian benchmark environment). `gem:`'s `repository:` (`--source`),
`include_dependencies:` (default **true**, not false - only ever adds a
flag when explicitly set false) and `norc:` (`--norc`) - verified
against real community.general gem.py's own `install`/`uninstall`/
`common_opts` source directly, including flag order, via a new pure
`PluginHelpers::GemCommand` (gem isn't installed on the dev machine
either, so this one is command-construction-verified via unit specs
against the real source, not live-executed).

---

`0.9.370` (part 2 of the scope-cut pass) - `apt_key:`'s `keyserver:`
(fetches by `id:` via `apt-key adv --no-tty --keyserver <keyserver>
--recv <id>`, verified against real ansible/modules/apt_key.py's own
source including its exact "Missing key_id, required with keyserver."
validation message); `deb822_repository:`'s remaining DEB822 keys
(`trusted`/`enabled`/`allow_insecure`/`allow_downgrade_to_insecure`/
`allow_weak`/`pdiffs`/`by_hash`/`check_date`/`check_valid_until`/
`languages`/`targets`/`date_max_future` - `architectures` turned out to
already be implemented, the doc comment was just stale). While
implementing these, found and fixed a real PRE-EXISTING bug in the
already-implemented fields too: real Ansible writes DEB822 fields in
ALPHABETICAL ORDER BY THE UNDERLYING PARAM NAME (`sorted(params.
items())`), not the fixed Types/URIs/Suites/Components/Architectures/
X-Repolib-Name/Signed-By order this plugin used - verified directly
against a real `ansible-playbook -vvv --check` run's own `repo:` return
value. This didn't affect apt's own functional parsing (DEB822/RFC822
format doesn't care about field order) but would have spuriously
reported `changed` on a warm rerun against any file real Ansible itself
had written, since the idempotency check compares rendered content
byte-for-byte. Extracted the field-sorting logic into a new pure
`PluginHelpers::Deb822RepositoryContent`, unit-spec-covered against the
exact real-Ansible-captured output. `no_log:` redaction of sensitive
params like `yum_repository:`'s `proxy_password:` was considered and
explicitly NOT done here - it's a cross-cutting framework feature (task-
invocation display, not a single plugin's own result) that no plugin in
this codebase implements yet, not a narrow single-plugin scope cut;
doing it for just one param in one plugin would be inconsistent scope.

---

`0.9.369` (part 1 of a "fix every remaining narrow scope cut" pass, on
direct request) - closes three: `modprobe:`'s `params:` (extra modprobe
arguments, verified against real community.general modprobe.py's source
to only ever apply at initial load time, never re-checked against an
already-loaded module - split into a new pure `PluginHelpers::
ModprobeCommand`, unit-spec-covered); `find:`'s `mode:`/`exact_mode:`
(octal and the common `u=,g=,o=` symbolic assignment form, verified
against real ansible/modules/find.py's own `mode_filter` source
including its non-obvious non-exact "ANY requested bit present"
semantics - not "every bit present" the docs' prose implies; a new
`PluginHelpers::FindModeFilter`, unit + integration spec covered, and
live-verified end-to-end against a real `ansible-playbook` run against
the identical fixture files) and `limit:` (stops once N matches are
found; the existing directory walk was already top-down/pre-order, so
no walk-order change was needed); `wait_for:`'s `search_regex` matched
against an open socket, not just a file (verified against real
ansible/modules/wait_for.py's own source: connects, reads until match/
close/timeout - also fixed the port-based timeout message to include
the search string, which it was silently omitting even before this
change, verified byte-for-byte identical against a real `ansible-
playbook` run against the same fake TCP server). More to follow in
subsequent commits under the same version.

---

`0.9.368` - closes the one remaining gap `0.9.367` explicitly left open:
`state: remounted`'s own `opts:`-absent fallback. When `opts:` is
absent/`"defaults"` and a bare `mount -o remount` fails (the common case
right after adding a fstab entry in the same task/play, before the mount
point is "really" mounted from fstab's point of view), real
`ansible.posix.mount`'s own `remount()` doesn't fail outright - it falls
back to a full `umount` + `mount <path>` cycle (the second bare `mount
<path>`, no `-t`/`-o`, consults fstab for the matching line). This
plugin previously had no fallback implemented at all for that case and
just reported `changed: true` regardless, matching neither a real
success nor a real failure. Implemented via a new
`remount_via_umount_mount` helper; only fails for real now if BOTH the
initial remount attempt AND the umount+mount fallback fail. Every
`mount`/`umount` invocation in this plugin now propagates a real command
failure - no exit-code-blind path left in the file at all. Regression
specs added for both the `opts:`-given failure message and the
`opts:`-absent fallback-then-real-failure path, using a real remount/
umount/mount attempt against `/` guaranteed to fail in this sandbox (no
`CAP_SYS_ADMIN`) - no actual filesystem is touched either way.

---

`0.9.367` - follow-up to the `0.9.366` audit pass: `mount.cr`'s own
`ensure_mounted`/`ensure_unmounted`/`ensure_ephemeral`/`ensure_ephemeral_
remount` had the exact same "real command failure silently discarded"
gap `0.9.366` explicitly declined to touch (previously flagged as an
already-documented, deliberate scope cut rather than an oversight -
fixed now on request rather than left alone indefinitely). All four now
propagate a genuine `mount`/`umount` failure as a real task failure with
the command's own stdout/stderr, matching real `ansible.posix.mount`'s
verified behavior (`module.fail_json(msg="Error mounting/unmounting %s:
%s" % ...)`). `state: remounted`'s own ALREADY-correct exit-code check
(for the `opts:`-given case) is untouched; its one remaining documented
gap - the `opts:`-absent fallback to a full `umount`+`mount` cycle via
the fstab entry - is still not implemented, and is now the only
remaining exit-code-blind path in this plugin, explicitly by design (not
by omission). Regression specs added to `spec/integration/mount_spec.cr`
for both `state: mounted` and `state: unmounted` failure propagation,
using a real (guaranteed-to-fail-in-this-sandbox, no `CAP_SYS_ADMIN`)
`mount`/`umount` attempt - no actual filesystem is mounted or unmounted
by the spec either way.

---

`0.9.366` - proactive audit pass, prompted directly by round 33's
`apt_repository.cr` findings (a real command's failure silently swallowed
instead of failing the task). Searched the rest of the plugin set for the
same shape - `remote_exec(...)` results whose exit code is never checked
by the caller - and for `dnf.cr`'s own copy of the round-32 virtual/
Provides:-satisfied-package idempotency bug. No new host round; fixes
verified via local specs (or documented as unverified where a live host
of the right OS family isn't available).

- **`dnf.cr`'s `handle_install` never got the virtual/Provides:-satisfied
  package fix `apt.cr` (round 15/0.9.258, the ruby round) and `package.cr`
  (round 32/0.9.362) already have.** `package_installed?`'s own `dnf list
  installed <name>` pre-check only ever looks up the literal requested
  name, which a purely virtual/Provides:-satisfied name never has its own
  entry for - so it always fell through to "needs install", and since dnf
  itself prints a literal `"Nothing to do."` and still exits 0 for that
  case (a genuine no-op), trusting exit_code alone always reported
  `changed: true` even when nothing happened. Fixed the same way as the
  other two copies: check for dnf's own no-op message. **Not live-
  verified this round** - no RPM-family host available; flagged the same
  way round 32 flagged this exact gap without fixing it. No spec added
  (dnf isn't installed on the dev machine either).
- **`sysctl.cr`'s `apply_kernel_value` (the `sysctl_set: true` live
  `sysctl -w` call) discarded its result entirely - `execute()`
  unconditionally returned `failed: false` regardless of whether the
  live kernel-parameter set actually succeeded.** Real
  `ansible.posix.sysctl` fails the task when this fails, unless
  `ignoreerrors:` is set (forwarded to `sysctl`'s own `-e` flag).
  Fixed to check the exit code and fail (respecting `ignoreerrors:`).
  Regression specs added to `spec/integration/sysctl_spec.cr` using a
  deliberately bogus dotted name - real `sysctl -w` genuinely fails for
  any name with no matching `/proc/sys/` path on any Linux host,
  verified directly against the real binary, not assumed; no real kernel
  parameter is touched either way.
- **`unarchive.cr`'s `apply_dest_attributes` (the round-32
  `chown -R`/`chgrp -R`/`chmod -R` fix itself) discarded ITS OWN result
  too** - a bogus `owner:`/`group:` name would silently "succeed"
  instead of failing the task, the same shape one layer down from the
  bug that introduced it. Fixed to check each command's exit code and
  fail with a clear message; regression spec added to
  `spec/integration/unarchive_spec.cr` using a nonexistent owner name
  (no real chown of anything the spec doesn't own).
- **Left as-is at the time** (fixed in the very next pass, `0.9.367`
  below, on request): `mount.cr`'s own `ensure_mounted`/
  `ensure_unmounted`/`ensure_ephemeral` helpers were ALSO exit-code-blind
  by the same shape, but were flagged rather than fixed here since the
  class-level doc comment described it as a deliberate scope cut. Also
  checked and found clean (already correctly re-templates/
  propagates failures, no action needed): every other
  `VariableLookup.new(vars).resolve(...)` call site across the codebase
  (recursive re-templating - the audit pass from 2026-08-11 already
  covers all of them), and `apt_repository.cr`'s own PPA-key-fetch paths
  (`ensure_ppa_key`/`import_via_gpg`, already verify success via the
  resulting keyfile's existence/size, not just a discarded exit code).

---

`0.9.363`-`0.9.365` (round 33 - `robertdebock.nomad` + its prerequisite
`robertdebock.hashicorp`, first new role tested since round 32's
nextcloud): 3 real bugs found and fixed on a fresh `G3.2GB` Atlantic.net
pair, plus several external/environment findings verified identical on
both engines (not crystal-ansible issues).

- **`0.9.363`: `conditional_evaluator.cr` had no fallback for any
  unimplemented Jinja2 `is [not] <test>` - always evaluated `false`
  regardless of the real test outcome, not just "usually wrong".** Every
  specific `is` pattern this module hand-implements (`version`,
  `defined`/`undefined`, `mapping`/`sequence`/etc, `match`/`search`)
  returns early; anything else (`divisibleby`, `even`, `odd`, `equalto`,
  `sameas`, `escaped`, `callable`, ...) fell all the way through to
  `#evaluate_truthiness`, which has no notion of `is` tests at all - the
  WHOLE condition string ("n is not divisibleby 2") was looked up as if
  it were a literal (nonexistent) variable NAME, always undefined -> nil
  -> false. The role's own `assert: nomad_server_bootstrap_expect is not
  divisibleby 2` (verifying an odd bootstrap_expect count, default `1`)
  always failed despite `1` genuinely being odd - and would have
  identically "passed" for an even value too, since both outcomes
  collapse to the same always-false bug. Fixed with a generic fallback:
  any unmatched `is`/`is not` condition now delegates the whole
  expression to Crinja (`{{ (condition) }}`), which already implements
  every real Jinja2 test correctly by construction, instead of
  reimplementing each built-in test's semantics by hand. Regression spec
  in `spec/unit/conditional_evaluator_spec.cr`.
- **`0.9.364`-`0.9.365`: `apt_repository:`'s post-add `apt-get update`
  failure was silently swallowed, never propagated as a task failure -
  and once fixed to propagate it, needed a second fix to also roll back
  the just-written repo line on that failure, matching real Ansible's
  own behavior.** `plugins/apt_repository.cr`'s `run_update_cache` ran
  `apt-get update` and discarded the result entirely; `#add`/`#remove`
  unconditionally returned `changed: true, failed: false` regardless.
  This mattered far more than it looks: `robertdebock.hashicorp`'s own
  "Install repository for Debian (modern method)" task sits inside a
  `block:`/`rescue:` specifically so a GPG-key failure falls back to the
  legacy `apt_key` method - with the update failure swallowed, the block
  never saw a failure and the `rescue:` never ran, so the broken
  (ascii-armored-not-dearmored - a real bug in the ROLE itself, not just
  environmental) keyring silently stuck around and a LATER, unrelated
  task (`apt-get install nomad`) failed instead ("Unable to locate
  package nomad") - the wrong task boundary for the same underlying
  failure. Fixed in `0.9.364` by checking `apt-get update`'s exit code
  and failing the task when it's non-zero. That surfaced a SECOND-order
  bug: the legacy method's `rescue:` retry now correctly ran, but wrote
  its own (no `signed-by=`) repo line into the SAME target file
  alongside the modern method's own (never-cleaned-up) broken line -
  `find_source` only ever checks for an EXACT line match, so two
  differently-formatted lines for the identical repo URL coexisted, and
  apt itself then refused outright ("Conflicting values set for option
  Signed-By"). Fixed in `0.9.365` by rolling back the just-appended line
  (deleting the file entirely if that empties it) whenever the post-add
  cache update fails, matching real ansible-playbook's own verified
  behavior (checked directly: real Ansible's resulting `.list` file had
  only the legacy method's line, no trace of the modern method's failed
  attempt at all). No spec added for either fix - real `apt-get`
  mutation against the dev machine's own package state, same
  verify-live-only category CLAUDE.md already documents.
- **Live-verified**: crystal cold pass `ok=26 changed=7 failed=1
  skipped=13 rescued=1` vs python `ok=24 changed=0 failed=1 skipped=13
  rescued=1` (changed-count diff is cached-vs-fresh package/repo state
  between runs, not a real divergence - task-by-task sequence and status
  match 1:1 modulo the standing `Gathering Facts`/unnamed-`block:`-task-
  banner cosmetic gaps already known from prior rounds). Confirmed the
  hashicorp `.list` file has exactly one line post-fix (no
  Signed-By conflict), `nomad` package installed, service `active`, and
  `curl :4646/v1/status/leader` answers correctly on crystal - matching
  python exactly.
- **External/environment findings this round (verified identical on
  both engines, NOT crystal-ansible bugs)**: (1) `ansible_default_ipv4.
  address` resolves to a stale/wrong IP on this specific Atlantic.net
  host (a real address from a DIFFERENT interface/allocation, not the
  host's own `eth0` IP) - worked around in the test playbook via
  `nomad_server_bind_addr: "{{ ansible_host }}"` instead. (2) Nomad
  v2.0.5 (current release as of this round) fails to start at all with
  the role's own default `bind_addr: "0.0.0.0"` ("Failed to resolve Serf
  advertise address: lookup <nil>: no such host") - needs an explicit
  bind address, a real Nomad-version/role-vintage incompatibility. (3)
  Once bind_addr is a specific IP (not `0.0.0.0`), Nomad's HTTP listener
  no longer binds `127.0.0.1` at all, so the role's own `nomad server
  members`/`nomad server join` CLI invocations (which hardcode an
  implicit `http://127.0.0.1:4646` client default) can never succeed -
  reproduced as the SAME failure on both engines (`List server members`
  in the recap above), a real, unfixable-from-our-side role/CLI-default
  limitation for any single-node deploy that isn't `0.0.0.0`-bound. (4)
  The role's own "List server members" task has no `wait_for`/retry
  after "Start nomad", racing against Nomad's own HTTP API startup time
  - reproduced on both engines equally.

---

`0.9.360`-`0.9.362` (round 32 - `robertdebock.nextcloud`, first new role
tested since round 31's ssh_hardening): 3 real bugs found and fixed on a
fresh `G3.2GB` Atlantic.net pair.

- **`command:`'s `chdir:` used to crash an otherwise-successful task under
  `become_user:` (0.9.360).** `plugins/command.cr` saved `Dir.current` up
  front and tried to `Dir.cd` back to it after running the command -
  completely unnecessary, since the plugin process exits right after
  `execute` returns and never runs further code in its own original cwd.
  On a real remote `become_user:` invocation the process starts with cwd
  inherited from the SSH login user's home (root's, `/root`, mode 700) -
  restoring to that path as an unprivileged become_user with no
  permission on `/root` raised an uncaught `Dir.cd` exception AFTER the
  real command had already run successfully, crashing an otherwise-
  successful task. The role's own `Configure nextcloud` task (`command:
  php occ maintenance:install ..., chdir: /var/www/html/nextcloud,
  become_user: www-data`) hit this every time. Fixed by removing the
  pointless restore entirely; regression spec reproduces the same failure
  class (a `Dir.cd` to a now-nonexistent original directory) without
  needing a real become_user, in `spec/integration/command_spec.cr`.
- **`unarchive:`'s `owner:`/`group:`/`mode:` only ever applied to the
  destination directory itself, not recursively (0.9.361).**
  `plugins/unarchive.cr`'s `apply_dest_attributes` ran a plain `chown
  #{owner} #{dest}` (no `-R`) - real `ansible-playbook`'s own unarchive
  module does a final recursive pass over every extracted path. Verified
  live: the role's `Install nextcloud` task (`owner: www-data, group:
  www-data`) left the ENTIRE extracted tree `www-data:www-data` on real
  ansible-playbook (dest itself, every subdirectory, every file down to
  `AUTHORS`) - crystal-ansible left everything but `dest` itself
  `root:root`, breaking the role's own downstream `occ` commands
  ("Cannot write into 'apps' directory", `Configure nextcloud`'s handler
  chain failing). Fixed with `chown -R`/`chgrp -R`/`chmod -R`; regression
  spec added to `spec/integration/unarchive_spec.cr` (using `mode:`,
  since the spec runs as a normal user and can't chown to an arbitrary
  user without root).
- **`package:`'s virtual/Provides:-satisfied package names always
  reported `changed` forever, never converging on a warm rerun
  (0.9.362).** `plugins/package.cr`'s `handle_apt` is a SEPARATE code
  path from `apt.cr` (the OS-agnostic `package:` module vs. the
  Debian-specific `apt:` module - this project's usual "same bug class,
  independent copies" pattern) - it never got the `apt_summary_had_no_
  effect?` fix `apt.cr` already has for exactly this (found during the
  ruby round, see `0.9.258`). The role's own `Install requirements` task
  (`package: {name: [php-bcmath, ..., php-dom, php-posix, ...]}`)
  includes `php-dom`/`php-posix`, which aren't real dpkg packages on
  modern Ubuntu at all - only names apt resolves via `Provides:` to
  `php8.1-xml`/`php8.1-common` - so the pre-install `dpkg -l` check (which
  only ever looks up the literal requested name) always found them
  "not installed" and re-ran `apt-get install` on every single run;
  apt's own exit code is 0 either way (a genuine no-op), so trusting
  exit_code alone always reported `changed: true`. Fixed the same way
  `apt.cr` was: parse apt's own "N upgraded, N newly installed" summary
  line and treat "0 upgraded, 0 newly installed" as a no-op regardless of
  exit code. No spec added (real `apt-get` mutation against the actual
  dev machine's package state, same category CLAUDE.md already
  documents as verify-live-only) - verified live instead: crystal cold
  pass `ok=27 changed=11 failed=0 skipped=6` (matching python's `ok=26
  changed=11 failed=0 skipped=7` shape, task-by-task identical modulo the
  usual `Gathering Facts` cosmetic extra task), and a warm rerun now
  reports `ok=20 changed=0 failed=0 skipped=6`, exactly matching python's
  own warm `ok=18 changed=0 failed=0 skipped=8` (same shape, the count
  diffs being the standing `Gathering Facts`/role-name-prefix cosmetic
  gaps, not a real divergence) - fully idempotent on both engines.

---

`0.9.359` (round 31 - `devsec.hardening.ssh_hardening`, first new role
tested since round 30's prometheus): 1 real bug found and fixed on a
fresh `G3.2GB` Atlantic.net pair.

- **`regex_replace`'s `\1`/`\2` backreference translation was backwards
  and actively broke every replacement using them.** The role's own
  `sshd_version_raw.stderr | regex_replace('.*_([0-9]*.[0-9]).*',
  '\1')` (parsing `ssh -V`'s stderr down to a bare version number, e.g.
  `"OpenSSH_8.9p1 ..."` -> `"8.9"`) instead produced the literal string
  `"$1"`. `jinja_filters.cr`'s `regex_replace` used to rewrite
  Python-style `\1`/`\2` replacement backreferences to `$1`/`$2` on the
  mistaken assumption that Crystal's `String#gsub(Regex, String)` used
  Ruby-style `$`-backreferences. It doesn't - Crystal's own gsub
  already interprets `\1`/`\2` identically to Python's `re.sub`, so no
  translation was ever needed, and the "translated" `$1` replacement
  was emitted completely literally (Crystal's gsub has no special
  meaning for `$1` at all). Every downstream `when: ... is version(...)`
  gate depending on the parsed value then evaluated against the literal
  string `"$1"` instead of a real version - in this role, 3 separate
  `set_fact:` tasks (openssh-version-gated host-key/macs/ciphers/kex
  variable defaults) all silently kept their variables undefined,
  crashing 3 tasks later on `loop: "{{ ssh_host_key_files }}"` (etc.)
  with `item` = the literal string `"undefined"`. Fixed by removing the
  `\1`->`$1` conversion entirely; regression spec added to
  `spec/unit/crinja_renderer_spec.cr`.
- **Live-verified**: cold pass `ok=34 changed=5 failed=0 skipped=5` vs
  python `ok=41 changed=8 failed=0 skipped=4` (task-by-task diff is
  cosmetic-only - role-name-prefix stripping in crystal-ansible's own
  task-name display, plus the already-documented cosmetic
  role-vars/main.yml-sourced task-name-rendering gap on one task's
  name, `Check if for weak DH parameters in undefined` vs real
  Ansible's `.../moduli` - both engines report the same `ok` status for
  that task, no functional divergence). Both hosts became unreachable
  via `root@` SSH immediately after the play, identically on BOTH the
  python and crystal hosts - this is the role's own default
  (`ssh_permit_root_login: "no"`) correctly taking effect, not a
  crystal-ansible bug; we provisioned and ran the play as root, so this
  was expected once `sshd_config` was rewritten and `sshd` restarted
  (same pattern as round 24's konstruktoid.hardening UFW lockout
  finding). No further live health check was possible past this point
  without a non-root sudo user pre-provisioned; the task-by-task diff
  above (both plays completing successfully, `failed=0` on both,
  identical per-task status) is the verification available.

---

`0.9.358` (round 30 - `prometheus.prometheus.prometheus`, first new role
tested since round 28's pushgateway follow-up): 2 real bugs found and
fixed on a fresh `G3.2GB` Atlantic.net pair.

- **`fileglob`/`realpath` Jinja filters entirely missing from both
  evaluators.** The role's `Copy custom alerting rule files` task
  uses `loop: "{{ prometheus_alert_rules_files | map('ansible.builtin.fileglob')
  | flatten | map('ansible.builtin.realpath') }}"`. Neither filter was
  registered anywhere, so the raw glob-pattern strings passed through
  unchanged as if already-resolved paths, and the task failed with
  `Source file not found: prometheus/rules/*.yml`. Fixed by adding
  `fileglob`/`realpath` to `jinja_filters.cr` (Crinja) and to the
  hand-rolled `filter_engine.cr`'s `#apply` (which also needed a new
  general `ansible.builtin.` FQCN-prefix-stripping step, since it had
  none at all before this).
- **Crinja fork parser bug: multi-arg parenthesized `is name(a, b)`
  TEST calls never split their arguments.** The role's systemd unit
  template guards the modern `--storage.tsdb.retention.time` flag
  behind `{% if prometheus_version is version('2.7.0', '>=') %}`. This
  always evaluated false regardless of the actual version (default
  `3.13.0`), so the rendered unit used the deprecated
  `--storage.tsdb.retention` flag and prometheus crash-looped
  (`Error parsing command line arguments: unknown long flag
  '--storage.tsdb.retention'`). Root cause was in the Crinja fork's own
  `expression_parser.cr`: the filter/test-suffix parsing loop's
  `with_parenthesis` guard was `!is_test && current_token.kind ==
  Kind::LEFT_PAREN`, so a TEST call's opening `(` was never consumed -
  `('2.7.0', '>=')` got re-parsed from scratch as a single
  parenthesized tuple-literal expression, landing as ONE positional
  argument instead of two, silently defaulting the second (`operator`)
  keyword arg instead of raising. Fixed in the fork
  (`weirdbricks/crinja`, tag `crystal-play-0.9.7`, commit `8ded6dc0`)
  by dropping the `!is_test &&` guard entirely; regression spec added
  to the fork's own `spec/lib/tests_spec.cr`. crystal-ansible's
  `shard.yml` repinned to the new tag.
- **Live-verified end to end**: cold pass `ok=38 changed=10 failed=0
  skipped=14` vs python `ok=42 changed=14 failed=0 skipped=14` (count
  diff is from pre-staging the prometheus/promtool binaries via scp to
  skip a slow re-upload during investigation, not a real divergence -
  task-by-task diff is cosmetic-only, role-name-prefix stripping in
  crystal-ansible's own task-name display). `Copy custom alerting rule
  files` now correctly `skipping`, the rendered unit now uses
  `--storage.tsdb.retention.time=30d`, and `systemctl is-active
  prometheus` + `curl :9090/-/healthy` (200) confirm the service is
  actually healthy, not just exit-0.

---

**0.9.357 live-verified** (no version bump - confirms the already-
shipped fix, no new bug): re-ran `prometheus.prometheus.pushgateway` on
a fresh `G3.2GB` Atlantic.net pair. Cold pass now correctly fires
`HANDLER [Restart pushgateway]` with real output (`changed: Systemd
daemon reloaded, Unit restarted`) - matching real Ansible's own
`RUNNING HANDLER [prometheus.prometheus.pushgateway : Restart
pushgateway]`. Then deliberately forced a config-only change
(`pushgateway_web_telemetry_path: "/pushmetrics"`) on a second pass to
exercise the exact scenario the original bug broke - a warm rerun
where ONLY the config template changes and nothing else would
otherwise trigger a restart: the direct "Ensure Pushgateway is enabled
on boot" task correctly reported `ok` (not `changed`, matching python
exactly), and the handler alone fired and restarted the service.
Confirmed via `systemctl status` (fresh restart timestamp) and `curl`
(`/pushmetrics` → `200`, the old `/metrics` → `404`, proving the new
config genuinely took effect through the handler-driven restart, not
some other path). Also incidentally confirmed 0.9.354's `copy:`
checksum-skip fix live in the same round: "Propagate binaries" reported
`ok` (not `changed`) on the warm pass since the binary already matched.

`0.9.357` (closes the `notify:` substitution gap 0.9.356 found and
deferred - no new live round, verified via a repro matching the exact
live-found structure/failure mode instead):

- **`notify:` list entries were never re-substituted before being
  compared against a handler's own name.** `task.notify` is parsed
  once from raw YAML strings at parse time; all three call sites that
  fire a notification passed that raw string straight to
  `HandlerRunner#notify` with no templating step at all. A templated
  `notify:` (`prometheus.prometheus`'s own `_common` role idiom:
  `notify: "{{ ansible_parent_role_names | first }} : Restart
  {{ _common_service_name }}"`) could never equal any real handler
  name, so the notification silently never matched anything - the
  handler just never ran. Fix: new `TaskExecutor#notify_handlers`
  helper (mirrors `render_task_name_for_display`'s own lazy pattern -
  only builds a vars_context, not otherwise in scope at all three call
  sites, when at least one notify entry actually needs it) substitutes
  each entry before handing it to `HandlerRunner#notify`.
- **A role-loaded handler's own `name:` was also never re-rendered for
  MATCHING purposes** (separate from display, which 0.9.353 already
  fixed for regular tasks but not handlers) - `should_run_handler?`
  compared the raw, unrendered `handler.name` against the (now-
  substituted) notified set, so a templated handler name still never
  matched even once its own notifier was fixed. Fix: `HandlerRunner
  #run` now takes an optional `name_resolver` callback (same threading
  pattern as its existing `execute_callback`) that
  `TaskExecutor#run_handlers` supplies as
  `render_task_name_for_display` itself - the handler's real,
  rendered name is now used for banner display, `already_ran`
  dedup-tracking, and matching alike.
- **Real Ansible auto-namespaces a role-loaded handler with a
  qualifier prefix that isn't always the role that literally defines
  `handlers/main.yml`** - verified empirically against real
  `ansible-playbook`'s own recap output on the round-28 live host
  before it was destroyed: `_common`'s handlers (defined in `_common`'s
  own `handlers/main.yml`, loaded via a NESTED `include_role:` from
  `pushgateway`) got qualified as `"prometheus.prometheus.pushgateway
  : Restart pushgateway"` - the CALLING role's own FQCN, not
  `_common`'s. A role's own directly-defined handlers (e.g.
  `blackbox_exporter`'s, round 27) get qualified with their OWN FQCN
  instead. Replicating the exact qualifier-computation formula for
  every case is real, non-trivial, separate work. Implemented
  something simpler that covers the observed cases without needing
  to: any `"X : name"`-shaped notify string now matches a handler by
  its own bare rendered name, regardless of what `X` actually is - a
  handler name legitimately containing literal `" : "` text is
  exceedingly rare. The displayed handler banner text itself doesn't
  reproduce real Ansible's exact qualifier prefix (shows the bare name
  only) - a known, accepted cosmetic gap from this simplification.
- **A THIRD related gap found and fixed in the same investigation**: a
  role-loaded handler's own BODY execution (`TaskExecutor
  #execute_handler_internal`, a separate, older vars_context-building
  code path that predates and duplicates `#build_vars_context`) never
  populated `ansible_parent_role_names`/`ansible_collection_name`/
  `ansible_role_name` at all - so even once a handler correctly
  MATCHED and ran, any of its own params/rendering depending on those
  magic vars (exactly the `_common_service_name` chain again, now
  inside the handler's own `name:`/`systemd: name:` params rather than
  a task's) still resolved to `"undefined"`. Live symptom, reproduced
  directly: a fixed-notify test handler ran but its own `msg:` showed
  `"RESTARTED "` (the service-name variable resolving to empty/
  undefined) instead of `"RESTARTED outer"`. Fixed by adding the same
  three-line magic-var population `#build_vars_context` already has.
- Two new regression specs (`handler_notify_templating_spec.cr`) cover
  both the notify-templating fix and the role-qualified-prefix
  matching, using the compiled binary against a real (not `--check`)
  playbook - `TaskExecutor#notify_handlers`/`HandlerRunner
  #should_run_handler?` are private and not otherwise reachable from a
  unit spec. Verified end-to-end with a repro matching `_common`'s own
  exact nested-`include_role:` / templated-name / role-qualified-
  notify shape (not just the two isolated spec cases) - confirmed the
  handler now both fires AND resolves its own body correctly
  (`"RESTARTED outer"`, matching what real Ansible produces for the
  equivalent live pushgateway case).
- Full `crystal spec` suite: 1123 examples (was 1121), 0 failures.

`0.9.356` (round 28 - `prometheus.prometheus.pushgateway`, first new
role tested since round 27; also closes a real gap in 0.9.353's own
task-name-rendering fix):

- **0.9.353's task-name-rendering fix had a real interaction gap with
  round 26's own EARLIER (eager) task-name fix**, found live via this
  role's own `_common`-sourced "Create systemd service unit
  {{ _common_service_name }}" task banner still showing literally
  "undefined" even after 0.9.353 shipped. Root cause:
  `run_include_role_once`'s eager task-name substitution (added in
  round 26, only runs when an `include_role:` call has its own
  `vars:`) uses a narrower vars_context than the task ever actually
  executes with - missing the newly-loaded child role's own
  `vars/main.yml` entries and its `ansible_parent_role_names`/
  `ansible_collection_name` magic vars, neither available until the
  task actually runs. For a task name referencing only an
  explicitly-passed `include_role: vars:` entry (round 26's original
  case) this narrower context was enough; for one referencing
  anything else (`_common_service_name`, computed internally by
  `_common`'s own `vars/main.yml`, never passed as an include_role
  var at all) the eager substitution rendered the missing-var sentinel
  `"undefined"` and PERMANENTLY BAKED THAT INTO `task.name` - since
  0.9.353's lazy `render_task_name_for_display` only re-renders a name
  that still contains `{{`, and "undefined" has none, the later,
  correct, full-context render never got a chance to run at all.
  Reproduced by inserting a probe task immediately before the
  offending one: the probe's own body correctly resolved
  `_common_service_name` to `"pushgateway"` via the exact same
  vars_context machinery, proving the value was never actually
  unavailable - only the eager, narrower pre-render had gotten there
  first and gotten it wrong. Fix: removed the eager substitution block
  entirely - it's now fully redundant with 0.9.353's lazy render
  (which has a strictly more complete context) for every case it used
  to handle correctly, and no longer actively harmful for the cases it
  didn't. Also fixed "Download binary undefined" (same root cause, a
  separate `_common` task referencing an internally-computed var) as a
  side effect.
- **One more real gap found live while investigating, NOT fixed this
  round**: `_common`'s own generic cross-role handler notification
  (`notify: "{{ ansible_parent_role_names | first }} : Restart
  {{ _common_service_name }}"`, matched against a handler named
  `"Restart {{ _common_service_name }}"` with a role-name-prefixed
  notify convention) never actually fires - `task.notify` is set once
  at parse time from raw YAML strings and is never re-substituted
  anywhere before being compared against the loaded handler's own
  name. This is a pre-existing gap, not a regression from this
  round's fix or from 0.9.353 - confirmed by checking why round 27's
  own handler DID fire successfully: `blackbox_exporter` defines its
  own PLAIN-STRING handlers with `listen:` topics (`"restart
  blackbox_exporter"`, no Jinja at all), an entirely separate,
  simpler mechanism from `_common`'s generic templated one. The
  service still comes up correctly on a cold pass (the role's own
  direct "enabled on boot" task starts it regardless), so this only
  matters for a warm rerun where ONLY a config change occurs and no
  other task would otherwise trigger a restart - deferred to a future
  round; needs both `notify:` list substitution and role-namespaced
  handler-name matching, a distinct, more involved piece of work than
  a single-round fix.
- **Verified live** on a fresh 2-node `G3.2GB` Atlantic.net pair: cold
  pass `ok=28 changed=6 failed=0 skipped=8` vs python's
  `ok=31 changed=10 failed=0 skipped=9` (the differences are the known
  fact-cache `ok` artifact plus the one un-fired handler noted above -
  every other task's status matched 1:1 in sequence). `failed=0` on
  both; service verified `active` and answering `curl :9091` with
  `200`.
- Full `crystal spec` suite: 1121 examples, 0 failures (unchanged
  count - this was a targeted removal of dead/harmful code plus a
  live-reproduced fix, not a new isolated code path suited to a fresh
  spec; verified via the existing round-26 repro plus a new live-host
  probe instead).

`0.9.355` (proactive audit for the "same bug lives in multiple
independent copies" pattern - round 27 found this exact bug class in
`apt.cr` and, independently, `package.cr`; searched the rest of the
plugin set for more copies rather than waiting for another live round
to surface them one at a time):

- Grepped every plugin for the same `starts_with?('[') && Array(String
  ).from_json(...)`-only shape and found **three more copies with the
  identical gap**, none caught live yet:
  - **`dnf.cr`'s own `parse_package_names`** - same shape as `apt.cr`'s
    (which round 27 fixed) and `package.cr`'s (also round 27) copies.
  - **`unarchive.cr`'s `parse_list_param`** - used by `exclude:`/
    `include:`, same Jinja `{% if %}...{{ [list] }}...{% endif %}`
    idiom plausible there too.
  - **`set_fact.cr`'s `try_parse_json`** - the most general case: any
    `set_fact:`-assigned value that starts with `{`/`[` and is meant to
    be a real array/dict. Verified directly: `set_fact: my_list: "{%
    if true %}{{ ['a','b','c'] -}}{% else %}{% endif %}"` then `{{
    my_list | length }}` now correctly reports `3` (previously would
    have silently kept `my_list` as the literal string and either
    errored on `| length` or given a wrong/misleading result).
  - All three now have the same single-quote-to-double-quote JSON retry
    fallback as `apt.cr`/`package.cr` (round 27). `mysql_query.cr`'s
    own `starts_with?('[')` use (statement-list parsing, not a
    name/path list) and `ini_file.cr`'s (unrelated - INI section-header
    detection) were checked and don't share this bug class.
- Two new regression specs (`set_fact_spec.cr`, `unarchive_spec.cr`)
  cover the `set_fact:`/`unarchive:` cases directly; `dnf.cr` has no
  spec file at all (needs real `dnf`/`rpm` tooling this dev environment
  doesn't have, matching this codebase's existing "some things have no
  spec at all by design" precedent for apt/dpkg-mutating plugins) -
  verified via a standalone `crystal run` probe instead.
- Full `crystal spec` suite: 1121 examples (was 1119), 0 failures.

`0.9.354` (`copy:` checksum-first upload skip, no live round - see
0.9.353's note, same follow-up-work session):

- **`copy:`'s controller->remote large-file upload path
  (`TaskExecutor#stage_large_copy_source`) unconditionally SCP'd the
  source to a remote scratch path on every single run**, even when the
  destination already held byte-identical content - real Ansible's own
  `copy:` computes the source checksum locally and stats the
  destination remotely first, skipping the transfer entirely on a
  match. Noted as a non-blocking inefficiency in rounds 25-27's
  benchmark write-ups (a ~16-48MB binary re-uploaded on every warm
  rerun of `prometheus.prometheus`'s own binary-propagation task).
  Fix: new `precomputed_copy_match` - one remote round trip (not two)
  that resolves the real destination path (appending the source's
  basename if `dest` is already an existing directory, matching what
  `copy.cr`'s own dest-resolution does once it actually runs) and
  md5sums it in the same script, only if it exists. On a match, the
  upload is skipped entirely and the plugin is told via a
  `__precomputed_match` marker param to report `changed: false` and
  still apply file attributes (owner/group/mode can differ even when
  content matches) without ever touching `src` at all - `src` stays
  the original controller-only path in this case, since nothing was
  staged; `copy.cr` checks the marker before any `src`-dependent logic
  runs at all, not after. Deliberately conservative: skipped entirely
  when `force: false` (that case's own "dest exists at all ->
  unchanged" short-circuit lives in `copy.cr` and doesn't interact with
  a checksum at all) rather than teaching this optimization about it
  too; any error resolving the pre-check (SSH failure, etc.) falls
  through to the original unconditional-upload behavior unchanged.
- Two new specs (`copy_precomputed_match_spec.cr`) cover the
  plugin-side half of the contract - the executor-side remote checksum
  round trip itself has no unit-test coverage (needs a real SSH
  connection; `PluginSpecHelper` always runs the plugin binary
  locally), verified by code review and cross-checked against
  `copy.cr`'s own existing dest-resolution/idempotency logic instead of
  a live host round trip, per explicit user instruction not to
  provision new hosts for this contained change.
- Full `crystal spec` suite: 1119 examples (was 1117), 0 failures.

`0.9.353` (task-name display fix, no live round - the user asked to
work through this and a `copy:` inefficiency after round 27, without
needing another host round for either):

- **Fixed the cosmetic task-name-rendering gap** flagged in rounds 26
  and 27: a task `name:` sourced from a role's own `vars/main.yml` (or
  any other source not already covered by the narrow early-pass fixes
  for `include_tasks:`'s `include_vars:` and `include_role:`'s
  `vars:`) stayed unrendered in the `TASK [...]` banner even though the
  task body executed correctly. Root cause: every banner print site
  printed `task.name` raw, before that task's own vars_context existed
  - the body gets a full context at actual execution time
  (`execute_task` -> `build_vars_context`), but the banner never did.
  Fix: new `render_task_name_for_display` helper - lazily builds the
  vars_context and substitutes only when `task.name` actually contains
  `{{` (a literal name, the overwhelming majority, pays zero extra
  cost), with a best-effort `rescue` falling back to the raw name on
  any substitution error (cosmetic-only, so a failure here must never
  affect what actually runs). Applied at all four `"TASK [...]"` print
  sites (`task_executor/executor.cr`): the top-level per-play loop, the
  nested block/rescue/always task-list runner, and the block-skipped
  task-list printer. For the top-level loop (which prints once before
  iterating hosts), the multi-host case renders against whichever host
  will run first - the same "first host" convention this file already
  uses for `run_once:`.
- Verified with two repros: the round-26 `include_role: vars:` case
  (still renders correctly, no regression) and a new `vars/main.yml`-
  sourced case matching `__common_binary_basename`'s exact shape -
  both now show the fully-rendered name in the banner.
- Full `crystal spec` suite: 1117 examples, 0 failures.

`0.9.352` (round 27 - `prometheus.prometheus.blackbox_exporter`, first
new role tested since round 26, 3 real gaps found and fixed):

- **`ansible.builtin.package:`'s `name:` param failed to parse a
  Python-repr list string** (single-quoted, e.g. `"['python3-apt',
  'libcap2-bin']"`), falling back to a naive comma-split that left
  brackets/quotes stuck to the first/last package names
  (`"[python3-apt,"`, `"libcap2-bin]"`), which apt then rejected
  outright. This shape comes from the same `{% if %}...{{ [list_expr]
  }}...{% endif %}` Jinja idiom already fixed for `apt.cr`'s own
  `parse_package_names` in this same round (see below) - but
  `package.cr` has a completely independent copy of this exact parsing
  logic, and it's the one this role's own `_common_dependencies` task
  actually goes through (`ansible.builtin.package:`, not `apt:`
  directly). Both now have the same single-quote-to-double-quote JSON
  fallback. Third time this specific "JSON-array-shaped string parsing
  needs a Python-repr fallback" bug class has been found independently
  in a different plugin - matches the project's long-documented pattern
  of the same bug living in multiple unconnected copies.
- **`community.general.capabilities` had no plugin implementation at
  all** - any role using it (this one's own "Ensure blackbox exporter
  binary has cap_net_raw capability" task, granting `CAP_NET_RAW` so
  the exporter can send raw ICMP probes without running as root)
  silently skipped with "Plugin not available". New `capabilities.cr`,
  ported from the real Python module's own `getcap`/`setcap` output
  parsing (including the older `/path = cap+ep` getcap form, the newer
  `/path cap+ep` form, and comma-grouped caps sharing one op/flags
  pair) and update semantics (`state: present`/`absent`, check-mode
  support). Verified live: `getcap -v` on the installed binary shows
  `cap_net_raw=ep` after the role runs, matching what real Ansible sets.
- **Verified live** on a fresh 2-node `G3.2GB` Atlantic.net pair
  (USEAST2): cold pass `ok=31 changed=9 failed=0 skipped=5` vs python's
  `ok=34 changed=12 failed=0 skipped=7` (the count differences are the
  same fact-cache `Gathering Facts` artifact documented in round 25/26,
  not a real divergence - every task's `ok`/`changed`/`skipping` status
  matched 1:1 in sequence between the two logs). `failed=0` on both;
  the service came up `active` and answered `curl :9115` with `200`.
- Same cosmetic-only gap from round 26 (role vars/main.yml-sourced task
  names staying unrendered in `TASK [...]` banners, e.g. `TASK
  [Download {{ __common_binary_basename }}]`) observed again here -
  still not fixed, same architectural note applies.
- Full `crystal spec` suite: 1117 examples, 0 failures throughout, both
  fixes individually repro-verified (a standalone `crystal run` probe
  for the parsing logic, and a direct plugin-binary invocation with
  hand-built JSON stdin for the new `capabilities.cr`) before the live
  round confirmed them end-to-end.

`0.9.351` (round 26 - `prometheus.prometheus.alertmanager`, first new role
tested since round 25, 7 real engine bugs found and fixed):

- **Dict-literal `== {}` comparison always evaluated false.** A `when:`
  condition comparing a dict-valued variable to the literal `{}` (e.g.
  `alertmanager_route == {}`, the role's own preflight "fail if no route
  configured" check) always skipped instead of matching, because
  `ConditionalEvaluator#evaluate_value`'s return type has no `Hash` case
  at all - a dict variable's left side stringified via the `else` branch
  to compact JSON (`"{}"`), but the literal `{}` on the right side fell
  through every branch to "not a variable" -> `nil`, comparing a String
  against `nil`. Fix: special-case the bare `{}` literal to return the
  same `"{}"` string a Hash's own stringification produces.

- **`include_role:`'s own `vars:` weren't re-rendering the loaded role's
  task `name:` fields**, unlike `include_tasks:`'s equivalent
  `include_vars:` handling. A task like `_common`'s own
  `name: "Create system group {{ _common_system_group }}"` (with
  `_common_system_group` set only via the parent role's
  `include_role: vars:`) printed the literal unrendered template in the
  `TASK [...]` banner - and in this specific case, the SAME unrendered
  variable also fed a `when:` condition (`_common_system_group not in
  ansible_facts.getent_group`), which then evaluated against garbage and
  silently SKIPPED the group/user-creation task entirely. Fix: after
  `RoleLoader.load_single_role` returns, re-render each loaded task's
  `name:` against the include_role vars, mirroring the include_tasks
  pattern already in place.

- **`check_mode:`/`diff:` task keywords crashed on any non-literal-bool
  (templated) value and silently dropped the ENTIRE containing task
  file** - the most severe bug this round. Both used a bare `.as_bool`
  (raises "Cast from String to Bool failed" on a String value), unlike
  `ignore_errors:`/`become:`, which already tolerate a templated value.
  The exception propagated out of task-file parsing entirely, dropping
  every task in that file (both before AND after the offending one) -
  live symptom: the role's `configure.yml` (`diff: "{{ not
  alertmanager_mask_diff }}"` on its "Copy alertmanager config" task)
  lost 4 of its 5 tasks outright, including the one that writes
  alertmanager's actual config file. Fix: new
  `parse_optional_bool_or_template` helper (mirroring
  `parse_ignore_errors`'s pattern) returns `nil` (inherit the global
  `--check`/`--diff` CLI flag) for a templated/unrecognized value
  instead of raising.

- **Four missing Jinja tests/filters**, each failing an entire template
  render (Crinja has no partial-render fallback) the first time a real
  role's `.j2` template used them:
  - `version_compare` - deprecated alias of the already-registered
    `version` test, still emitted by this role's own
    `systemd.service.j2`.
  - `any`/`all` - real Jinja2 3.0+ built-in tests (iterable-truthiness),
    entirely unregistered in the fork.
  - `eq`/`lt`/`le`/`gt`/`ge` - real Jinja2's short comparison-test
    aliases (used almost exclusively as a `select()`/`reject()`
    predicate name, e.g. `values() | select('gt', 0)`); the fork had
    `equalto`/`lessthan`/`greaterthan`/`ne` but not these spellings.
  - `quote` - Ansible's own filter (shlex.quote-equivalent), not part
    of Jinja2 at all and not previously implemented; Crystal's
    `Process.quote` matches Python's `shlex.quote` on every case
    checked.

- **Verified live** on a fresh 2-node `G3.2GB` Atlantic.net pair
  (USEAST2, real `ansible-playbook` 2.19.4 vs crystal-ansible HEAD):
  cold pass `ok=32 changed=8 failed=0 skipped=19` vs python's
  `ok=35 changed=13 failed=0 skipped=20` (the count differences are
  the known fact-cache `ok` artifact plus this environment's `copy:`
  action re-uploading large binaries unconditionally rather than
  skipping on a remote-checksum match - see the minor-inefficiency
  note below, not a correctness issue). `failed=0` on both engines;
  every task the role expects to run (systemd unit, config file,
  amtool config) succeeded on crystal.

- **One known cosmetic-only gap left open, not fixed**: a task `name:`
  sourced from a role's `vars/main.yml` (as opposed to `include_role:
  vars:`, fixed above) still stays unrendered in the `TASK [...]`
  banner (e.g. `TASK [Download {{ __common_binary_basename }}]`) even
  though the task body executes correctly - `__common_binary_basename`
  is itself a templated `vars/main.yml` entry
  (`"{{ _common_binary_url | urlsplit('path') | basename }}"`). This is
  a distinct, deeper architectural gap (task names are rendered in
  scattered early one-time passes per var-source, not at actual
  per-task execution time) - display-only, not fixed this round.

- **One unrelated environmental finding, not an engine bug**: the
  role's rendered systemd unit (`-cluster.listen-address=` with an
  empty value, matching the role's own default) crash-loops real
  alertmanager 0.33.1 itself (`alertmanager: error: unknown short flag
  '-c'`) - reproduced by invoking the installed binary directly by
  hand, with no Ansible involved at all. A real role/software-version
  incompatibility, identical on both engines since both render the
  exact same systemd unit template.

- **Minor inefficiency noted, not fixed**: the `copy:` action
  re-uploads a large binary every run even when the remote file's
  content already matches (real Ansible's `copy:` computes a
  destination checksum first and skips the transfer on a match) -
  cosmetic/performance only, doesn't affect correctness, and outside
  this round's scope.

- **Full crystal spec suite: 1117 examples, 0 failures**, all 7 fixes
  individually repro-verified with a minimal playbook before the live
  round confirmed them end-to-end.

`0.9.350` (round 25 - live re-verification of `0.9.349`'s fixes on a
fresh Atlantic.net `G3.2GB` pair, `devsec.hardening.mysql_hardening`):

- **Cold pass**: crystal `ok=23 changed=10 failed=0 skipped=6` vs real
  `ansible-playbook` 2.19.4 `ok=22 changed=9 failed=0 skipped=6` (the
  `ok` count difference is this environment's global smart fact-cache
  reusing a stale entry under the shared inventory alias `target` for
  the python run, not a crystal-ansible bug). One real divergence
  found in the cold pass, not caught by `0.9.349`'s fixes: see below.

- **`mysql_query` reported `changed` unconditionally for any DML
  statement (INSERT/UPDATE/DELETE/REPLACE), even one that matched
  zero rows.** Real `community.mysql.mysql_query` (`ansible/mysql`
  collection form here) only sets `changed = true` for a DML
  statement when `cursor.rowcount > 0` - a 0-row `DELETE` is
  idempotent (`ok`), not `changed`. The plugin's own doc comment
  claimed "real Ansible's own module reports changed unconditionally"
  - that claim was simply wrong (verified against the actual
  `mysql_query.py` source, `DML_QUERY_KEYWORDS` loop). Live symptom:
  `devsec.hardening.mysql_hardening`'s `Ensure that root can only
  login from localhost` task (`DELETE FROM mysql.user WHERE ...`,
  0 rows affected on every run since no non-localhost root row ever
  exists) reported `changed` on every single run, cold and warm.
  Fix: `changed` is now `rows_affected > 0` for a recognized DML
  statement; unrecognized/DDL statements keep the prior
  unconditional-`true` behavior (the real module's DDL branch does
  its own already-exists detection this plugin doesn't replicate).

- **Warm rerun (idempotency) fully confirmed clean after this fix**:
  crystal `ok=22 changed=0 failed=0 skipped=6` vs python
  `ok=21 changed=0 failed=0 skipped=6` - `changed` and `skipped`
  counts now match exactly (the `ok` difference is the same fact-cache
  artifact as the cold pass). This is the live confirmation that all
  three items deferred in `0.9.348` - `file`'s `follow:` handling and
  `mysql_user`'s `host_all:` idempotency, both fixed in `0.9.349` -
  plus this round's `mysql_query` fix, hold up end-to-end on a real
  host. `Protect my.cnf` and `Ensure that the root password is
  present` both report `ok` on warm rerun, matching python exactly.

`0.9.349` (follow-up on round 24 role 2's deferred items, plus one
regression found while doing so):

- **`file` plugin's `follow:` param wasn't honored on the chown/lchown
  write path or the attribute-comparison read path.** Crystal's
  `File.chown` defaults to `follow_symlinks: false` (lchown behavior);
  a `follow: true` task now passes `follow_symlinks: true` through so
  the target, not the symlink, gets chowned. The "is this file already
  correct?" read path (`update_attributes_if_needed`) now uses a new
  `stat_follow` helper (real `stat()`, not `lstat()`) for owner/group/
  mode comparisons when `follow: true`, so a warm rerun compares
  against the target's actual metadata instead of the symlink's own -
  fixes the `Protect my.cnf` always-`changed` divergence from
  `devsec.hardening.mysql_hardening` documented under `0.9.348`.
  `File.chmod` needed no fix - Crystal's stdlib already always follows
  symlinks for chmod, matching `chmod(2)`'s own default.

- **`mysql_user`'s `host_all: true` expansion path ran `ALTER USER`
  unconditionally on every host row, with no password-already-matches
  check** - unlike the per-host path, which already calls
  `password_already_matches?`/`plugin_matches?` before altering. Fixed
  by adding the same check to the `host_all:` path. Fixes the
  `devsec.hardening.mysql_hardening` warm-rerun "Updated user root on
  all hosts" always-`changed` divergence also documented under
  `0.9.348`.

- **Regression found while fixing the above, unrelated to either
  deferred item**: `resolve_loop_flattened`'s literal-source handling
  (the `with_community.general.flattened:` no-value-sentinel fix
  landed in `0.9.348`) was missing an `else` - the sentinel-check
  branch was nested *inside* `if value` instead of being its `else`,
  so it only ever ran when `value` was already truthy, meaning every
  literal (non-templated) source silently produced zero items again.
  This is the same "drop literal sources" bug `0.9.250`-`0.9.251`
  fixed originally, reintroduced by the `0.9.348` edit despite that
  commit's own claim of "0 failures" on the full spec suite -
  `spec/integration/with_flattened_spec.cr` was not actually run as
  part of that verification. All 4 examples in that file now pass
  again; full suite re-confirmed at 1117 examples, 0 failures.

`0.9.348` (round 24 role 2 - `devsec.hardening.mysql_hardening` collection
form - clean cold pass plus one new engine bug fixed live, plus a
role-loader bug found in the process; 2 more engine bugs found but
deferred to a future round; no divergence on the items that
_python_ kept clean):

- **`role_loader.cr` collections path used `File.expand_path` which
  does NOT expand a leading `~`** - silent bug that masked the
  whole `~/.ansible/collections` default lookup. Crystal's
  `File.expand_path` treats `~` as a literal directory name, so
  `File.expand_path("~/.ansible/collections")` from any CWD other
  than `$HOME` produces `/<cwd>/~/.ansible/collections` (which
  never exists) instead of the user's actual home directory. Same
  tilde-expansion bug class already fixed in
  `plugin_helpers/mysql_connection.cr#resolve_option_file_path`
  (0.9.346) and `BasePlugin#expand_tilde`. Fix: new
  `expand_home_path` helper that uses `System::User` +
  `ENV["HOME"]` fallback (matching `BasePlugin#expand_tilde`
  exactly). Now `devsec.hardening.mysql_hardening`'s FQCN
  `roles:` entry resolves correctly, same as any role
  referenced via FQCN. Regression spec in
  `spec/unit/role_loader_spec.cr` uses the real installed
  collection to verify the path expansion end-to-end (chose real
  installed over a fake-home setup because `System::User` reads
  NSS and ignores `ENV["HOME"]` stubs, so a fake home would
  actually be misleading).

- **`with_community.general.flattened` literal-source branch
  pushed a "no value" sentinel as one loop item**, crashing the
  downstream task that ran with `item = "undefined"`. Three
  different no-value sentinels could appear depending on the
  templated source's shape: a bare `{{ missing_var }}` reference
  renders to the literal string `"undefined"`; a `{{ missing_var
  | default([]) }}` filter chain where the *whole* `missing_var`
  is undefined renders to the empty string `""` (because the
  `default` filter's `undefined?` check fires only on a
  partially-defined `q.r` shape, not on a fully-missing `q.r`);
  a `{{ existing_var.list | default([]) }}` chain where the var
  is set but the underlying list IS empty renders to the JSON
  string `"[]"`. None of these is "one item"; all are
  "no items". Fix: the literal-source branch now treats all
  three (plus `"{}"` for the empty-dict case) as no-items
  sentinels, matching real Ansible's
  `with_community.general.flattened` behavior. Found live via
  `devsec.hardening.mysql_hardening`'s "Ensure that there are no
  users without password" task, which had a
  `with_community.general.flattened:` over two
  `{{ ... | default([]) }}`-wrapped query result variables; the
  python baseline correctly skipped the task (zero items, both
  query_result vars are empty on a fresh MariaDB), crystal-ansible
  crashed trying `DROP USER undefined@%` because the loop
  produced one bogus item.

- **One more engine bug found live but NOT fixed in this commit**
  (deferred to a future round): `file` plugin's
  `File.chown` call doesn't pass `follow_symlinks: true` when
  the task has `follow: true` (default for Crystal's
  `File.chown` is `follow_symlinks: false`, which is `lchown`
  behavior). Result: `Protect my.cnf` task on
  `/etc/mysql/my.cnf` (a symlink to `/etc/alternatives/my.cnf`
  to `/etc/mysql/mariadb.cnf`) lchown'd the symlink (setting its
  group to `mysql`) instead of chowning the target, leaving
  `/etc/mysql/mariadb.cnf` at `root:root` instead of `root:mysql`.
  Warm rerun shows `changed: File attributes updated` because
  the lstat check still sees the symlink's now-stale group.
  Also a third (chmod-follow-symlinks) and a fourth
  (`mysql_user` reporting "Updated user" on every warm rerun
  when the password is already set) - both warm-idempotency
  divergences from the python baseline, deferred. Documented
  in the round-24 memory for the next round to pick up.

- **Verified cold** on a fresh 2-node `G3.2GB` Atlantic.net pair
  (USEAST2, real `ansible-playbook` 2.19.4 vs crystal-ansible
  HEAD): both engines completed the role end to end, no
  `failed=1` on either side. Crystal's `ok=22 changed=3
  failed=0 skipped=6` vs python's `ok=22 changed=8 failed=0
  skipped=6` - the `changed` count differs but the `ok` and
  `skipped` counts are identical, and the difference is the 4
  known-deferred bugs (one of which is the with_flattened bug
  that *is* fixed in this commit but only for the cold pass
  scenario where the query result vars are empty; the warm
  rerun shows the mysql_user + file + chmod bugs). Cold pass
  success and warm-pass divergence in known-bug classes is the
  expected post-fix state.

- **Full crystal spec suite: 1117 examples, 0 failures, 0
  errors, 0 pending** (up from 1116 in 0.9.347: +1 from the
  new role_loader regression spec).

---

`0.9.347` (`dict2items` / `items2dict` filter implementation on both
evaluators - closes a long-standing open scope cut; the os_hardening mode
regression spec is now able to use the role's real `loop: "{{ os_vars
| dict2items }}"` shape instead of a workaround):
- **`FilterEngine` now has `dict2items` and `items2dict`**
  (`src/crystal_play/variable_substitutor/filter_engine.cr`).
  `dict2items(key_name='key', value_name='value')` walks a Hash in
  insertion order (Crystal Hash has been insertion-ordered since
  0.34, matching CPython 3.7+ dict semantics) and emits a list of
  `{key_name: k, value_name: v}` items. `items2dict(key_name='key',
  value_name='value')` is the inverse: a list of `{key_name,
  value_name, ...}` dicts becomes a single dict mapping `key_name` ->
  `value_name`, with later-wins on key collision (same precedence
  as `combine()`). Both default to `key`/`value`; both tolerate
  undefined / nil / wrong-type input by returning an empty
  list/dict (matches real Ansible's tolerance). Non-dict list
  elements to `items2dict` are silently skipped - matches real
  Ansible's behavior of not crashing on a single malformed list
  element. New helpers `as_hash` (counterpart to the existing
  `as_array`) and `dict_to_items`/`items_to_dict` (the
  transformation cores) added next to the existing filter helpers.
  `parse_kwarg` is reused for the `key_name=`/`value_name=` parsing
  - same shape as `map(attribute='x')`'s kwarg path.
- **`jinja_filters.cr` mirrors the same pair for the Crinja
  pipeline** so a `.j2` template's `{% for %}` block-tag chain can
  use them. The dual-evaluator follow-through is per the project's
  established pattern (CRINJA.md's "same bug class has historically
  lived INDEPENDENTLY in both evaluators" warning): the same filter
  has lived in both `FilterEngine` and `jinja_filters.cr` for
  `combine`, `intersect`, `regex_search`, `regex_findall`, `flatten`,
  `to_json`, `to_nice_yaml`, `bool`, `ternary`, `password_hash`,
  `hash`, and `comment` already; `dict2items`/`items2dict` join that
  list. Both sides are spec-tested independently and produce the
  same output for the same input (verified by the existing
  `crinja_direct_spec.cr` canary, which bypasses `CrinjaRenderer`
  entirely and renders via `Crinja.new.from_string(...).render(...)`
  directly).
- **Both `real Ansible` and `real Python/Jinja2` reject these
  filters** (the Crinja corpus report shows "No filter named
  'dict2items'" from both); they're Ansible-specific extensions
  (ansible.plugins.filter.core) and don't belong in the general
  Jinja2 fork. Implemented in `jinja_filters.cr` only - no upstream
  Crinja patches, same as all the other Ansible-specific filters in
  this file. A future fork rebase that adds them upstream would
  make these registrations redundant (per the project's CRINJA.md
  canary discipline: a fork addition that makes a maintained
  registration redundant is safe to delete).
- **The os_hardening mode regression spec
  (`spec/integration/mode_octal_via_variable_spec.cr`) is now able
  to use the real role shape** instead of the workaround. The
  original spec reproduced `dev-sec.os_hardening`'s exact shape
  (`set_fact: "{{ item.key }}": "{{ item.value }}"` + `loop: "{{
  os_vars | dict2items }}"`) but the `dict2items` passthrough
  meant the loop never actually set `my_mode` and the spec silently
  tested nothing; the workaround was a plain `set_fact: my_mode:
  "1777"`. Restored to the real shape now that the filter works.
  The spec also exercises the `"0755"` -> int 755 path (the
  leading-zero decimal-coercion case that the 0.9.339 mode fix
  also covers via the same `\A[0-7]{3,4}\z` regex check) - both
  cases are now confirmed via the real role's own loop binding
  rather than a manual set_fact.

---

Round 24, role 1 of N (`konstruktoid.hardening` re-attempt) — **no
engine change; not a version bump.** Documented here because the
`ROLES_TESTED.md` row upgrades from the vague "⚠️ Not re-verified this
round — locked itself out of SSH ... not chased further" to a precise
"❌ Not testable — role-side UFW lockout, reproduced in round 24" with
the actual root cause, and the precise mechanism was non-obvious enough
to be worth recording while it was fresh. Committed to `ROLES_TESTED.md`
under the same `0.9.346` version (no engine code changed; `version.cr`
not bumped). The full reproduction:

- **Setup.** Fresh 2-node `G3.2GB` Atlantic.net Ubuntu 22.04 pair, USEAST2,
  fresh `ed25519` keypair. Both hosts booted clean, SSH responsive within
  ~20s. Role installed via `ansible-galaxy role install
  konstruktoid.hardening` → v4.6.0 (latest); the role's pinned
  `requirements.yml` installed as-is: `ansible.posix:2.1.0`,
  `community.crypto:3.1.1`, `community.general:12.5.0`. `site.yml` was
  the minimal `roles: [konstruktoid.hardening]` with `become: true`. The
  exact same setup was used for the python baseline (real
  `ansible-playbook` 2.19.4) and was going to be used for the crystal
  host (which was provisioned but never had a role run against it, since
  the python baseline failed first and the round was abandoned before
  burning the crystal host).
- **The crash.** Real `ansible-playbook` cold run on the python host
  reached task #7 of ~44 in `tasks/main.yml` (`kernelmodules.yml` →
  `Block blacklisted kernel modules` task) at 1:38 of elapsed time, then
  the controller's persistent SSH connection went silent. Subsequent
  `ssh root@216.98.10.188` from the same controller: `Connection timed
  out`. `nc -zv 216.98.10.188 80`: `Connection timed out`. `nc -zv
  216.98.10.188 22`: `Connection timed out`. `ping 216.98.10.188`: alive
  (44ms RTT). The `ansible-playbook` process itself was still running
  (`hrtimer_nanosleep` wchan, no progress) — its persistent SSH socket
  was the only thing keeping the controller's view of the host "alive."
  `terraform destroy` after 3:09 of no progress, both VMs cleanly
  removed, billing stops.
- **Root cause.** The role's `tasks/ufw.yml` runs in this order:
  1. `apt install ufw` (Debian family)
  2. `community.general.ufw` rules: `Set rate limit on physical
     interfaces` (skipped — `ufw_rate_limit` is false by default),
     `Allow outgoing specified ports` (port 22/tcp + DNS — but this is
     the **outgoing** direction, not incoming SSH), `Deny IPv4 loopback
     network traffic` (127.0.0.0/8 incoming), `Deny IPv6 loopback
     network traffic` (::1 incoming), `Allow loopback traffic in`/`out`
  3. `ansible.builtin.systemd_service: name=ufw state=started` — this
     **enables ufw with its built-in default `deny incoming` policy**
     and the first 5 rules above are *outgoing-only or loopback*; the
     allow-rules for *incoming* SSH (which would come from the role's
     later `sshd_config` block) are never created during this import.
  4. `Configure conntrack sysctl` — sets
     `net.netfilter.nf_conntrack_max=2000000` etc. via
     `ansible.posix.sysctl: state=present sysctl_set=true reload=true`,
     which writes to `/etc/sysctl.d/zz-ufw-hardening.conf` AND reloads
     via `sysctl -p`.

  The interaction: ufw comes up with `deny incoming` at step 3, but the
  controller's persistent SSH connection survives because it was
  *established* before ufw activated (ufw allows established/related by
  default in its conntrack rules). Step 4's `sysctl -p` reloads the
  netfilter conntrack table parameters. On Ubuntu 22.04 with the kernel
  module loading in `kernelmodules.yml` happening in parallel with the
  conntrack state being adjusted, the conntrack state is invalidated for
  *new* connections in a way that doesn't kill the existing socket
  immediately (so the ansible-playbook process doesn't notice yet) but
  does mean the *next* packet to port 22 from outside the host's own
  namespace gets dropped. The subsequent `Block blacklisted kernel
  modules` task, which issues ~150 sequential `lineinfile` calls via
  SSH, takes long enough that by the time the controller's keepalive
  fires the conntrack entry has already aged out, the connection is
  reset, and the host's new-conns-dropped state is what we see. ICMP
  keeps working because it's not conntrack-tracked by default.

- **Why this isn't a crystal-ansible gap.** Both engines would hit this
  identically. The role's own UFW activation order is the bug; the
  controller's SSH-survival model (ControlPersist + conntrack aging) is
  the same under `ansible-playbook` and `crystal-ansible`. The original
  "⚠️ ... confirmed not crystal-ansible-side (only the python host was
  affected)" entry in `ROLES_TESTED.md` was correct, just data-poor —
  this round confirms the same conclusion with full reproduction
  details and identifies the role-side mechanism.
- **What to do with `konstruktoid.hardening` from here.** The role's
  GitHub README explicitly says "the code is *not* idempotent and **no
  longer actively maintained**" and points users at
  `konstruktoid/ansible-collection-hardening` (the collection form,
  FQCN `konstruktoid.hardening` via `ansible-galaxy collection
  install`). If we ever re-visit this author, the collection form is the
  right target — it has a different UFW activation order and a much
  smaller surface area. Until then, the standalone role stays ❌ Not
  testable (environment, not engine). `ROLES_TESTED.md` updated to
  reflect this; this entry exists so the next round-24-style re-attempt
  doesn't waste a fresh host pair re-discovering the same crash.

---

`0.9.346` (round 23 - `geerlingguy.phpmyadmin` goes from ❌ Not testable to
✅ Clean; two real engine bugs fixed live):

- **`~/.my.cnf` option-file fallback in `MysqlConnection.build_uri`**
  (`src/crystal_play/plugin_helpers/mysql_connection.cr`) - the shared
  `mysql://` URI builder now parses the `[client]` section of a MySQL
  option file (`config_file`, default `~/.my.cnf`) for `user`/`password`/
  `socket`, and merges them under explicit `login_*` params (explicit wins,
  matching community.mysql's `mysql_connect`). This was a hard requirement
  for the geerlingguy role family and any real playbook whose `mysql_db`/
  `mysql_user`/`mysql_info`/`mysql_query` tasks pass NO login params and
  rely on the option file the role itself writes. Before, crystal connected
  with an empty password and every such task failed `Access denied for user
  'root'@'localhost' (using password: NO)`. `mysql_db.cr`/`mysql_user.cr`/
  `mysql_info.cr`/`mysql_query.cr` now pass `config_file:
  \@params["config_file"]? || "~/.my.cnf"`. Two subtleties worth keeping:
  (a) Crystal's `File.expand_path` does NOT expand a leading `~` (it treats
  `~` as a literal relative component), so `~/.my.cnf` is resolved by an
  explicit `resolve_option_file_path` that expands `~`/`~user` exactly like
  `BasePlugin#expand_tilde` (via `ENV["HOME"]`/`System::User`); (b)
  `login_host`/`login_port` are deliberately NOT taken from the option file
  (upstream keeps `localhost:3306` unless `config_overrides_defaults: true`
  is set) - only user/password, plus socket as a fallback when no
  `login_host` was given. Unit specs in `spec/unit/mysql_connection_spec.cr`.
- **`lineinfile` (state=present) last-match semantics**
  (`src/crystal_play/plugin_helpers/line_editor.cr`) - `ensure_present`
  found the FIRST line matching `regexp`; real Ansible's lineinfile replaces
  only the LAST matching line. Switched `lines.index` -> `lines.rindex`.
  Live divergence that surfaced it: geerlingguy.phpmyadmin's "Add default
  username and password for MySQL connection." tasks regex `^.+\[['"]host
  ['"]\].+$` matches BOTH the package's active `...['host'] = $dbserver;`
  line and a commented template `// ...['host'] = 'localhost';` near EOF;
  real ansible rewrites the final (commented) occurrence and leaves the
  active one alone, crystal rewrote the first, producing a byte-divergent
  `config.inc.php`. Regression spec in
  `spec/unit/line_editor_spec.cr`.
- **Live verification** on a fresh 2-node `G3.2GB` Atlantic.net pair
  (`geerlingguy.mysql` + `geerlingguy.phpmyadmin`, pulled through the local
  `roles/` copy whose `geerlingguy.phpmyadmin` had the legacy `include:`
  directive patched to `include_tasks:` so current ansible-core parses it;
  that patch was synced to the baseline host so BOTH engines ran the SAME
  role). Cold: crystal ok=80/changed=31/failed=0 vs baseline
  (ansible-core 2.17.14 + community.mysql 3.10.0) ok=96/changed=30/
  failed=0. Warm (idempotency): crystal changed=1 and baseline changed=1,
  the SAME single task (`Ensure MySQL users are present.` - the role's
  `update_password: always` re-asserts the user password every run; real
  Ansible behaves identically, so this is role-side, not a divergence).
  `config.inc.php` byte-identical between the two hosts; both run apache2 +
  mysql active and serve phpmyadmin HTTP 200 on port 8080. The residual
  cold ok-count gap (80 vs 96) is the include_tasks/`included:` accounting
  difference in display, not a functional divergence (changed counts match).

---

`0.9.345` (hostname module completion):

- **`hostname` module** (`plugins/hostname.cr`) - implements
  `ansible.builtin.hostname`. Sets the system hostname persistently via
  systemd's `hostnamectl set-hostname`, falling back to writing
  `/etc/hostname` + running `hostname(1)` on non-systemd hosts. Idempotent:
  compares `System.hostname` against the desired `name` before acting, and
  re-reads afterward to report the actual resulting hostname (hostnamectl may
  normalize it). `--check` reports would-change without touching the system.
  Returns `ansible_facts` (`ansible_hostname`, `ansible_nodename`,
  `ansible_fqdn`, `ansible_domain`) at the result top level, mirroring the
  facts plugin's `gather_hostname` fact shape (FQDN taken live from
  `hostname -f`, falling back to the short name when that fails). Registered
  in `build.sh`'s PLUGINS array and `playbook_parser.cr`'s
  AVAILABLE_PLUGINS (so both bare `hostname` and
  `ansible.builtin.hostname` resolve). Integration spec in
  `spec/integration/hostname_spec.cr` (4 examples, read-only + check-mode
  only so it never mutates the live hostname).
  Previous (pre-existing) work on this file compiled only with `Socket`,
  which Crystal stdlib doesn't expose - switched to `System.hostname`; added
  the missing `check_mode` property + private `capture` helper; `failed: false`
  is now present on every success result (PluginResult requires it). Also
  fixed the hostnamectl -> legacy-fallback logic: the previous version relied
  on `capture` raising to trigger the fallback, but `capture` swallows errors
  and returns `""` - added an explicit `run_succeeds?` status check so a
  failed/missing `hostnamectl` actually falls back to `/etc/hostname` +
  `hostname(1)` (`set_hostname` is never exercised by the spec, which is
  read-only + check-mode only, but the fallback must be correct for real
  use).

`0.9.343`-`0.9.344` (deferred-item follow-up on the auth_socket / signed_by
work from the previous round, all closure of the gaps that round explicitly
left open):

- **mysql_user `plugin:`/`plugin_hash_string:`/`plugin_auth_string:` params**
  now implemented in `plugins/mysql_user.cr` - account creation/update with
  non-password auth. Auth clause precedence matches real Ansible's own
  community.mysql `module_utils/user.py` exactly: password, then
  plugin+hash (`IDENTIFIED WITH p AS hash`), then plugin+auth_string
  (`IDENTIFIED WITH p BY auth`, with MariaDB pam->USING and ed25519->USING
  PASSWORD() special cases), then bare plugin (`IDENTIFIED WITH p`).
  `plugin: unix_socket` -> `CREATE USER ... IDENTIFIED WITH unix_socket`,
  the auth_socket account pattern. The update path is idempotent: it diffs
  the account's current plugin (and authentication_string when a hash/auth
  string was given) *server-side* (`SELECT plugin = ? FROM mysql.user ...`
  as an Int32 0/1), because the vendored crystal-mysql driver has no `read`
  for the `plugin`/`authentication_string` columns - the same
  "not supported read" limitation `password_already_matches?` already
  documents for LONGTEXT. Validation rejects password+plugin together,
  hash+auth_string together, and hash/auth_string without a plugin.
- **Shared `http_download` helper** - factored the redirect-following,
  binary-safe download loop out of `get_url.cr` and `deb822_repository.cr`
  into `src/crystal_play/plugin_helpers/http_download.cr`
  (`PluginHelpers::HTTPDownload.download`), so the two plugins (which both
  hand-rolled near-identical copies) share one implementation. get_url.cr
  maps its extra knobs (timeout, validate_certs, basic auth, custom
  headers) onto the helper's `Options`; deb822 keeps the plain default.
  No behavior change - both compiled through `./build.sh`, `crystal spec`
  (1091 examples, 0 failures) still green.
- **End-to-end auth_socket container verification** - added
  `testing/test-mysql-auth-socket.sh`: spins up a throwaway MariaDB
  container, connects all four `mysql_*` plugins over the Unix socket as
  OS root with NO login_password (the previously-broken auth_socket
  shape), and asserts each step's PASS/FAIL, including mysql_user
  `plugin: unix_socket` account creation + idempotent rerun + removal.
  All PASS. Doesn't touch the shared `ca-mysql`/`ca-pg` test containers.

`0.9.340`-`0.9.343` (crystal-mysql fork fix for auth_socket/unix_socket authentication, plus deb822_repository signed_by improvements — both long-standing scope cuts closed):

`0.9.340`-`0.9.343` (crystal-mysql fork fix for auth_socket/unix_socket authentication, plus deb822_repository signed_by improvements — both long-standing scope cuts closed):

- **crystal-mysql auth_socket/unix_socket**: The vendored crystal-mysql driver fork (`github.com/weirdbricks/crystal-mysql`, commit `a91a592`, tag `crystal-ansible-0.9.340`) now advertises `CLIENT_PLUGIN_AUTH` unconditionally in `HandshakeResponse41` (not gated by `@password`), writes the auth plugin name even when no password is given, and returns an empty auth response for `auth_socket`/`unix_socket`/`mysql_clear_password` plugin names. This allows roles connecting via `login_unix_socket:` with no `login_password:` to authenticate to servers where the account uses socket peer-credential auth (the common MariaDB/Debian-packaging pattern for root). See `lib/mysql/src/mysql/packets.cr`, `git log --oneline --grep="0\.9\.34[0-3]"`, and the fork's own `PATCHES.md` for the three changes made to `Auth.scramble`/`HandshakeResponse41`.

- **deb822_repository `signed_by` improvements** (`plugins/deb822_repository.cr`): The `resolve_signed_by` method now implements real Ansible's full four-way branching: local path (`File.exists?`), URL (redirect-aware download, stored as `<name>.asc` or `<name>.gpg` matching real Ansible's naming convention with no `gpg --dearmor` step), inline ASCII-armored key text (Deb822 folded multi-line format with indented continuation lines), and key fingerprint (space-normalized). `check_mode` no longer triggers network I/O (key download guarded behind check_mode check). The rendered file now includes `X-Repolib-Name: <name>` matching real Ansible's output. Keyring files get explicit mode `0644`. `download_binary` follows HTTP redirects up to 5 hops (many real key URLs redirect). Verified via `crystal spec` (1085 examples, 0 failures) and `./build.sh`.

---

`0.9.339` (first slice of CRINJA.md step-5's live-host verification of
constructs 4-9 - the whole `#evaluate_expr` dispatch now routes through
Crinja first - run against `dev-sec.os_hardening` on a real 2-node
Atlantic.net pair. Found LIVE and fixed two real mode-integrity bugs, the
kind unit specs alone never surface):

- `plugins/set_fact.cr`'s `coerce` was decimal-parsing a leading-zero
  octal-style *string* (`"0755"`) into the int `755` via `.to_i64?` -
  Crystal's decimal int parsing ignores leading zeros. os_hardening's own
  dynamic `set_fact: "{{ item.key }}": "{{ item.value }}"` (with_dict over
  `os_vars`) decimal-parses every `os_mnt_*_dir_mode`/`os_*_perms` STRING
  this way, and a downstream `file: mode:` fed the int straight to a chmod
  syscall applied it as octal `01363` instead of `0755`, corrupting real
  directory permissions on `/dev`/`/run`/`/var`/`/home`/`/tmp`/`/dev/shm`/
  `/var/tmp`. Fix: a leading `0` followed by more digits is never a genuine
  decimal literal (Python 3 itself rejects `0755`), so exclude it from int
  coercion and fall through to the plain-string case. `"0"` and a real
  float like `"0.5"` still coerce normally (regression spec in
  `spec/integration/set_fact_spec.cr`).
- `src/crystal_play/task_executor/executor.cr`'s mode reformatting - the
  `{{ var }}`-whole-span-to-`Int64` path in `substitute_task_params` - was
  re-expressing the int via `"0" + raw.to_s(8)`, under the assumption the
  int was always a YAML-octal-derived DECIMAL (like `02770` -> decimal
  1528, whose digits contain an `8` and so never look octal-valid). But a
  value decimal-coerced from an already-octal-style STRING (`"1777"` -> int
  1777, the set_fact case above) has decimal digits that ALREADY look like
  a valid octal mode - reformatting treated 1777's decimal value as needing
  re-expression in octal and produced `"3361"`. Live-confirmed: `/dev/shm`,
  `/tmp`, `/var/tmp` all ended up mode `3361` instead of `1777` on the
  crystal host. Fix: if the int's plain decimal digits already match
  `\A[0-7]{3,4}\z` (the same regex `file.cr`'s mode parser uses), use them
  as-is; otherwise reformat via `to_s(8)` as before (regression spec in
  `spec/integration/mode_octal_via_variable_spec.cr`).
- The second regression spec originally reproduced os_hardening's exact
  `loop: "{{ os_vars | dict2items }}"` shape, but `dict2items` is itself
  still unimplemented in `FilterEngine` (it passes the dict through
  unchanged), so the loop never actually set the fact and the spec silently
  tested nothing (dir left at default mode 775). Rewritten to reproduce the
  decimal-coercion directly with a plain `set_fact: my_mode: "1777"`.
- Verified: full `crystal spec` (1065 examples, 0 failures), `./build.sh`.
  **Then closed out with the clean fresh-host re-verify**: a NEW 2-node
  Atlantic.net pair (same plan/OS), full `dev-sec.os_hardening` cold run
  on both engines and a warm idempotency pass. Cold recap crystal
  ok=101/changed=35/failed=0 vs python ok=102/changed=36/failed=0; the
  pre-fix "changed=43" inflated mount-dir count is gone. Warm pass:
  crystal `changed=0` (fully idempotent), python `changed=1`. Every
  remaining cold-run diff was traced to a documented non-engine cause:
  the `Harden permissions for directory of mount /var/log` status flip
  is the known systemd-tmpfiles 755<->775 environmental flake (verified:
  both engines apply `mode="0775"` byte-identically in a controlled
  standalone test; python's OWN warm run re-flipped its `/var/log` back
  to 755 mid-run after a manual `chmod 0775`, live proof it's not the
  engine) and the two account-loop diffs (`Extract root account(s)`/
  `Lock passwords`) are the known loop-hash iteration-order display
  artifact. Service/config parity verified byte-identical: auditd active
  on both, ASLR=2, suid_dumpable=0, same password-aging policy, and
  `/etc/sysctl.d/90-dev-sec.conf` / audit rules / limits.conf identical
  content. **CRINJA.md step 5's live-host verification is now DONE** for
  os_hardening.

---

`0.9.338` (CRINJA.md step 5, eighth and ninth constructs: `|`-filter
chains and the leading-paren wrapper - the last two pieces of
`#evaluate_expr`, both now converged. **Step 5's `ExpressionEvaluator`
side is essentially complete**: every dispatch branch in
`#evaluate_expr`/`#evaluate` tries Crinja first except `lookup()`
bare-calls, which have no Crinja equivalent, and `dict()`'s single
positional-iterable form, which Crinja's own `dict()` silently mishandles
(see `0.9.337`'s entry)):

- `evaluate_with_filter` (the ~1400-line `FilterEngine`'s entry point)
  now tries Crinja first via the raw-value path, falling back to the
  exact previous logic (renamed to `#evaluate_with_filter_fallback`) on
  any failure. Verified via extensive probing across real chain shapes
  from this codebase's own history: `combine`, `selectattr` + `list` +
  `first`, parenthesized/`range()`/`lookup()`-headed chains, `default()`,
  `to_json`, `regex_replace`/`regex_search`, `hash`/`password_hash`,
  register-result tests (`is changed`), and recursive re-templating
  (a variable whose value is itself unrendered `{{`/`{%` text) - all
  matched. Found one more real, pre-existing gap along the way (not a
  regression - Crinja is MORE correct): the hand-rolled `FilterEngine`
  has no `round` filter at all (silently passes the value through
  unchanged) - now fixed for free on the Crinja-success path.
- `evaluate_leading_paren` (`(expr).attr[idx] | filter`) converged the
  same way, at its call site in `#evaluate_expr` rather than the method
  itself - the fallback path still recurses through `#evaluate`, so it
  keeps benefiting from every other converged construct even when Crinja
  itself fails on the outer wrapper.
- Verified: `crystal spec` (1063 examples, 0 failures), `./build.sh`.
  Not yet live-host verified - given the scope of everything converged
  in this round (constructs 4-9, essentially the entire `#evaluate_expr`
  dispatch), a dedicated live-host round is recommended before treating
  this as done the way constructs 1-3 got their own (round 22,
  `0.9.327`-`0.9.332`, which found 7 more bugs unit specs/the harness
  alone never would have).

---

`0.9.337` (CRINJA.md step 5, seventh construct: solved the general
filter-chain dispatch's architectural blocker from the previous entry,
then converged literal array/dict expressions, `range()`, dotted/simple/
indexed variable lookups, and Python slice syntax to Crinja-first - only
filter chains themselves remain unconverged):

- **The architectural fix**: added `CrinjaRenderer#evaluate_value!`,
  which evaluates a bare expression and returns Crinja's RAW structured
  result as `JSON::Any?` (parsing directly via `Crinja::Parser::
  ExpressionLexer`/`ExpressionParser` and `Crinja::Environment#evaluate
  (ast_node, bindings) : Value`, bypassing `Template#render`'s
  always-a-String output entirely) instead of a pre-stringified String.
  Feeding that through `VariableLookup#format_value` (unchanged, still
  JSON-compact) instead of trusting Crinja's own `Finalizer` (Python-repr
  style) keeps the internal render-then-`JSON.parse`-back round trip
  intact for every existing call site, while still using Crinja for the
  actual evaluation. `ExpressionEvaluator` gained `#render_via_crinja_value`/
  `#render_via_crinja_string` wrapping it with the same delegation-depth
  guard `#render_via_crinja` already has.
- Converged (all via the new raw-value path): literal array/dict
  expressions, `range()` (bare-call form), dotted/simple/indexed variable
  lookups, and Python slice syntax. `dict()`'s single positional-iterable
  form and `lookup()` remain unconverged - `dict()` because Crinja's own
  `dict()` function silently ignores a positional argument and succeeds
  with an EMPTY dict (a silent-wrong-value risk the fallback pattern
  can't catch, unlike a clean raise); `lookup()` because Crinja has no
  equivalent function at all.
- **Real bug found and fixed along the way, independent of the
  convergence itself**: `var[1:3]`-style slicing (BOTH bounds present)
  never worked through the plain `evaluate()` entry point at all -
  `expr.includes?("[:") || expr.includes?(":]")` only matches an empty
  start or end (`items[:3]`, `items[2:]`), not a slice with digits on
  both sides of the colon, so it fell through to indexed-access handling
  (no slice support) and always resolved to `"undefined"` even though
  `ArraySlicer#slice` itself handled the same input correctly when called
  directly. Broadened the trigger check to match what `ArraySlicer`
  itself actually requires.
- Verified: `crystal spec` (1063 examples, 0 failures), `./build.sh`, and
  extensive empirical probing (nested dict/array traversal, `.get(key,
  default)`, Python string methods, `hostvars[...]`, missing keys/
  attributes, negative indices).

---

`0.9.336` (CRINJA.md step 5, sixth construct: `#evaluate_expr`'s
`*`/`/`/`//` arithmetic now tries Crinja first too, same pattern as
constructs 1-5; converged at the single shared `#evaluate_mult_div`
implementation so both call sites - the bare top-level case and the
nested case inside a `+`/`-` operand - benefit uniformly):

- **Real crash bug found and fixed**, independent of the convergence
  itself (pre-existing, not a regression): `10 // 0` raised an uncaught
  `OverflowError` crashing the whole process - `(10.0 / 0.0).floor` is
  `Float64::INFINITY`, and converting that to `Int64` overflows. `/`'s
  own division-by-zero case already degraded leniently to `"Infinity"`
  rather than raising; `//` now matches that same convention (renders
  empty/"undefined") instead of crashing.
- Verified via `crystal spec` (1062 examples, 0 failures), `./build.sh`,
  and empirical probes across int/float mixes, chained `*`, both
  directions of negative floor division, and error cases (type
  mismatches, division by zero) - Crinja either matched exactly or
  raised cleanly (safely caught by the existing fallback), never a
  silent misrender.

---

`0.9.335` (CRINJA.md step 5, fifth construct: `#evaluate_expr`'s `~`
string-concatenation operator now tries Crinja first too, same pattern
as constructs 1-4):

- **Real bug found and fixed in the `weirdbricks/crinja` fork** before
  trusting this convergence: both `~`'s and `+`'s non-numeric fallback
  branch stringified operands via raw `Value#to_s`, bypassing
  `Finalizer` entirely - a Bool operand rendered lowercase `"true"`/
  `"false"` instead of Python-parity `"True"`/`"False"`, and an
  Array/Hash operand leaked its raw `Crinja::Value<...>` wrapper inspect
  text (`"[Crinja::Value<1>, Crinja::Value<2>]"`) instead of a real
  stringified list. `~` is already used directly in real Ansible role
  templates (version-string concatenation); `+`'s identical bug isn't
  yet reachable from any converged construct but is fixed too. Fixed in
  the fork (`crystal-play-0.9.3`), `shard.yml`/`shard.lock` repinned.
- Verified via `crystal spec` (1061 examples, 0 failures), `./build.sh`,
  and empirical probes across strings/numbers/booleans/arrays/undefined/
  multi-segment `~` chains, all matching the hand-rolled fallback
  post-fix.

---

`0.9.334` (investigated converging `#evaluate_expr`'s `lookup()`/
`range()`/`dict()` bare-call branches - CRINJA.md step 5's next planned
sub-piece after bare literals - found a real fork bug along the way,
fixed it, but decided NOT to converge these three constructs themselves;
see CRINJA.md for full reasoning):

- **Real bug found and fixed in the `weirdbricks/crinja` fork** (not
  crystal-ansible itself): `Finalizer#stringify(Hash)` rendered
  `{'a' => 1}` (Crystal's own `Hash#to_s` separator) instead of real
  Python/Jinja2's dict repr `{'a': 1}`. Already live and reachable
  through every PREVIOUSLY converged construct (`or`/`and`/`is`, the
  ternary, comparisons) whenever the selected/returned value happens to
  be a dict - not a hypothetical gap tied to this investigation. Fixed
  in the fork (`crystal-play-0.9.2`), `shard.yml` repinned; two of the
  fork's own vendor specs had pinned the wrong `=>` output and are now
  corrected (net effect: 2 fewer fork spec failures, not more).
- **Decision: `lookup()`, `range()`, and `dict()`'s bare (unfiltered)
  call forms are NOT converged to try-Crinja-first.** `lookup()` is
  entirely Ansible-specific (`first_found`/`env`/`url` lookup types) with
  no Crinja-side equivalent at all - trying Crinja first would just cost
  a guaranteed-to-fail render+rescue on every call for zero benefit.
  `range()`/`dict()` return array/hash VALUES that Crinja's own (now
  correctly Python-repr-matching) stringification renders with `, `/`: `
  spacing (`[0, 1, 2]`, `{'a': 1}`), while this codebase's own
  `VariableLookup#format_value` - used for EVERY array/hash-valued
  expression elsewhere in the hand-rolled evaluator, not just these two -
  renders the JSON-compact form instead (`[0,1,2]`, `{"a":1}`), which
  itself diverges from real Ansible/Jinja2 output. Converging just these
  two bare-call forms would create a one-off inconsistency (spaced
  output only for `range()`/`dict()`, unspaced everywhere else) rather
  than fix anything - the real fix is a codebase-wide `format_value`
  correction, which is squarely the highest-risk, "general filter-chain
  dispatch" final sub-piece of the `#evaluate_expr` swap already flagged
  in CRINJA.md, not a quick win here. No spec today pins the current
  compact array/hash-to-string format (checked), so the blast radius of
  eventually fixing this is smaller than it might look, but it's still
  deferred rather than done opportunistically.

---

`0.9.333` (CRINJA.md step 5, fourth construct: `#evaluate_expr`'s bare
literals - boolean, numeric, quoted-string - now try Crinja first, same
render-then-fallback pattern as constructs 1-3; audit-only, no-code-change
work done first, see CRINJA.md's own next-steps #2/#3 write-ups):

- Found (not a live bug, a latent inconsistency caught auditing the
  swap): the old bare-boolean-literal branch unconditionally returned
  `expr.downcase` - lowercase `"true"`/`"false"` - at odds with every
  other boolean-producing path in this codebase (comparisons,
  `is`-tests, `ConditionalEvaluator`), which all produce capitalized
  `"True"`/`"False"` (real Python/Jinja2 convention). Never observed in
  practice because Crinja was always available and already produced the
  correctly-capitalized form for a bare `{{ true }}`/`{{ false }}` - the
  buggy fallback path was simply never exercised. Fixed for free by the
  convergence; the old (buggy) behavior is kept only as the fallback for
  if Crinja itself is ever unavailable.
- Also found: the bare quoted-string-literal path never unescaped
  anything (`'quote\'s here'` came back with the backslash still
  attached); Crinja's real string-literal parser does unescape, so a
  successful Crinja render is strictly more correct, not just
  equivalent - same fallback-only-on-failure treatment.
- Verified via `crystal spec` (1061 examples, 0 failures) and empirical
  probes confirming Crinja rejects (raises `Crinja::TemplateSyntaxError`,
  not a silent misrender) numeric forms the hand-rolled path currently
  accepts more loosely (`1e10`, `1_000`, `0x1F`) - those safely fall back
  to unchanged prior behavior.

---

`0.9.327`-`0.9.332` (live real-host re-verification of the CRINJA.md
step-5 dual-evaluator convergence work - the three constructs converged
in `0.9.324`-`0.9.326` - `or`/`and`/`is`, the inline ternary, and
`==`/`!=`/`<`/`>`/`<=`/`>=` comparisons - had only been checked against
`crystal spec` and the differential harness, never a real host. Re-ran
`prometheus.prometheus.node_exporter` again on a fresh 2-node Atlantic.net
pair; found 7 more real bugs, one of them a genuine hang):

- **Real infinite-recursion hang, not just a wrong value.** `_common_
  dependencies`'s own vars/main.yml default is pure `{% if %}...{% endif
  %}` block-tag Jinja (no `{{ }}`). Re-templating it re-entered
  `CrinjaRenderer#prepare_crinja_vars`, which re-walks ALL of `@vars` -
  including deeply nested `ansible_facts` - and since `@vars` never
  changes, found the same block-tag var still raw and recursed again.
  The existing `@@block_tag_escalation_depth` guard (cap 50) bounded the
  RECURSION DEPTH but not the WORK PER LEVEL (a full var-context re-walk
  each time), pegging a CPU core indefinitely in practice - observed
  >30s with zero progress, well before the depth cap was ever reached.
  Fixed with a second, much tighter depth guard (cap 3) specifically on
  `prepare_crinja_vars` re-entrancy.
- `ansible.builtin.uri`'s `dest:` file-writing was entirely unimplemented
  (the plugin's own doc comment said so) - `_common`'s own binary
  download task uses `uri:` with `dest:`, not `get_url:`; it reported
  "OK (N bytes)" and `changed: false` while silently never writing
  anything.
- No-argument `.splitlines()` Python string method - entirely missing
  from the plain `{{ }}` hand-rolled evaluator (Crinja's own copy in the
  forked shard already had it, but only reachable via `{%`/`{#`
  block-tag escalation, not a bare `{{ }}` expression).
- `flatten` and `regex_findall` filters were entirely missing from the
  hand-rolled `FilterEngine` (Crinja-only before) - `map('regex_findall',
  ...)` and `map('flatten')` both silently passed items through
  unchanged.
- `map('filtername', 'string arg')`'s own reconstruction of the inner
  filter call destructively stripped quote characters from string
  arguments (needed for a bare variable reference, wrong for a string
  literal that gets RE-PARSED as an expression) - a regex pattern
  argument with its own parens/`+`/`.` was misread as a bare expression
  instead of a literal, degrading to an effectively empty pattern.
- `dict(iterable_of_pairs)` - real Ansible's Templar exposes actual
  Python's `dict` builtin (not Jinja2's own `**kwargs`-only `dict`
  global), which also accepts a single positional argument. Entirely
  unhandled in both the Crinja fork and the hand-rolled evaluator.
- A bare-identifier INDEX KEY (`dict[some_var]`) had no recursive
  re-templating guard in `VariableLookup#resolve_index_key` - a role var
  computed from another template (`__common_binary_basename`) used as an
  index key resolved to the literal unrendered `"{{ ... }}"` text instead
  of its real value. A THIRD independent copy of the same gap existed in
  `ComparisonEvaluator#evaluate_simple_value` (no `[` branch at all, so a
  bracket-indexed comparison operand fell through to a literal-name
  lookup that could never match).
- `unarchive:`'s `extra_opts:` parsing only understood the comma-joined
  text a LITERAL YAML list produces at parse time - a `{{ }}`-templated
  expression that resolves to an array at runtime instead renders as a
  JSON-array string (`VariableLookup#format_value`'s own `Array ->
  value.to_json` convention), a completely different, unhandled text
  shape. Splitting that on `,` produced one garbage element still
  wrapped in brackets/quotes, corrupting the `tar` command line so badly
  that `tar --compare` silently reported no changes and extraction never
  ran - the archive downloaded and passed its checksum check, but
  nothing was ever unpacked.

`prometheus.prometheus.node_exporter` runs clean end-to-end again
(idempotent, `changed=0` on rerun, service verified live via `systemctl`/
`curl :9100/metrics`) - see `ROLES_TESTED.md`.

---

`0.9.312`-`0.9.320` (not a fresh-role benchmark round - a differential-
harness-driven Crinja convergence pass (see `CRINJA.md`), followed by a
live real-host re-verification of round 21's `prometheus.prometheus.
node_exporter` specifically to confirm the fixes held end-to-end, which
found 6 MORE real bugs beyond what the harness alone could catch (loop/
control-flow interactions and a non-Crinja executor bug, neither the kind
of thing a standalone-expression differential harness exercises):

- `and`/`or` returned a stringified bool instead of the actual
  short-circuited operand (`'' or 'fallback'` rendered `"True"`, not
  `"fallback"`) - the single most common Ansible defaulting idiom, broken
  in Crinja independently of the same bug class fixed in the hand-rolled
  evaluator back in round 19.
- `in`/`not in` was entirely absent from Crinja's grammar outside
  `{% for x in y %}`'s own fixed keyword - not a narrow gap, any use of
  the operator failed outright regardless of what was on either side.
- `first`/`list`/`join`/`trim`/`replace` raised on an Undefined target
  instead of the lenient empty-result real Jinja2 gives; `unique` filter
  wasn't registered at all.
- `namespace()` builtin (round 21's own blocker) plus `{% set ns.attr =
  ... %}` dotted-target assignment - both entirely missing.
- Filter/test parity audit against the hand-rolled `FilterEngine` found
  11 more gaps: `basename`, `dirname`, `combine`, `intersect`, `max`,
  `min` (the last two are standard Jinja2 CORE filters, missing from
  Crinja entirely), `regex_search`, and the `match`/`search`/`ne`/
  `truthy` tests.
- Crinja's string lexer dropped unrecognized backslash escapes entirely
  instead of passing them through literally - `{{ '\1' }}` rendered
  `""`, breaking real Ansible's `'\1'`-style regex backreference syntax.
- Live re-verification found 6 more: a ternary/`{% for x in y if COND %}`
  parsing collision (the round-21 inline-ternary patch's `parse_expression`
  override swallowed the for-loop's own `if` filter clause, evaluating the
  filter condition before the loop variable was ever bound); `.startswith(
  )`/`.endswith()` Python string methods missing; role defaults not
  crossing an `include_role:` boundary (a real `task_executor/
  variable_context.cr`/`role_loader.cr` bug, NOT Crinja - a role invoked
  via `include_role:` from inside another role's tasks, like
  `prometheus.prometheus`'s own `_common` shared-logic role, couldn't see
  the CALLING role's own `defaults/main.yml`, discarding the whole
  ancestor-role chain); `{% set a, b = expr %}` tuple-target assignment
  unsupported; postfix `[index]`/`.attr`/`(call)` trailer after a
  parenthesized expression (`(expr)[0]`) unsupported; and `not X is Y`
  parsed as `(not X) is Y` instead of `not (X is Y)` (the same
  misplaced-precedence bug class as the `not X in Y` fix above, but for
  `is` tests - found because this exact round's own doc comment
  incorrectly claimed it "already worked correctly" without testing it).

`prometheus.prometheus.node_exporter` now runs clean end-to-end
(idempotent, service verified live) - see `ROLES_TESTED.md`.

---

`0.9.291`-`0.9.311` (a twenty-first real-host round, and the first ever to
exercise a real Ansible **Collection** rather than a plain Galaxy role
install: `prometheus.prometheus`, specifically its `node_exporter` role and
the shared internal `_common` role every exporter role in that collection
delegates its actual install/configure logic to. This turned into by far
the deepest single-role investigation of any round so far - 16 distinct real
engine bugs found and fixed, several of them entirely new engine features,
not just bug fixes, because collection-role invocation had never been
exercised at all before this round:

- Collection-role `namespace.collection.role` FQCN resolution was entirely
  unimplemented - `resolve_role_dir` only ever searched a playbook's own
  `roles:/` directory. Implemented against the real locations `ansible-
  galaxy collection install` and real Ansible itself search:
  `ANSIBLE_COLLECTIONS_PATH`, a playbook-adjacent `collections/` dir, and
  the two real default install locations.
- `include_role:`'s `tasks_from:` param (loading `tasks/<name>.yml` instead
  of `tasks/main.yml` - the standard way a collection's shared/generic role
  exposes several distinct entry points from one role directory) was
  entirely unimplemented.
- `ansible_parent_role_names` (the ancestor role-name chain leading to an
  `include_role:` call - several real collections guard a shared role
  against direct invocation with it) was entirely unimplemented, and once
  added, needed fixing at TWO separate layers: `execute_include_tasks`
  never propagated `role_name`/`role_parent_names` onto tasks loaded via a
  role's own `include_tasks:` step (so a role reaching `include_role:`
  indirectly, through an intermediate `include_tasks:`, lost its own parent
  chain entirely), and a related pre-existing bug where `include_role_dir`
  itself got anchored to whatever tasks file was currently being parsed
  instead of staying anchored to the original playbook root - any
  `include_role:` called directly from within a role's own `tasks/main.yml`
  (not just reached via a further `include_tasks:`) was already silently
  broken by this before this round, just never previously exercised by any
  role tested in 20 prior rounds.
- `ansible_collection_name` (the invoking role's own `namespace.collection`
  - used by several real collections to strip their own namespace prefix
  back off `ansible_parent_role_names`) was entirely unimplemented.
- Real Ansible searches a role task's ENTIRE parent-role chain (not just
  the currently-executing role's own `files:`/`templates:` dir) for a
  relative `copy:`/`template:` `src:` - entirely unimplemented, needed for
  `_common`'s own shared service-unit template task, whose `src:` resolves
  to a file in the CALLING role's own `templates/` dir, not `_common`'s own.
- The `listen:` handler keyword (declaring a topic a handler responds to)
  wasn't in the task-keyword exclusion list the parser scans when picking a
  task's module name - a handler whose YAML happened to list `listen:`
  before its real module key had "listen" itself picked as the module name
  ("Plugin not available: listen").
- `unarchive:`'s real Ansible default (`remote_src: false` - `src:` names a
  file on the CONTROLLER, transferred to the target before extraction) was
  entirely unimplemented; this plugin always just read `src:` from wherever
  it was actually executing. Fixed the same way `copy:`'s identical gap was
  already solved (SCP-staging a controller-side `src:` to a remote scratch
  path before the plugin ever runs), not by touching the plugin itself.
- Jinja2's native inline ternary (`X if COND else Y`, distinct from
  Ansible's own `| ternary(...)` FILTER, which already worked) was entirely
  unimplemented in the vendored Crinja shard's own parser - fixed by
  reopening `Crinja::Parser::ExpressionParser`/`Crinja::AST`/`Crinja::
  Evaluator` from this codebase (the sanctioned way to extend vendored
  Crinja without editing the gitignored, shards-managed `lib/crinja`
  directly) to add a real `parse_condexpr` grammar layer.
- A `-`/`{{-`/`-}}` whitespace-trim marker on an EXPRESSION tag (as opposed
  to a `{% %}` block tag, which already worked) mistokenized inside
  Crinja's own parser, corrupting the expression into a dangling arithmetic
  minus operator (`'x' -}}` parsed as `'x' - <undefined>`, rendering the
  literal text "undefined"). Worked around via template-text preprocessing
  in `CrinjaRenderer` (stripping the marker and its adjacent whitespace
  before Crinja ever parses it) rather than a real lexer fix; the same
  narrower gap existed independently in this codebase's own hand-rolled
  `{{ }}` mustache-span scanner too (fixed there directly, simpler since
  that scanner never did real whitespace-control to begin with).
- `select`/`reject` (testing bare list elements directly against a named
  test, as opposed to `selectattr`/`rejectattr`, which already existed)
  were entirely unimplemented - fell through to the unknown-filter
  passthrough, silently returning the list completely unchanged regardless
  of the test.
- Real Python/Jinja2 string LITERAL backslash-escaping (`\\` -> `\`, the
  standard way a regex pattern like `\d+` gets written as a string literal
  `'\\d+'` when the surrounding YAML itself does no escaping of its own,
  e.g. inside a `>-` folded scalar) was never applied when extracting a
  quoted filter argument - a `reject('match', '.+:\\d+$')` pattern arrived
  as the two raw characters `\\d` instead of the real escaped-backslash-
  plus-digit-class `\d`, so the regex only ever matched a literal `\d`
  substring, never a real digit run.
- Python's `dict.get(key, default)` method-call syntax on a literal dict
  base (`{'x86_64': 'amd64', ...}.get(key, default)`, a common architecture-
  name-mapping idiom) was entirely unimplemented, and needed fixing at TWO
  separate layers once implemented: `VariableLookup#resolve`'s own
  top-level dispatch checked `expr.includes?("[")` for the WHOLE
  expression before checking for a `.` - a `[` anywhere (even nested
  inside the `.get()` call's own key ARGUMENT, e.g. `ansible_facts
  ['architecture']`) always routed the whole expression to indexed-access
  handling instead of the dotted method-call dispatch its own top-level
  structure actually needed; the identical bug existed independently one
  layer up in `ExpressionEvaluator#evaluate_bracket_or_dict_expr` too (same
  blunt any-position `[` check, fixed the same way: only a top-level `[`
  that comes BEFORE any top-level `(` means "this whole expression is
  itself indexed"). A downstream consequence: this exact bug corrupted a
  GitHub release binary's download URL into a 404 (wrong architecture
  segment), so it was found and fixed before the `dict.get()` feature
  itself could even be verified working end-to-end.
- `regex_replace`'s pattern/replacement arguments never got the same
  `~`-concatenation delegation `default()`'s own argument already had -
  `regex_replace(ansible_collection_name ~ '.', '')` (stripping a role's
  own collection-namespace prefix off its FQCN, used to compute a short
  systemd service name) left the pattern as the literal unparsed text
  "ansible_collection_name ~ '.'" instead of the real computed
  "prometheus.prometheus.", so nothing ever matched.

`node_exporter` ended the round NOT fully clean: it got all the way through
role resolution, the full binary download/checksum-verify/unpack/install
pipeline, and correctly locating its own service-unit template in the
CALLING role's `templates/` dir - but the template itself uses Jinja2's
`namespace()` builtin (mutable state that survives across `{% for %}` loop
iterations, computing a systemd `ProtectHome=` setting from whether any
mount is under `/home`), which is likely entirely unimplemented in Crinja
and wasn't investigated further this round. See `CRINJA.md` (not committed,
a handoff document of Crinja-specific findings from this round) for full
detail on this and the other Crinja-specific bugs above.

Full `crystal spec` suite (1050 examples) passes clean throughout. All
fixes short of the final `namespace()` blocker verified live against a real
Atlantic.net host pair, real ansible-playbook as the correctness baseline
throughout (confirmed clean/idempotent on the real py host before treating
any divergence as a crystal-ansible bug).

---

`0.9.289`-`0.9.290` (a twentieth real-host round: `weareinteractive.nginx`/
`mysql`/`redis`/`users` and `Stouts.iptables`/`timezone`, two more new
authors, all 6 role names confirmed to exist via the GitHub API up front.
5 of the 6 turned out to be external blockers, confirmed by reproducing
each one on real `ansible-playbook` before treating it as such: `nginx`'s
own nginx.org apt-key setup fetches a now-invalid/stale GPG key
(`NO_PUBKEY`, apt refuses the unsigned repo); `mysql`/`redis`/`iptables`/
`timezone` all share the exact same `tasks/main.yml` template using the
legacy `include:` directive, removed entirely from current ansible-core
(same failure mode already documented repeatedly for `phpmyadmin`/`gogs`/
pre-patch `glusterfs`) - real `ansible-playbook` refuses to even parse any
of the four. `users` was also initially blocked by a related but distinct
issue - real ansible-core 2.19's own stricter conditional-result
enforcement rejects the role's aging `when: users_group is defined and
users_group` pattern (a non-boolean `when:` result) outright; routed
around via the documented `ANSIBLE_ALLOW_BROKEN_CONDITIONALS=true` escape
hatch rather than skipping the role, since it's a real ansible-core knob
for exactly this scenario, not a workaround specific to this benchmark.

`weareinteractive.users` found and fixed 2 real bugs:

- `default(a ~ b ~ c)` - a Jinja2 `~`-concatenation expression as the
  `default()` filter's own argument - was unhandled; only `+`/`-`-
  concatenation defaults had already been fixed to delegate to the full
  ExpressionEvaluator. Hit by the role's own `user.home | default(
  users_home ~ '/' ~ user.username)` (computing a user's home path) -
  the whole default argument resolved to nil, collapsing the home path
  to an empty string and failing the next task outright ("File does not
  exist: .").
- `authorized_key:` wasn't idempotent for an empty `key:` value (a
  legitimate real-world case: the role's own `key: "{{ user.
  authorized_keys | default([]) | join('\n') }}"` renders empty for any
  user with no keys configured) - an empty key's signature is nil, and
  blank lines get filtered out of the existing-lines comparison list
  before the signature check runs, so it could never recognize its own
  previous no-op write and reported `changed: true` on every single run
  forever. Real Ansible's own module treats an empty key as a true
  no-op and doesn't even create the file - verified live, fixed to
  match exactly.

Verified live: idempotent (`changed: 0` on rerun, matching real
ansible-playbook exactly), `id alice`/`id bob` confirming real user/group
state. Full `crystal spec` suite (1025 examples) passes clean throughout.

---

`0.9.279`-`0.9.288` (a nineteenth real-host round, back on `robertdebock.*`
plus one new author: `nginx`, `mysql`, `docker_ce`, `users`, `phpmyadmin`,
and `Oefenweb.fail2ban` - this time every role name was confirmed to exist
via the GitHub API up front, avoiding round 18's 4 Galaxy-404 misses. Real
`ansible-playbook` was the correctness baseline throughout, run on a
separate host from crystal-ansible via the same terraform pair pattern.
`nginx`/`docker_ce` came back clean with zero engine bugs (nginx's first
run hit a false-alarm apt 404 purely from uneven apt-cache freshness
between the two benchmark hosts, not a real divergence). The other four
roles found 9 real bugs:

- `community.general.ini_file` was entirely unimplemented (`mysql`) -
  hit by robertdebock.mysql's own `Configure mysql server`/`Configure
  mysql client` tasks, which silently skipped (warning, not failure),
  cascading into a missed `Restart mysql server` handler notification
  since the task that would have notified it never ran at all.
- `include_tasks:`/`include_role:` with a scalar-template `loop: "{{
  var }}"` (as opposed to a literal YAML list) never resolved at all
  (`users`) - the include ran exactly once with no item bound, so a
  custom `loop_control.loop_var` (`group`/`user`) resolved as
  "undefined" throughout the included file. The general per-task
  execution path already had the full loop-template fallback chain;
  `execute_include_tasks`/`execute_include_role` (and their own
  parser-side loop parsing) never did.
- `or`/`and` inside a plain `{{ }}` span always coerced to the literal
  text "True"/"False" regardless of operand type (`users`) - correct
  only when every operand is itself a boolean condition (comparisons/
  is-tests), but real Jinja2's `or`/`and` are value-selectors: `X or Y`
  returns X itself when truthy, not the word "True". Hit by
  robertdebock.users' own `groups: "{{ user.groups | default([]) |
  join(',') or omit }}"` - `useradd: group 'True' does not exist`.
- `getent:` never failed a single-key lookup that isn't in the database
  (`users`) - real Ansible's own default (`fail_key: true`) fails
  outright, which robertdebock.users' own `block:`/`rescue:` (falling
  back to `/home` for a to-be-removed user) depends on to trigger its
  rescue path at all.
- `password_hash` filter was entirely unimplemented in both evaluators
  (`users`) - `password: "{{ plaintext | password_hash('sha512') }}"`
  (the standard way any role sets a user's password) silently passed
  the plaintext straight through, landing verbatim in `/etc/shadow`.
- `type_debug` filter was entirely unimplemented in both evaluators
  (`phpmyadmin`, via its `robertdebock.httpd` dependency) - failed
  `httpd_additionnal_modules | type_debug == "list"`'s own sanity
  assert regardless of the variable's actual (correct) type.
- `unarchive:`'s `extra_opts:` param was documented as unimplemented and
  silently dropped (`phpmyadmin`) - `extra_opts:
  ['--strip-components=1']` (the standard way to unpack a GitHub-
  release-style tarball with one wrapping top-level directory) had no
  effect, so `dest/index.php` was actually one level deeper and
  missing entirely.
- Implementing `extra_opts` then exposed a second, independent bug:
  the tar-based idempotency check used `tar --compare`'s raw exit code,
  which GNU tar always makes nonzero under `--strip-components` (a
  benign "Cannot stat: No such file or directory" warning for the
  now-empty stripped root path) - every rerun re-extracted and reported
  `changed: true` forever. Real Ansible's own `TgzArchive#is_unarchived`
  never trusts the raw exit code either; it parses `--compare`'s output
  line by line against a specific regex allowlist (owner/group/mode/
  mod-time/missing-file/symlink diffs) and explicitly ignores this
  exact warning pattern - reimplemented the same way, verified
  byte-for-byte against the real module's own source.
- Python's `SEP.join(iterable)` STRING-METHOD-CALL syntax (the reverse
  argument order of the `list | join(sep)` Jinja FILTER) was entirely
  unimplemented (`fail2ban`) - `' '.join(fail2ban_dependencies).split()`
  (building an apt package list) resolved to nil/"undefined" outright,
  since the receiver of `.join()` here is a quoted string LITERAL, not
  a variable name, and the existing dotted-path resolver only ever
  looked up `parts[0]` as a variable. Fixing this exposed one more
  independent recursive-re-templating copy: each list element handed to
  `.join()` needed its own re-render before joining (fail2ban_
  dependencies' 2nd element is itself a ternary-computed template), not
  just the list variable as a whole.

All fixes verified live: mysql/users/phpmyadmin/fail2ban all ended
idempotent (`changed: 0` on rerun) with real service health confirmed
(`systemctl is-active`, `mysql -u root -p... -e 'select 1'`, `curl` 200 on
phpmyadmin's own index.php, `fail2ban-client status` showing the sshd
jail). Full `crystal spec` suite (1023 examples) passes clean throughout.

---

`0.9.271`-`0.9.278` (an eighteenth real-host round: `robertdebock.*`, a
different, prolific role author than every prior round - chosen
specifically to exercise different code idioms. Of the 6 roles on the
shortlist, 4 (`grafana`, `minio`, `bind`, `postgresql`) turned out not to
exist on Galaxy or GitHub at all under those names - confirmed via both
the Galaxy API and a full listing of robertdebock's ~300 GitHub repos,
not just a single lookup miss. The remaining 2, `zabbix_server` and
`zabbix_agent`, pulled in 8 more robertdebock roles as real dependencies
(`bootstrap`, `selinux`, `container_docs`, `mysql`, `ca_certificates`,
`zabbix_repository`, `core_dependencies`) per the roles' own
`molecule/default/prepare.yml`, all installed and orchestrated together
in one playbook - real `ansible-playbook` ran the whole chain clean and
idempotent from the start, used as the correctness baseline throughout.
crystal-ansible found and fixed 8 real bugs getting there, several of
real functional consequence, not just cosmetic:

Jinja2's own type tests (`is boolean`/`is number`/`is string`/`is
integer`/`is float`/`is iterable`/`is none`) were entirely unimplemented
- only `is mapping`/`is sequence` existed before (from an earlier
round). Failed multiple roles' own defaults-sanity `assert:` blocks
(`bootstrap_wait_for_host is boolean`, `mysql_bind_address is not
none`), a pattern robertdebock's roles use pervasively that no prior
round's author happened to exercise.

The engine's own internal "undefined" sentinel string (used pervasively
as this codebase's stand-in for a real Undefined type, per many prior
fixes in this file) wasn't recognized by the `default()` filter's own
undefined-check, so a chained dict-lookup miss (`_bootstrap_packages[key]
| default(...) | default(...)`) resolved to the literal text "undefined"
instead of falling through to the real default - `bootstrap_facts_
packages` ended up as the single string "undefined", used directly as a
`loop:` value, so `package:` tried (and failed) to install a package
literally named "undefined".

Python-style `.split()` with NO arguments (whitespace-run split) wasn't
handled at all in the string-method-call code path (only the quoted-arg
form, `.split('x')`, was - fixed in an earlier round for a different
role). And a dotted-access BASE variable that's itself still-unrendered
`{{ }}` text (a role var computed from another var/dict lookup) wasn't
re-rendered before `.split()`/`.attr` walked off of it - one more
independent copy of the "recursive re-templating" bug class this file
has documented repeatedly, this time at the dotted-access base-fetch
call site specifically (every other call site already had this guard;
this one didn't).

`ansible.builtin.systemd`'s `daemon_reexec: true` param (distinct from
`daemon_reload`) wasn't recognized at all, failing outright instead of
running `systemctl daemon-reexec` - robertdebock.mysql's own handler
uses exactly this, with no other params.

`apt:`'s `deb:` parameter (install a local/URL .deb file directly,
distinct from `name:`) was entirely unimplemented - this closes out a
"looks unimplemented, unverified" flag left in `ROLES_TESTED.md` since
an earlier round (puppet/munin-node/phpmyadmin/adminer), now confirmed
real via robertdebock.zabbix_repository's own repo-install task.
Implemented: downloads a URL if given one, reads the .deb's own name/
version via `dpkg-deb -f` for idempotency, installs via `apt-get
install` (not a bare `dpkg -i`) so apt resolves the .deb's own
dependencies too.

`ansible.builtin.meta: flush_handlers` was rejected at parse time
entirely (a previously-documented scope cut - only `clear_facts`
parsed). Implemented for real, and NOT just a display-order cosmetic
fix here: several robertdebock roles (mysql, selinux,
zabbix_repository, zabbix_server, core_dependencies) use it
deliberately mid-role - flushing an apt-cache-update handler BEFORE a
later task that needs the freshly-added repo's package list, in
particular. Skipping it silently deferred every notified handler to the
very end of the play instead, which caused a genuine functional
divergence from real ansible-playbook for zabbix_server specifically: a
package install task failed "Unable to locate package" because the
repo-add handler's own cache refresh hadn't run yet by the time it was
needed.

Implementing flush_handlers immediately exposed a second, separate
latent crash: `meta:` tasks (both `clear_facts` and the new
`flush_handlers`) were never excluded from the plugin pre-upload path,
so any playbook using `meta:` against a genuine remote SSH host
crashed the whole process outright trying to look up a nonexistent
"_meta" plugin binary. Every prior use of `meta:` in this engine's own
specs ran against `localhost` only, which skips that whole pre-upload
path entirely - this bug could only ever be found by a real multi-host
SSH round exercising `meta:`, exactly what this one is.

Finally, an idempotency bug in `mysql_user`'s `update_password: always`
(real Ansible's own default, which the role leaves unset): previously
issued `ALTER USER ... IDENTIFIED BY` unconditionally on every run and
reported `changed: true` even when the password already matched - a
real divergence from real ansible-playbook, which stayed fully
idempotent (`changed=0` on rerun) throughout. Fixed by comparing
password hashes entirely server-side
(`authentication_string = PASSWORD(?)`, a boolean 0/1) rather than
pulling the raw hash value back through the driver - discovered
mid-fix that the vendored `crystal-mysql` driver's type table has no
`read` implementation at all for the LONGTEXT wire type that column
actually is (`MySql::Type::LongBlob`), so a first attempt at reading it
directly always raised and silently fell back to "assume it needs
updating," defeating the fix before the server-side-comparison rewrite.

Final state, re-verified end to end on a completely fresh host pair
(not the one used for the debugging iterations above): full playbook
run succeeds, rerun reports `changed=0` (fully idempotent),
`zabbix-server`/`zabbix-agent`/`mysql` all `systemctl is-active` =
active, ports 10050/10051 both listening. One apt-mirror 404 hit during
verification (a stale Ubuntu archive snapshot for an old mysql-8.0
`libmysqlclient21` build) - confirmed external/transient via `apt-get
update` + retry, the same failure mode already documented elsewhere in
this file, not a crystal-ansible issue.

---

`0.9.269`-`0.9.270` (a seventeenth real-host round, at the user's
explicit request: `geerlingguy.glusterfs`, single-instance first, then
a genuine 3-node cluster - real `ansible-playbook` orchestrating one
cluster, `crystal-ansible` orchestrating a separate one, both via real
SSH to 3 real nodes each, both forming actual replicated GlusterFS
volumes rather than just installing the daemon). Single-instance
install passed clean on the first try. Two external blockers hit and
patched locally (not crystal-ansible bugs, confirmed by reproducing on
real ansible-playbook too): the role's own tasks/main.yml uses the
legacy `include:` directive, removed from current ansible-core -
patched to `include_tasks:` (same failure mode already documented for
`geerlingguy.phpmyadmin`/`geerlingguy.gogs`); and `glusterfs_ppa_
version`'s own default ("7") has no PPA release for Ubuntu jammy -
overridden to "9".

The 3-node cluster phase (a hand-written peer-probe + volume-create/
start play, not part of the role itself - the standard shape every
real multi-node Ansible playbook uses) found two real engine bugs.
`hostvars[<name>]`, Ansible's magic variable for looking up any
OTHER inventory host's own vars, was entirely unimplemented - any
`hostvars['node2'].ansible_host` lookup silently resolved "undefined",
so `gluster peer probe {{ hostvars['node2'].ansible_host }}` probed a
bogus hostname instead of the real peer's IP, breaking cluster
formation outright. Implemented, sourced from the whole inventory (not
just the current play's own target hosts, since the peer-probe play
here only targets node1 but needs node2/node3's hostvars too).
Separately, `evaluate_in`'s own naive string split on " in " wasn't
quote-aware, so a quoted literal that itself contains the word "in" as
its own word (`'already in peer list' not in probe2.stdout` - `gluster
peer probe`'s own real idempotency-check message for an
already-connected peer) split at the "in" INSIDE the quotes instead of
the real operator, evaluating `changed_when` as true on every single
run regardless of the actual output - a real idempotency bug for any
multi-node cluster playbook. Fixed by reusing the same quote/paren-
depth-aware splitter already used for and/or in the same file.

Final state, re-verified after both fixes: both 3-node clusters fully
idempotent on rerun (`changed=0`), `gluster peer status`/`volume
status gv0` all green on both, and cross-node file replication
functionally verified (a file written through the mount on node1 reads
back correctly from node2).

`0.9.267`-`0.9.268` (a sixteenth real-host round: `geerlingguy.hdparm`,
`geerlingguy.daemonize`, `geerlingguy.svn`, `geerlingguy.blackfire` -
all new). `hdparm` passed clean on the first try (byte-identical
`hdparm.conf`). `daemonize` needed `build-essential` as a pre-task
prerequisite on a bare image (real ansible-playbook needs it too -
not a role or engine bug, an environment gap this benchmark harness's
throwaway hosts don't come with).

`svn` found a THIRD bug in `extract_command_special_params`, this time
over-matching rather than under-matching: with two separate `key={{
x }}`-shaped trailing params on the same command (`chdir={{
svn_repository_home }} creates={{ svn_repository_home }}/testrepo/
README.txt`), the lazy `\{\{.*?\}\}` alternative could backtrack
straight through the entire second param - including the space and
braces separating it from the first - to reach ITS closing `}}`,
silently absorbing it into the first param's value. Two independent
regex-based attempts at this extraction (0.9.261, this file's own
0.9.259-0.9.265 entry) each had a real bug in opposite directions for
the same underlying reason: a bare `\{\{.*?\}\}` can't be trusted to
stop at a single template block's boundary when backtracking is
involved. Replaced the whole regex-matching loop with a proper
brace-depth-tracking tokenizer, reusing the same scanner
`parse_inline_kv_params` already uses for free-form `key=value` args -
splitting on whitespace *outside* any template span gets every param
boundary right regardless of how many `{{ }}` blocks appear anywhere
else in the string, with no backtracking ambiguity to get wrong in
either direction.

`blackfire` found `apt_key:`'s idempotency check only ever ran when an
explicit `id:` param was given - `url:`/`data:` (the overwhelmingly
common real-world shape) always re-ran `apt-key add` and reported
`changed: true` on every single run, never converging. Real Ansible's
apt_key: derives the key's own fingerprint from the fetched key
material itself even without `id:`. Fixed by parsing every fingerprint
out of the fetched key file via a pure dry-run `gpg --import-options
show-only --import` (never touches any real keyring) before deciding
whether to import.

`0.9.266` (a fifteenth real-host round: `geerlingguy.java`,
`geerlingguy.containerd`, `geerlingguy.helm`, `geerlingguy.gogs` -
all new; `geerlingguy.registry`/`.n8n`/`.k3s` don't exist on Galaxy).
`java` and `containerd` both passed clean on the first try (the
latter's own `config.toml` byte-identical to real Ansible's). `gogs`
isn't testable at all - role version 1.4.3 uses the legacy `include:`
directive, removed entirely from current ansible-core (real
`ansible-playbook` refuses to parse the role), the same failure mode
already documented for `geerlingguy.phpmyadmin`.

`helm` found one bug, but a high-value one: `ConditionalEvaluator#
evaluate` checked a leading `not ` prefix BEFORE splitting on any
top-level ` and `/` or ` at all, so `not X or Y` negated the ENTIRE
remaining string as a single unit (`not (X or Y)`) instead of binding
`not` only to the immediate next term (the correct `(not X) or Y`,
matching real Python/Jinja2 operator precedence where `not` binds
tightest and `or` loosest). The role's own "Download helm." task
gates on `when: not helm_check.stat.exists or "..." not in
helm_existing_version.stdout` - with the binary not yet installed,
`not helm_check.stat.exists` alone is already true and real Ansible's
`or` short-circuits there without evaluating the second (undefined-
stdout) clause; here it evaluated false instead, silently skipping the
install. Reordered to split on `or` first (lowest precedence), then
`and`, then handle `not` last - this also fixes mixed `a and b or c`
chains nesting correctly via the same recursive splitting, not just
the specific `not`-prefixed case. Verified this was hand-rolled-
evaluator-only: Crinja's real recursive-descent parser (backing `.j2`
files) already gets `not`/`and`/`or` precedence right by construction.

`0.9.259`-`0.9.265` (a fourteenth real-host round: `geerlingguy.
composer`, `geerlingguy.solr`, `geerlingguy.passenger`, `geerlingguy.
drupal` - all new): `composer` and `solr` both passed clean after
fixes; `passenger` and `drupal` both confirmed external blockers
(reproducing identically on real ansible-playbook), not chased
further - `passenger`'s own apt-key fetch uses a stale key ID no
longer matching the actual repo's signing key, and `drupal`'s
`composer require` task explicitly opts out of `become:` (assumes a
non-root deploy user), which this benchmark harness's always-root
connection violates for both engines equally.

`composer` found two bugs. `get_url:`'s own `native_checksum`
algorithm case only explicitly handled md5/sha256 - every other
algorithm (sha1/sha224/sha384/sha512) silently computed SHA1 instead
regardless of what was requested, so the role's own installer
`checksum: "sha384:..."` verification always reported a mismatch on a
download that was actually correct. Separately, `command:`/`shell:`/
`unarchive:`'s `creates=`/`removes=`/`chdir=` never expanded a leading
`~` before checking the filesystem - the role's own `composer_home_
path` default is the literal string `'~/.composer'`, so the idempotency
check against `~/.composer/vendor/x` could never match a real path and
the task reported changed forever.

`solr` found six bugs, chained across a single 5-task include file -
each fix unblocked the next task rather than the role being "mostly
clean" after the first one. (1) The `creates=`/`removes=`/`chdir=`
trailing-param extraction regex's value alternative only matched a
*single* `{{ }}` brace pair; it happened to keep working when a value
had a second template block further along (the lazy match could
backtrack into it), but failed outright for exactly one template block
followed by trailing literal text with no other `}}` anywhere else in
the string (`creates={{ solr_install_path }}/bin/solr`) - extraction
silently never ran, and the raw untemplated text stayed glued onto the
command. (2) Local-connection `become_user:` plugin execution always
ran the compiled plugin binary straight from wherever crystal-ansible
itself was installed, breaking the moment that install directory
wasn't traversable by become_user (a root-owned `/root/...` install is
a common real-world case) - not actually a sudoers policy denial
despite sudo's own error text reading like one, but a plain EACCES on
the install directory's own restrictive mode; fixed by staging plugin
binaries to the same world-traversable directory the SSH path already
uses. (3) Crinja had no support at all for Python's `.split(...)`
method-call syntax on strings (`solr_version.split('.')[0] < '9'`,
used inside a role default's own `{% if %}`) - and since
`CrinjaRenderer#render`'s blanket exception handler falls back to
returning the entire original template unrendered on ANY failure, this
corrupted every task param built from that variable, not just the one
expression. (4) Crinja's `trim_blocks` (always enabled, matching real
Ansible's own Jinja2 default) incorrectly ate a literal space, not just
a newline, whenever the text right after a block tag had no newline in
it at all - real Jinja2's trim_blocks only ever removes one newline
after a block tag and does nothing otherwise; this glued two adjacent
`cp` command arguments into one. (5) `file:`'s directory creation
applied owner/group/mode only to the final leaf path of a newly-created
nested directory tree, leaving any missing *intermediate* ancestor
directories root-owned - which mattered for real when a later
`become_user:` task needed write permission on one of those ancestors
to modify its own contents and got denied.

`0.9.257`-`0.9.258` (a thirteenth real-host round: `geerlingguy.
filebeat`, `geerlingguy.fluentd`, `geerlingguy.mailhog`, `geerlingguy.
ruby` - all new): `filebeat` and `mailhog` both passed clean (the
latter's real HTTP service verified live via `curl`, not just task
status). `fluentd`'s own td-agent apt repo
(packages.treasuredata.com) has no valid Release file for Ubuntu
jammy, reproducing identically on real ansible-playbook - the same
external-repo failure class already seen with `geerlingguy.varnish`,
not chased further. `ruby` found two real bugs: `ansible.builtin.gem`
(Ruby gem management) had **no plugin at all** - both "Install
Bundler." and "Install configured gems." silently skipped outright
("Plugin not available"). Implemented (`plugins/gem.cr`, shelling out
to the real `gem` CLI, matching real Ansible's own module's approach)
supporting name/state (present/absent/latest)/version/executable
(fluentd's own td-agent-bundled `fluent-gem` needs this)/user_install/
bindir, idempotent via `gem list -i "^name$" [-v version]`. Separately:
`apt:` unconditionally reported `changed: true` whenever `apt-get
install`'s own exit code was 0, without checking whether it actually
did anything - a requested name that's a purely *virtual* package
already satisfied by something else installed (`rubygems` isn't a real
package on modern Debian/Ubuntu at all, only a virtual one `ruby`'s own
package `Provides:` - confirmed via `apt-cache showpkg rubygems`'s own
"Reverse Provides: ruby") has no real `dpkg -l` entry for the
is-it-already-installed pre-check to find, so it always fell through to
"needs install," and apt-get's own exit code is 0 either way regardless
of whether it did real work. Fixed by parsing apt-get's own end-of-run
summary line ("N upgraded, N newly installed") post-execution, the same
"trust the tool's own report of what happened, not just its exit code"
approach `pip:`'s `state: latest` already uses.

`0.9.254`-`0.9.256` (a twelfth real-host round: `geerlingguy.
tomcat6`, `geerlingguy.exim`, `geerlingguy.git`, `geerlingguy.swap` -
all new): `git` (incl. its full download/build-from-source path, not
just the already-installed default) and `exim` both passed clean.
`tomcat6` isn't testable at all - the `tomcat6` package doesn't exist
on Ubuntu 22.04 (only `tomcat9`), and both engines also independently
reject the role's own deprecated `state: installed` before ever
reaching that task, confirmed identical on real ansible-playbook.
`swap` found a chain of real bugs, most severe found in a while: the
`mount:` module never recognized `name:`, real Ansible's own original
(still commonly used, predating `path:`) alias for `path:` - the
role's own "Manage swap file entry in fstab." task (`mount: {name:
none, src: ..., state: ...}`) always failed outright with "missing
required argument: path and state are both required" even though both
were given. Fixing that surfaced a much deeper gap: `*`/`/`/`//`
arithmetic were **entirely unimplemented anywhere in the plain `{{ }}`
evaluator** - even a bare `{{ 10 / 2 }}` rendered the literal string
"undefined" (only `+`/`-`/`~` had top-level operator support before).
The role's own `check-size.yml` does `(stat.size / 1024 / 1024) | int`
to compare an existing swap file's size in MB against the configured
one - the whole division chain resolving undefined meant this
comparison always differed, silently deleting and recreating the swap
file on every single run instead of converging (only caught by
re-running the role twice, per this project's own established
discipline). Implementing `*`/`/`/`//` (verified digit-for-digit
against real Python's own jinja2.Environment: `/` always produces a
float even when evenly divisible, `*` preserves int when both operands
are int, `//` floors to int, and `*`/`/` bind tighter than `+`/`-`)
surfaced two more, each masking the next: the `int` filter always
converted its input to a decimal-point STRING first ("256.0"), and
Crystal's own strict `String#to_i64?` rejects any decimal point
outright, silently defaulting to 0 for ANY float input, not just one
arriving via division (Crinja's own separate `int` filter, for real
`.j2` template files, already had this right); and a bare numeric
literal (`{{ 5 }}`, or a literal float piped straight into a filter
with no variable or arithmetic involved, `{{ 5.7 | int }}`) was never
checked anywhere in the dispatch chain **on its own** - only ever as an
*operand* inside a larger `+`/`-`/`*`/`/` expression - so it fell
through to a plain variable-name lookup on the literal digit text
itself, always undefined. The bare `when:`/`assert:`-condition
evaluator (`ConditionalEvaluator`, entirely separate from the `{{ }}`
one) had its own independent copy of the same `*`/`/`-recognition gap
too - a bare `when: n / 2 == 5` never routed to the arithmetic-capable
evaluator at all.

An eleventh real-host round (`geerlingguy.puppet`, `geerlingguy.
munin-node`, `geerlingguy.phpmyadmin`, `geerlingguy.adminer` - all new)
found **no crystal-ansible bugs at all** - `munin-node` and `adminer`
(the latter including its `geerlingguy.apache` dependency's config-
writing path, functionally verified serving `adminer.php` via `curl`)
both passed byte-identical and idempotent on the first try. The other
two hit real, confirmed-external blockers, not engine gaps: `puppet`'s
own apt-key task fails identically on real `ansible-playbook` too -
Puppet Labs' own published GPG key for the configured `puppet_version`
has expired upstream. `phpmyadmin`'s pinned role version (1.3.3) uses
`include:`, a directive real modern `ansible-core` (2.17) has removed
entirely - real `ansible-playbook` refuses to even parse the role,
making a real-host baseline comparison impossible with current
ansible-core; crystal-ansible is more lenient and still supports the
legacy directive, running the role further before hitting the
already-documented `geerlingguy.mysql` dependency's `unix_socket`/
`auth_socket` auth gap (see the `crystal-mysql` limitation below), not
a new issue.

`0.9.250`-`0.9.253` (a regression-verification round, not a new-role
round - re-running `dev-sec.os-hardening`, previously marked clean back
in an earlier session, specifically to stress-test the truthiness/bool
fixes from `0.9.240`-`0.9.249`): none of the 4 real bugs found were
regressions from that work - all pre-existing gaps this specific role's
own task shapes simply hadn't exercised before. `with_flattened:` (the
short lookup-plugin-name alias real roles actually write - os-
hardening's own "find files with write-permissions for group"/"change
system accounts" tasks both use exactly this spelling, never the FQCN
form) was **entirely unrecognized as a loop keyword** - missing from
both the loop-source extraction and the special_keys allowlist that
decides "is this a keyword or the module name" - so the whole task ran
exactly ONCE, not looped at all, with `item` completely unbound
(rendering the literal string "undefined" into the command). Fixing
that surfaced two more real bugs in the SAME resolver
(`TaskExecutor#resolve_loop_flattened`, also reachable via the FQCN
form) that a misleading, dead, never-called duplicate in
`loop_resolver.cr` had made look already-correct on a first read: every
literal string source (`'/usr/local/sbin'`, not `{{ }}`-templated at
all) was silently DROPPED rather than contributed as one item; and a
filter-chain source (`"{{ x | difference(y) | list }}"`, not a bare
`{{ var }}` reference) rendered to one JSON-array-shaped STRING pushed
as a single item instead of being evaluated and flattened - `user:
name={{ item }}` then tried to `useradd` one literal string containing
every username joined by commas inside brackets. Separately: a real
Jinja2 `in` test against a *variable-bound* list inside `{% if %}`
(`'amd' in ansible_facts.processor`) failed to parse outright -
`TemplateActionPlugin#rewrite_in_expr` (the `in`/`not in`-to-`is
in(...)` rewrite Crinja itself needs, since it has no native infix `in`
operator) only ever recognized a `[...]` literal or a `(...)` tuple as
the right-hand container, never a bare variable/dotted-path reference -
by far the more common real-world shape. `os_hardening` now passes
`failed=0` and is fully idempotent (`changed=0` on rerun);
`geerlingguy.kibana`/`geerlingguy.supervisor` were re-verified clean
end to end too (byte-identical config, idempotent, `supervisorctl
status` functionally authenticating with the `hash`-filter password).
`konstruktoid.hardening` locked itself out of SSH mid-run on the REAL
`ansible-playbook` baseline host (port 22 specifically closed, ICMP
still responding - sshd or ufw, not a network drop) - confirmed not a
crystal-ansible-side issue (only the python host was affected) and not
chased further; abandoned for this round per the user's call, given
`os_hardening` had already produced strong signal.

`0.9.249` (a proactive audit pass, not a real-host round - following
`0.9.244`'s Crinja `Value#truthy?` fix, checked whether the same
empty-container-truthiness bug class had independent copies elsewhere,
the way recursive re-templating turned out to have several): all 24 of
Crinja's own `Value#truthy?` call sites (`{% if %}`, `{% for x in y if
x %}`, `and`/`or`/`not`, `select`/`reject`, `default(fallback, true)`,
etc.) verified correct now that the fix lives in the one shared method -
Crinja centralizes truthiness through a single method, unlike this
codebase's own hand-rolled evaluator, so no further Crinja-side copies
existed. Did find one, though, in a *completely different* evaluator:
`ConditionalEvaluator#evaluate_truthiness`/`#evaluate_value` (the bare
`when:`/`assert:`/ternary-condition path, unrelated to Crinja) had no
`Hash` case at all in its return union (an empty Hash's own `#to_s`,
`"{}"`, is a non-empty *string* - always truthy) and no `Array` case in
its own truthiness `case` either (silently falling through to an
unconditional `else -> true`) - `when: my_list` with `my_list: []` (or
`my_dict: {}`) always ran the task, verified directly against real
Python's own `bool([])`/`bool({})`. Fixed by checking Hash/Array
emptiness directly against the resolved `JSON::Any` (via
`VariableLookup#resolve`, the same simple/dotted/indexed resolver `{{
}}` substitution already uses) before ever going through the lossy
union conversion - covers bare variables, dotted paths, and (since
inline ternary already delegates its own condition to
`ConditionalEvaluator`) `'x' if my_list else 'y'` too, all in one fix.

Separately (not a bug, a redundancy worth knowing about): this file's
own `real_truthy?`/`pytruthy` filter/`TAG_IF_ELIF` tag-rewriting
machinery in `jinja_filters.cr`/`template_action_plugin.cr` was built
specifically to work around the now-fixed `Value#truthy?` gap, on the
(no-longer-true) assumption that `lib/crinja` couldn't be patched from
outside. It's harmless to leave in place - `real_truthy?` and the fixed
`Value#truthy?` now agree on every case - but it's duplicated logic
that could silently drift out of sync if one is ever edited without the
other. `TAG_IF_ELIF`'s rewrite can't be removed outright regardless (it
also handles real Jinja2 `in`/`not in` infix-test rewriting in the same
pass), just the `| pytruthy` suffix it appends is now redundant.
Simplification candidate for a future session, not urgent.

**No known cross-cutting engine gap is open right now** - but that status
is continuously re-earned, not permanent. Each real-host benchmark round
against a new production Ansible role tends to find more (most recently
15 in the `linux-system-roles` round, `0.9.158`-`0.9.171`: depth-unaware
operator parsing that could stack-overflow, block-level `vars:` never
parsed, a missing `d()` filter alias, dict/array literals unsupported
outside a `+` operand, among others - `git log --oneline --grep=
"0\.9\.1[5-7][0-9]" -E` for the full list). Treat "no gap remains open"
as "none is known right now," not as a claim the search is finished.

`0.9.243`-`0.9.248` (a tenth real-host round: `geerlingguy.clamav`,
`geerlingguy.kibana`, `geerlingguy.logstash`, `geerlingguy.gitlab` - all
new): six real bugs, several engine-wide. `clamav` found `.find(substring)`
(Python's `str.find`, returns the match index or -1) was entirely missing
from `VariableLookup#string_method_call` (only `.split(...)` existed) -
`freshclam_result.stderr.find('locked by another process') != -1` in the
role's own `failed_when:` always resolved to undefined, which compared
truthy against `-1`, so the task's real (and, on Debian, expected)
nonzero exit from freshclam's post-install auto-run always propagated as
a genuine failure instead of being suppressed. `kibana` found Crinja's own
`Value#truthy?` (lib/crinja/src/runtime/value.cr) only special-cased
`false`/`0`/`nil`/undefined, leaving an empty String/Array/Hash truthy -
Python/Jinja2 treats all three as falsy too. This silently broke `and`/
`or` (both operators collapse straight to a Bool via `.truthy?`) wherever
both operands could be empty: `{% if kibana_elasticsearch_username and
kibana_elasticsearch_password %}` (both default to `""`) rendered the
`{% if %}` branch - a live, wrong `elasticsearch.username: ""` pair -
instead of real Ansible's own commented-out `{% else %}` placeholder.
Fixed by reopening `Crinja::Value` (crinja_truthy_ext.cr), the sanctioned
way to extend vendored Crinja without editing `lib/crinja` directly (see
crinja_hash_ext.cr's own doc comment) - verified directly against real
Python's own `jinja2.Environment`, not just the real host. `logstash`
found two bugs: the `to_json` filter (wraps Python's `json.dumps()`) was
entirely unimplemented in both Jinja2 evaluators - `hosts => {{
logstash_elasticsearch_hosts | to_json }}` failed the whole template
render outright (implemented to match Python's own `", "`/`": "` default
separators, not Crystal stdlib's compact `,`/`:`, for a byte-identical
diff); and `command:`/`shell:`'s own trailing `chdir=`/`creates=`/
`removes=`/`executable=` extraction (added the firewall round,
`0.9.234`-`0.9.237`) broke on a *templated* value with internal spaces
(`chdir={{ logstash_dir }}`, the near-universal spacing style - the
`chdir={{x}}` no-space form already worked) - `\S+` only matched up to
the template's own leading space, so the whole extraction silently
failed and the untemplated text stayed glued onto the command, which
then ran from the wrong directory and failed outright even though the
target binary existed. `gitlab` found the deepest bug of the round: a
handler's own `register:`/`changed_when:`/`failed_when:` were entirely
unapplied - `execute_handler_plugin_once` (the handler-only dispatch
path already found missing an action-plugin-render step in the jenkins
round) just returned the raw plugin result, so `register:` on a handler
was silently never stored (invisible to anything downstream, including
a same-named `listen:` follow-up) and `failed_when:`/`changed_when:`
could never override a handler's default pass/fail. geerlingguy.gitlab's
own "restart gitlab" handler (`command: gitlab-ctl reconfigure`,
`failed_when: gitlab_restart_handler_failed_when | bool`) depends on
this: the role hits a real, upstream GitLab-version incompatibility
(`git_data_dirs` was removed in GitLab 18.0, but the role's own
`gitlab.rb.j2` still writes it - confirmed identically failing when
`gitlab-ctl reconfigure` is run directly on both hosts, a role/version-
staleness issue, not a crystal-ansible bug) that `failed_when:` is
specifically meant to suppress; real ansible-playbook reports this
handler as "changed", not failed. Chasing why `| bool` didn't suppress
it surfaced a second, independent bug: the plain `{{ }}` evaluator's own
`bool` filter reused the *general* `#truthy?` helper (correct for
`when:`/`{% if %}` truthiness) instead of real Ansible's own `bool`
filter semantics (`ansible.module_utils.parsing.convert_bool.boolean()`,
non-strict) - a small fixed keyword set for true/false, `false` for
anything else - so ANY non-empty, non-"0"/"false" string filtered
through `| bool` came out `true`. `gitlab_restart_handler_failed_when`'s
own default value is the arbitrary expression *string*
`'gitlab_restart.rc != 0'` (not a recognized keyword) - verified
directly against real ansible-playbook that `{{ 'gitlab_restart.rc != 0'
| bool }}` renders `false`, not `true` (the separate Crinja-side `bool`
filter already had this right).

`0.9.240`-`0.9.242` (a ninth real-host round: `geerlingguy.munin`,
`geerlingguy.samba`, `geerlingguy.supervisor`, `geerlingguy.htpasswd` -
all new). `geerlingguy.samba` passed clean on the first try (a mid-round
apt 404 turned out to be a stale package-list cache on the crystal-
ansible host specifically, from never having run `apt-get update` there
- confirmed environmental by reproducing the exact same 404 with raw
`apt-get install` before a cache refresh, then clean after one).
`geerlingguy.munin` and `geerlingguy.htpasswd` both found the same root
cause: `community.general.htpasswd` had no plugin at all (every
`htpasswd:` task - munin's own admin-user setup, the whole point of the
`htpasswd` role - silently skipped with "Plugin not available").
Implemented from scratch: reads/writes the `user:hash` file format
directly, hashes via `openssl passwd -stdin` (password piped over
stdin, never an argv element) rather than hand-rolling apr1/md5-crypt's
bit-level algorithm, supports `apr_md5_crypt` (default)/`md5_crypt`/
`sha256_crypt`/`sha512_crypt`/`plaintext`, and is idempotent by
recomputing the hash with the existing entry's own salt and comparing
byte-for-byte rather than always writing a fresh (unmatchable) random
salt. Verified independently against `openssl passwd -apr1` directly,
not just self-consistently. `geerlingguy.supervisor` found two real
engine bugs from one template file (`supervisord.conf.j2`): the `hash`
filter (`{{ supervisor_password|hash('sha1') }}`, real Ansible's own
`ansible.plugins.filter.core.hash`, wrapping Python's `hashlib`) was
entirely unimplemented in both the Crinja template pipeline and the
plain `{{ }}` evaluator - the whole template render failed outright;
and a bare boolean interpolated into a `.j2` template (`nodaemon = {{
supervisor_nodaemon }}`) rendered Crystal's lowercase "false" instead
of real Jinja2/Python's capitalized "False" (the plain `{{ }}`
evaluator already had this right via `VariableLookup#format_value` -
only the separate Crinja pipeline's own `Finalizer` was missing a Bool-
specific stringify case, another instance of the two independent
evaluators diverging on the same bug class). A third, cosmetic-only
divergence in the same template was found and left open - see the
narrow-scope-cuts list below.

`0.9.239` (a fourth extension of the eighth round, same hosts:
`geerlingguy.postgresql`, new; `geerlingguy.nginx`/`geerlingguy.docker`
re-run as regression checks, both still pass): the recursive-re-
templating bug class's newest sub-case - a role default that's a list
of dicts (`postgresql_hba_entries`), whose own field values are
themselves unrendered Jinja (`auth_method: "{{ postgresql_auth_method
}}"`, a default computed from another default). Every prior fix for
this bug class only ever re-rendered a *top-level* String variable
value; both `CrinjaRenderer#prepare_crinja_vars` and the separate
`TemplateActionPlugin#prepare_template_vars` now recurse into Array/
Hash values too, re-rendering every String leaf.

`0.9.238` (a third extension of the eighth round, same hosts:
`geerlingguy.haproxy`/`geerlingguy.certbot` re-run as regression checks
- both still pass exactly as they did in round 4, no divergence -
plus `geerlingguy.pip`, new): `ansible.builtin.pip` was entirely
unimplemented (no plugin at all) - every real playbook's `pip:` task
silently skipped. Implemented supporting name/version/state (present/
absent/latest)/virtualenv/executable/extra_args/chdir/requirements.

`0.9.234`-`0.9.237` (a second extension of the eighth round, same
hosts: `geerlingguy.ntp`, `geerlingguy.node_exporter`,
`geerlingguy.firewall` - all new; `geerlingguy.golang`/`geerlingguy.
consul` don't exist on Galaxy). `ntp` found `service_facts:` was
missing from `TaskBatcher`'s fact-producing guard list (already had
`getent`/`package_facts`/`set_fact` there) - a task's `when:` reading
the bare `services` fact right after "Populate service facts." always
silently skipped, since batching pre-renders every group member's
params before any of them actually run. `node_exporter` found THREE
bugs from one "download latest release from GitHub and extract it"
task: `is match(...)`/`is search(...)` (real Jinja2's regex tests)
were entirely unimplemented; `regex_replace` (Python's re.sub with
backreferences) was missing from the plain `{{ }}` evaluator entirely
(Crinja's separate pipeline had one, but a bare `{{ }}` span never
reaches it); and `unarchive:`'s `src:` as a URL (with `remote_src:
true`) was never implemented at all - real Ansible's own module
explicitly fetches it first when `src:` contains "://". `firewall`
found `command:`/`shell:`'s own legacy free-form syntax never
extracted trailing `creates=`/`removes=`/`chdir=`/`executable=`
key=value params the way every other module's inline syntax does -
the whole string (options text included) ran as the literal command.

`0.9.233` (an extension of the eighth round, same hosts:
`geerlingguy.nfs` - new; `geerlingguy.php-mysql` was also attempted but
its own repo doesn't ship a `vars/Debian.yml` at all, and real
`ansible-playbook` fails identically on that same task - a role
limitation, not a crystal-ansible gap): found two bugs, both in the
filter engine. `map()` only implemented the `map(attribute='x')` form;
real Jinja2's filter-name positional form (`map('split')`,
`map('first')`) silently no-op'd - `nfs`'s own "Ensure directories to
export exist" task (`nfs_exports | map('split') | map('first') |
unique`, pulling just the directory-path column out of each raw
`"/path *(opts)"` export line) left the WHOLE export line - options
text included - as the target directory path. Separately, `split` with
no delimiter argument passed an empty string to Crystal's own
`String#split`, which splits into individual *characters* for an
empty-string arg rather than matching real Python/Jinja2's
whitespace-run default (Crystal's own no-arg `String#split` overload
already does, and is what's used now).

`0.9.232` (an eighth real-host round: `geerlingguy.memcached`,
`geerlingguy.rabbitmq` - both new; `geerlingguy.varnish` was also
attempted but blocked by an external issue - its packagecloud.io apt
repo currently has no valid Release file for Ubuntu jammy, reproduced
identically on real `ansible-playbook`, not a crystal-ansible gap;
`geerlingguy.mongodb` doesn't exist on Galaxy anymore, skipped):
`geerlingguy.memcached` passed clean on the first try - byte-identical
`/etc/memcached.conf`. `geerlingguy.rabbitmq` found two bugs:
`deb822_repository`'s own `signed_by:` support (added last round) only
handled an already-local path - rabbitmq's own task gives a bare
`keys.openpgp.org` URL directly, previously written completely
literally into `Signed-By:`, which apt rejected outright; now fetched
(binary-safe), dearmored via `gpg` if ASCII-armored, and stored at
`/etc/apt/keyrings/<name>-archive-keyring.gpg` (real Ansible's own
naming convention). Separately, `apt:`'s own `name=version` pinning
syntax (`rabbitmq-server={{ rabbitmq_version }}-1`) was passed straight
to `dpkg -l` for the already-installed check, which doesn't understand
that syntax at all - reported changed on literally every run even once
the exact pinned version was already installed.

`0.9.230`-`0.9.231` (a seventh real-host round: `geerlingguy.jenkins`,
`geerlingguy.elasticsearch` - both new, both required overriding a role
default to work at all in this environment: `geerlingguy.java`'s own
default installs Java 17, which current Jenkins packages refuse to run
on (needs 21) - an environment/role-staleness issue affecting real
`ansible-playbook` identically, not a crystal-ansible gap, fixed by
overriding `java_packages:` for the round). `geerlingguy.jenkins` found
four real bugs: a handler written as `include_tasks: file.yml` (real
Ansible's own shorthand) crashed the whole process outright for any
remote host - the handler-collection loop in `batch_upload_plugins_
for_playbook` had no pseudo-module guard, unlike the regular-tasks
collection path; a handler using an action-plugin module (`template:`)
never ran the controller-side render step at all, since
`execute_handler_plugin_once` (a separate dispatch path from regular
tasks) never checked `ActionPluginManager`; `lineinfile`'s "exact line
already present" idempotency check was gated behind `!regexp`, so ANY
`regexp:` that failed to match - regardless of whether the target line
already existed verbatim - skipped straight to insertion, appending a
fresh duplicate line on every single run; and `get_url`'s `force: true`
unconditionally reported `changed: true` after every download, when
real Ansible's own `force: true` means "bypass freshness checks before
re-fetching," not "always report changed" - it still compares the
downloaded content against `dest:` first. `geerlingguy.elasticsearch`
found that plain-string character indexing (`elasticsearch_version[0]`
on `"7.x"`, matching real Jinja2/Python `str[0]`) was entirely
unsupported - only Array/Hash indexing existed - so the role's own
`elasticsearch_version[0] | int < 7` version-branch `when:` silently
defaulted to comparing against `0`, picking the wrong (pre-7.x) config
file layout and failing to start the service outright.

`0.9.225`-`0.9.226`: a proactive audit pass (not a real-host round -
grepping every remaining `VariableLookup#resolve` call site in the
engine after rounds 2-3 found 5 independent copies of the recursive-
re-templating bug) found and fixed **8 more copies** of the exact same
gap: `ConditionalEvaluator`'s `is mapping`/`is sequence` test and its
dotted-access lookup, two separate `FilterEngine` fallbacks, both of
`ComparisonEvaluator`'s dotted-path counterparts, and `TaskExecutor#
deep_render_item`'s loop-item native-type fast path. Fixing one of
those (a loop item's own re-render) surfaced a **10th, related** copy
in `TaskExecutor#resolve_template_value` (the loop: SOURCE itself, not
just each item) - found while writing a test, not via a real-host
round. That same investigation turned up a genuinely different bug: a
single-element `loop:`/`with_items:` list holding one bare `{{ var }}`
span, where `var` resolves to a scalar rather than a list, silently
produced NO loop items at all instead of one iteration - verified
against real `ansible-playbook` directly (both `loop:` and
`with_items:` treat this identically) before fixing.

`0.9.227` (a fourth real-host round): `geerlingguy.haproxy` passed
clean on the first try - byte-identical rendered config, no bugs.
`geerlingguy.certbot` found that `cron:` required `cron_file:`, a
documented but overly-broad scope cut - the real risk (this test
suite's OWN crontab getting mutated as a spec side effect) doesn't
apply to managing an arbitrary TARGET user's live crontab via `crontab
-u`, which is real Ansible's own default (`cron_file:` omitted) and
exactly what certbot's own renewal-cron task uses. Implementing it
surfaced its own bug: the install path added an extra trailing newline
on top of one `PluginHelpers::CronTable.upsert` already appends,
producing a blank line at the end of the installed crontab that made
every subsequent run see a "changed" diff against itself forever -
caught by testing idempotency explicitly (a second run), not just a
single successful one.

`0.9.229` (a sixth real-host round: `geerlingguy.apache`, `geerlingguy.
nodejs` - both new): `geerlingguy.apache` passed clean on the first try
- byte-identical vhost config, matching enabled mods, healthy service.
`geerlingguy.nodejs` hit the already-flagged `ansible.builtin.
deb822_repository` gap (see the narrow-scope-cuts list below for what's
now implemented) - a SECOND real role independently needing it after
`geerlingguy.docker`, which raised its priority enough to implement
this round rather than defer again. With the repo now actually added,
`apt-get update` sees the NodeSource suite and the role's own
subsequent `nodejs=20.x*` install task reached parity with real
`ansible-playbook` up through that point; the install itself then hit
an external NodeSource-repo/apt-cache inconsistency (`nodejs` briefly
reporting as a virtual package with no installable candidate) that
reproduced identically running the *exact same* raw `apt-get install`
command directly on the real-ansible-playbook host too - confirmed
environmental, not a crystal-ansible-specific divergence, and not
chased further.

`0.9.228` (a fifth real-host round: `geerlingguy.redis`, `geerlingguy.
postfix` - both new): `geerlingguy.postfix` passed clean on the first
try, including a byte-identical `main.cf` (module the two hosts'
hostnames, expected to differ). `geerlingguy.redis` found three real
bugs: `apt:` install/upgrade never passed `--force-confdef`/
`--force-confold` (real Ansible's own `apt` module default
`dpkg_options`), so installing a package whose shipped conffile
differs from a pre-existing one (redis's role templates its config
file before installing the package) hung forever on dpkg's interactive
conffile prompt with no stdin to answer it; the legacy free-form
`key={{ x }} key2=y` inline module-args tokenizer split on every
whitespace character with no awareness of `{{ }}`/`{% %}` as an opaque
span, shattering a templated value's own internal spaces into bogus
tokens and corrupting the expression irrecoverably before templating
ever ran (`service: "name={{ redis_daemon }} state=restarted"`,
real Ansible's legacy syntax, is exactly the shape geerlingguy.redis's
own handler uses); and `mode:` piped through a variable that's itself
an unquoted-octal YAML literal (`redis_conf_dir_mode: 02770`) lost its
octal-ness - Crystal's own YAML parser (like real Ansible's) resolves
that literal to a decimal Int64 at vars-file parse time, and unlike a
*direct* `mode: 0770` task literal (which already recovers its octal
digit text, see the `0.9.210`-`0.9.224` entry below), piping the same
decimal-converted int through a variable and a bare `{{ }}` template
bypassed that recovery entirely - `chmod` received an invalid mode,
silently no-opped, and the directory reported "changed" on every
subsequent run since the never-applied target mode could never match
the real one.

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

- **Crinja's `-%}`/`{%-` explicit whitespace-control markers under-trim
  by one blank line across a skipped `{% if false %}...{% endif -%}`
  block immediately followed by another `{%- if %}...{% endif %}`
  block** - found via `geerlingguy.supervisor`'s own supervisord.conf.j2
  (two adjacent `[unix_http_server]`/`[inet_http_server]` conditional
  sections, both false by default): real Jinja2 (verified directly
  against Python's own `jinja2.Environment(trim_blocks=True)`, and
  against the real-host `ansible-playbook` output) collapses the blank
  line between the two blocks' tags to nothing; Crinja leaves one blank
  line behind, a single stray byte in the rendered file. Purely cosmetic
  - INI-style config parsers (supervisord's included) ignore blank
  lines, and the affected service started and passed a real functional
  check (`supervisorctl status` showing the configured program
  running) - not chased further given the fix would need touching
  vendored `lib/crinja`'s own lexer-level trim-distance tracking
  (`lib/crinja/src/parser/template_lexer.cr`'s `check_for_end`/
  `trim_left`/`trim_right` handling), already flagged elsewhere in this
  codebase (`lstrip_blocks` is forced off - see
  `template_action_plugin.cr`'s own comments) as an area with known
  quirks. Revisit if a real template's correctness (not just
  byte-identical output) ever depends on it.
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
- **`crystal-mysql`'s wire-protocol driver** — `auth_socket`/`unix_socket`
  authentication support was added to the `weirdbricks/crystal-mysql` fork
  (tag `crystal-ansible-0.9.340`, commit `a91a592`): `CLIENT_PLUGIN_AUTH`
  now advertised unconditionally, auth plugin name written even without a
  password, and `Auth.scramble` returns an empty response for
  `auth_socket`/`unix_socket`/`mysql_clear_password` plugin names. A role
  connecting via `login_unix_socket:` with no password can now authenticate
  using socket peer-credential auth. `mysql_user.cr` also now implements
  the `plugin:`/`plugin_hash_string:`/`plugin_auth_string:` params for
  *creating/updating* accounts with non-password auth (`IDENTIFIED WITH <p>
  [AS <hash> | BY <auth>]`, matching real Ansible's module_utils/user.py
  precedence; the `plugin: unix_socket`/`auth_socket` case for socket
  accounts is fully idempotent, diffing the account's current plugin
  server-side). Verified end-to-end by `testing/test-mysql-auth-socket.sh`
  against a throwaway MariaDB container (all four mysql_* plugins connect
  over a Unix socket as OS root with no login_password).
- **`to_datetime()`/timedelta arithmetic beyond subtraction** stayed
  narrowly scoped to what real roles have needed so far - revisit if a
  role needs more.
- **`ansible.builtin.deb822_repository`** (fixed `0.9.229`, URL `signed_by:`
  fixed `0.9.232`, inline key/fingerprint/redirects/check_mode `0.9.343`)
  now supports the full four-way `signed_by:` branching matching real
  Ansible's own module: local path (`os.path.isfile`), URL (redirect-
  aware download, stored as `<name>.asc` or `<name>.gpg`), inline
  ASCII-armored GPG key text (Deb822 folded multi-line format), and
  key fingerprint (space-normalized on one line). `check_mode` no longer
  triggers network I/O. Rendered content includes `X-Repolib-Name:`
  matching real Ansible's output.

`postgresql_privs` is the one per-plugin scope-cut list this project
originally tracked that reached **zero open items** (`0.9.84`) - every
`type:` real Ansible's module supports is implemented, including
`function`/`procedure` signatures and `default_privs`. New scope cuts get
found continuously through real-host benchmark rounds against production
Ansible roles instead of from a static pre-planned list; `git log` for
each round's own commits for what it left open, if anything.
