# Known Missing / Known Gaps

The goal is 100% behavioral compatibility with `ansible-playbook`,
verified against real runs rather than assumed - not "cover the common
cases" - for **core (`ansible.builtin`) modules**. For community
modules, krikri chooses which ones it supports: a module explicitly
promoted to supported owes the same 100%-parity bar as core, but krikri
is not trying to reimplement every community module that exists (an
unbounded, ever-growing target). A divergence whose root cause is an
**unsupported** community module doesn't belong in this file at all -
not as an Open gap, not as a Deliberate limit - it isn't scope, so it
isn't tracked here. (See `krikri-role-tester`'s own
`COMMUNITY_MODULE_MISSING` classification and its
`SUPPORTED_COMMUNITY_MODULES` list for how a round's results already
reflect this before anything reaches this file.) This file tracks
what's actually missing **today** within that scope. It does
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
it does not linger at the top. This file carries no per-round
narrative or fix history - `git log` is the record of what was found
and fixed and when.

**Currently at `0.9.1471`.**

## Open gaps

- **Registered-result key order: what is verified and what is not.** `PluginResult#key_order` (or an
  omit-`changed` wire) pins a plugin's keys to real 2.19.11's order. Everything below was compared against
  real on the same host, cold and warm, with `{{ r | to_json }}` probe roles
  (`testing/keyorder_probes/kop_*`, run through `krikri-role-tester run` with `local:` queue entries and compared
  by `krikri-role-tester keyorder`; rounds 997000-997006 and 998000, 0.9.1468/0.9.1470: 168 probes on 7 roles, all
  identical on Ubuntu 22.04 and Rocky 9, every role's PLAY RECAP CLEAN; `keyorder --values` also compares the values, and
  what is left there is host noise - apt/dnf output text, per-host keys/UUIDs, snap loop devices, mount and systemd
  dependency ordering). Verified on real hosts: `user`, `group`,
  `authorized_key`, `known_hosts`, `sysctl`, `mount_facts`, `modprobe`, `ufw`, `apt` (install/no-op),
  `lvg`, `lvol`, `parted`, `zfs`, `mount`, `synchronize`, `subversion`, `apache2_module`, `java_cert`,
  `openssl_csr`, `openssl_csr_info`, `deploy_helper`, `easy_install`, `maven_artifact`,
  `current_container_facts`, `virt_net`, `selinux`, `seboolean`, `sefcontext`, `seport`, `firewalld`,
  `service` (systemd path), `dnf`, `copy` (failure shapes) - and, on the dev box in containers, the Docker
  plugins, `docker_image_build`, `podman_image`, the rpm family and `gem`/`rpm_key`. Some of these have no
  literal `key_order` call (`grep -L key_order plugins/*.cr` lists them) because their shape comes from an
  omit-`changed` wire or the controller backfill; `setup`/`gather_facts`/`wait_for_connection`/`fail` are
  handled outside their plugin files. Not verified, and why:
  - `snap`: snapd is too heavy for a probe round, so it is deliberately not probed.
  - `homebrew`, `homebrew_cask` and `homebrew_tap` are not supported (dropped 0.9.1466: macOS-first, under 1.5% of the roles we have
    run, and nearly all of those only on macOS-only code paths); a task using one stops with the unimplemented-module error.
  - The real-mutation variants of `iptables` (its check-mode/stub shapes are pinned); not probed.
  - `ovirt_auth`, `redhat_subscription`, `rhsm_repository` and `rhsm_release` are not supported (dropped 0.9.1470: each needs
    a live oVirt engine or a Red Hat entitlement to run for real, and together they appear in under 0.3% of the roles we
    have run); a task using one stops with the unimplemented-module error.
  - *Needs an external account or appliance neither engine can reach from either host (not a gap to
    close without credentials):* `ec2_*`, `iam_user_info`, `nsupdate`, `rabbitmq_*`.
  - Known value (not shape) differences left as they are: the order of the `public_key_fingerprints` entries
    (real builds them from a Python set, so its order is nondeterministic) and `ufw`'s `commands`/`apt`'s failure
    results on the mutating paths, which are verified against real's command construction and wording but not yet
    end-to-end on a real host after 0.9.1470. `krikri-role-tester keyorder --values` over a probe round is how
    any remaining value difference is found; host-specific noise (apt output text, per-host keys, snap revisions)
    shows up there and is not a krikri difference.
- **PostgreSQL gaps found while verifying:** the aliases real deprecates (`port`, `host`, `login`, `unix_socket`, `db`)
  now print/register real's deprecation; connection failures use libpq's own wording (refused, wrong password,
  missing database, missing unix socket - byte-identical to real); `postgresql_query` without a database name warns
  like real. Still different: a *temporary* resolver failure prints the EAI_NONAME wording (Crystal's
  `Addrinfo::Error` carries no gai code) and strerror texts are glibc's. `postgresql_*` and
  `mysql_db`/`mysql_query`/`mysql_user`/`mysql_variables` results and accepted-parameter sets otherwise match real
  (live-verified on postgres:17 / mysql:8.4); real builds `postgresql_privs`'s privilege list from a Python
  frozenset, so its multi-privilege ordering is nondeterministic and krikri keeps declared order. The PostgreSQL
  live tests on port 15432 need a postgres:16 server (the host's pg_dump is 16; a 17 server fails the dump/restore
  test).
- **Docker plugin gaps found while verifying** (results otherwise match real on podman's Docker-API socket):
  the text wrapped after real's own error prefixes is the Python SDK's wording (`500 Server Error for
  http+docker://...`) where krikri's client prints `Code: 500 Message: ...`; check-mode `create_parameters` carries only
  the fields krikri itself sends where real also records defaulted options; `docker_container`'s list options
  (`command`, `entrypoint`, `volumes`, `ports`) have their own JSON wire in the parser (other modules' YAML lists use
  the generic comma-joined wire - a list element containing a comma is ambiguous there).
- **`konstruktoid.hardening` real-host parity is unconfirmed** (rounds
  975062/978000, 2026-09-26): real `ansible-playbook` doesn't complete
  within 30 minutes on this role even on a fresh host (`rc=124` both
  attempts) - too slow to establish parity either way, not a krikri
  signal. After krikri's own cold run completed (modulo the then-unfixed
  `systemd` query-only gap), the host became SSH-unreachable for the warm run; whether
  that's a krikri-specific regression or simply this hardening role's own
  SSH/firewall changes taking effect (which real Ansible never got far
  enough to also demonstrate) is unresolved.

## Deliberate limits (decided, not defects)

Everything here is a decision someone already made, with the reasoning
attached. Nothing here is waiting on anyone. Do not re-litigate without
new evidence - and if new evidence turns up, move the entry to "Open
gaps" rather than arguing with the note in place.

### Console-output differences from ansible-core 2.19.11 that cannot be matched

krikri aims for byte-for-byte identical stdout/stderr/exit code to `ansible-playbook` 2.19.11 (checked with
`scripts/output_parity.sh` and the per-module `krikri-playbook-generator`). The known exceptions:

- Python interpreter-discovery warnings (`Host ... is using the discovered Python interpreter ...`) are not
  emulated - krikri has no Python interpreter to discover.
- Values that are random per real run: temp file/dir names, the order of string sets (`union`/`intersect`/...
  on lists of strings) and the order of several invalid options in one error message. Integer set order
  *is* reproduced.
- `community.general.filesystem`'s `value of fstype must be one of: ...` choices list: real builds it from
  a Python set of strings (`fstypes = set(FILESYSTEMS.keys()) - ...`, then `choices=list(fstypes)`), so the
  order is randomized per real process by string-hash randomization - five consecutive real 2.19.11 runs
  with the same bad `fstype` each printed a different order (verified live, kpg35 sweep #53). Unmatchable
  by design; krikri's list is the same fixed membership its argspec table captured, and the generator
  masks the list (the `FSTYPE-SET-ORDER` mask in the generator's masks.cr) the same way it masks
  `Valid booleans include:`.
- `-vvv` module-execution mechanics lines are not emulated (`<host> Attempting python interpreter
  discovery.`, `<host> ESTABLISH LOCAL CONNECTION ...`, the `<host> EXEC`/`<host> PUT` shell commands,
  `Using module file ...`, `Pipelining is enabled.`) - krikri has no Python interpreter, no module files
  and no staged tmp dirs, and the commands embed the per-run random `ansible-tmp-<epoch>-<pid>-<random>`
  staging paths. `scripts/output_parity.sh` masks these (and the copy/template action-plugin
  `invocation.module_args` blocks carrying the same random staged paths) from both sides.
- `copy:`/`template:` results at `-vvv` that real dispatches through a *staged Python module* carry an
  `invocation.module_args` block naming that random staged file; krikri's action dispatch produces no
  module invocation block for those (except the deterministic check-mode content-copy shape, which IS
  reproduced). Masked in `scripts/output_parity.sh` - see above.
- A malformed `-e '{...'` JSON argument produces a different error chain:
  real prints a multi-part stderr chain (an inventory-plugin parse
  warning quoting the extra-vars value, "Unable to parse ... as an
  inventory source", the two implicit-localhost warnings, then the
  `[ERROR]:` block with `Origin: <CLI option '-e'>` and a
  `(source not shown: TypeError)` line - Python-internal wording) and
  exits 4; krikri prints a one-line error and exits 1.
- `--version` output: real's block names real's own version, its config
  file, Python paths (`python version = 3.13...`, `jinja version`) and
  the module search paths - facts about real's Python environment that a
  non-Python engine cannot truthfully reproduce. Krikri prints its own
  version block instead.
- `--help` and unknown-option usage text: real's usage/option listing is
  generated from real's own option set (including options krikri does
  not have), and an unknown option is reported as Python argparse's
  `usage: ...` + `ansible-playbook: error: unrecognized arguments: ...`
  with exit code 2; krikri prints its own usage with exit code 1.
  Matching byte-for-byte would mean embedding real's verbatim help text,
  which documents real's options - not krikri's.
- Multi-host task-line ordering: real's per-task result-line order for
  2+ hosts comes out of Python's hash-randomized set iteration and
  fork scheduling (two real runs already disagree byte-for-byte, and a
  single real run mixes orders between tasks); krikri's order is the
  inventory/pattern order. `scripts/cli_output_parity.sh` therefore
  runs its execution cases against single-host play patterns and sorts
  the `hosts (N):` block in `--list-hosts` output on both sides.
- `group_vars/`/`host_vars/` directories adjacent to the PLAYBOOK:
  real 2.19.11 (live-probed with local inline and file inventories)
  does NOT load playbook-dir-adjacent group_vars/host_vars at all -
  only inventory-adjacent ones - while krikri loads both. Playbooks
  relying on playbook-dir group_vars show variables real Ansible leaves
  undefined.
- Degenerate quote-soup task arguments (single-quoted Jinja strings
  with embedded escaped quotes written as YAML quote soup, e.g.
  `msg="{{ 'has \"dq\" and 'sq'' | b64encode }}"`): krikri's YAML/arg
  split keeps the backslashes verbatim where real's splitter unescapes
  them, so both "succeed" with different bytes. Clean quoting (a vars
  entry, or YAML single-quoted) is identical on both engines.
- A broken `with_*` loop source (`with_subelements:` missing its subkey
  term): real fails with the lookup-plugin error and a bare
  `Origin: <unknown>` / `invoke_lookup()` block; krikri's error shape
  differs (the loop degrades to a failed task with the finalization
  chain instead).
- `template:` with an `output_encoding:` written as a YAML list of plain strings
  (`[a, b]`) reports real's `unknown encoding: a,b` instead of real's
  `encode() argument 'encoding' must be str, not _AnsibleTaggedList`: the params
  wire is comma-joined for a list of strings, so that value is indistinguishable
  from the equally plausible STRING `"a,b"` - which real itself reads as a codec
  name. Every other non-string `output_encoding` (int, float, bool, a list with a
  non-string member, a dict, an empty container) matches real exactly, as does
  the falsy fallback to utf-8 and the unknown-codec failure.
- Which wrong-typed string option `include_role`/`import_role` reports when SEVERAL of
  `defaults_from`/`handlers_from`/`tasks_from`/`vars_from` are wrong-typed: real picks one by Python set
  order (the same playbook alternates between runs), so krikri cannot match it. Masked in
  `scripts/output_parity.sh` and the generator; the message text and type still have to match.
- A string-list or dict literal given where real's module crashes on the type, on a param the wire flattens:
  `debconf` with a plain-string-list or dict `value:` (real: `sequence item 3: expected str instance, list
  found`), and the Python `repr` of an all-string list inside `copy`'s `remote_src` missing-source message.
  The params wire comma-joins/JSON-ifies these into text indistinguishable from a plain string, so only
  non-string scalars and lists with a non-string member are reproduced (same class as the `output_encoding`
  entry above). A `debconf` multiselect list mixing strings and ints raises real's order-dependent
  `'<' not supported` TypeError first and is not reproduced either.
- Other `ansible-core` releases may differ in wording or edge cases; 2.19.11 is the reference.

### Differential-fuzz residual leniency between the two Jinja evaluators

- `bin/differential_fuzz` (the seeded ExpressionEvaluator-vs-krikri-jinja
  comparison harness) triaged 20k+ generated expressions against real
  Jinja2 3.1.6 on 2026-09-27; the three triaged disagreement classes
  (lenient answers to invalid Jinja, the undefined-ternary sentinel
  split between the two entry points, lenient out-of-range list
  indexes) were fixed the same day - the fixes live in `git log`, with
  the krikri-jinja engine side in v0.4.20-v0.4.22. What remains is
  deliberate, not defect: two-raw-string and numeric-string-vs-number
  orderings (module stdout values are strings), per-filter argument
  type leniency (`| sum` on strings, `| abs` on a string,
  `| split(dict)`), the unimplemented `%` modulo operator,
  `not (...)` wrapped around an unimplemented inner construct,
  bare-callable attributes (`str.count`), and the engine's lenient
  chain off a lenient undefined for bracket indexing
  (`missing_var[9]` stays the "undefined" sentinel engine-side - that
  chain is the load-bearing shape behind `x | default(other.thing.y)`).
  The residual classes live as tight predicates in
  `src/krikri/differential_fuzz/runner.cr` (`KNOWN_DIFFERENCES`,
  including the one documented predicate hole); the fixed-seed CI
  slice is `test/unit/differential_fuzz_test.cr`.

### Unsafe-data taint is a provenance-closed registry, not an AnsibleUnsafe type

- Real ansible-core marks host-controlled strings with a type
  (`AnsibleUnsafeText`) that survives every operation. krikri instead
  records the hostile TEXTS in a global registry and closes it under
  derivation: the moment a render decision establishes (by resolved
  name, expression provenance, or substring containment) that an
  output was fed by execution data, the transformed output itself is
  registered, so every later re-render refuses it by text. Same
  verdict as the type for every shape tested live against
  ansible-playbook 2.19 - but it is structurally approximate: a NEW
  re-render path must extend the hostile matrix in
  `test/integration/unsafe_data_test.cr`, not be assumed safe.

### `fetch:` refuses a destination that escapes `dest`, stricter than real Ansible

- A `src` whose `..` components carry the composed
  `dest/<host>/<src>` path outside `dest` fails with "Detected directory
  traversal, expected to be contained in ..." instead of writing there.
  Real ansible-core 2.19.11 writes through: its CVE-2019-3828 guard
  (`is_subpath(dest, original_dest)` in `action/fetch.py`) runs before
  the path is composed, so it compares `dest` with itself and never
  fires (verified live). Deliberate: `src` can come from data a managed
  host controls (e.g. `find:` results), and a controller-side write
  outside `dest` is the exact bug that CVE describes. Every non-escaping
  path matches real Ansible byte-for-byte.

### `ansible_version` is pinned to a fixed real ansible-core release, not this project's own version

- `ANSIBLE_VERSION_MAGIC_VAR` reports `2.19.4` regardless of which real
  `ansible-playbook` happens to be installed on the machine running
  krikri (e.g. `2.19.11` was installed when round 979000 flagged
  `xanmanning.k3s`'s version-check task printing a different string than
  the live comparison run). Deliberate: this engine's whole design goal
  is behavioral parity with real Ansible, and every version-gated role
  feature in the wild expects a 2.x-shaped comparison target - reporting
  this project's own sub-1.0 version number here would make every such
  min-version check fail unconditionally, a worse outcome than pinning
  one fixed real version. `2.19.4` matches the exact ansible-core release
  this project's own benchmark rounds compare against (see
  `executor.cr`'s own comment). Not going to drift to match whatever's
  locally installed.

### `aem_design.aem_license`'s `no_log`-vs-fail-hard divergence (round 900000-900999) is a human security judgment call

- A `no_log: true` task masking a license-key value diverges from real
  Ansible in a way that's borderline security-sensitive (whether to
  fail hard vs. silently proceed on a masking edge case) rather than a
  clear-cut behavioral bug. Deliberately left unfixed and un-triaged
  further this round - a human should decide the right behavior here,
  not an automated fix pass.

### Role-private custom `action_plugin`s are not supported (module execution is; action plugins are not)

- Discovered round 91000: the `amtega.*` Galaxy collection (~28 roles
  - `amtega.ansible`, `.apache`, `.cron`, `.docker_engine`, `.java`,
  `.mysql`, `.sshd`, `.sysctl`, and more) all depend on
  `amtega.check_platform`, which ships a role-private
  `action_plugins/_check_platform.py` - a real `ActionBase` subclass
  that runs on the controller with access to `action_loader`,
  `templar`, and `connection` internals to dispatch other actions,
  gather facts, and validate distro/version support against role
  vars. Role-private `library/*.py` custom **modules** already run for
  real here (`PythonModuleRunner`, see the design-reversal note at the
  top of this file) - that mechanism executes a self-contained module
  on the target host via the normal module-execution pipeline. Custom
  **action plugins** are fundamentally different: arbitrary
  controller-side Python with direct access to Ansible's own internal
  plugin-loading/templating/connection APIs, meant to be run inside a
  real `ansible-core` process rather than dispatched to a target.
  Genuinely supporting this would mean either embedding a real Python
  interpreter with access to equivalent internal APIs, or building a
  bespoke internal API surface krikri doesn't have any other use for -
  a large, open-ended surface for a role feature real Ansible itself
  treats as an advanced/rare extension point (most Galaxy roles never
  ship one). Decision: krikri correctly reports the plugin name as an
  unimplemented module rather than silently skipping; a role depending
  on a custom action plugin stays out of scope for now, revisit only
  if a genuinely common role pattern is found to need it (unlikely,
  given `library/*.py` covers the overwhelmingly more common
  custom-module case already).

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
  Out of scope: this engine targets Ubuntu and RHEL-family hosts only.
  - apk is doubly out of reach: Alpine is musl and this engine's plugin
    binaries are glibc-linked, so they cannot execute there at all - the
    upload fails before any module runs. A musl plugin build is the
    prerequisite, not an apk backend.

### Arbitrary Python

- **Role-private custom `lookup_plugins/*.py` lookup plugins run on the
  controller, like the module/filter equivalents** (`PythonLookupRunner`,
  0.9.1038): `lookup('name', ...)`/`query('name', ...)` for a plugin the
  role ships in its own `lookup_plugins/` (or the playbook-adjacent one)
  dispatches to the controller's own python3 and runs the plugin's
  `LookupModule.run(terms, variables, **kwargs)` - a lookup plugin's name
  IS its file name, so no introspection pass is needed. Previously any
  such call silently degraded to "undefined"/`[]`, which collapsed a
  `loop: "{{ query(...) }}"` to zero iterations (seen live via
  manala.environment and manala.accounts). Wired into BOTH templating
  engines separately (the repo's two-evaluator split): the hand-rolled
  `{{ }}` evaluator's lookup dispatch (`evaluate_custom_python_lookup`)
  and the krikri-jinja template side (`krikri_jinja_lookups.cr`, which
  also serves `query()`/`q()`). Every unhelpable case
  (no python3, the `ansible` package not importable by the controller
  python3, no `LookupModule` class in the file) keeps that exact previous
  undefined/`[]` degradation; a plugin that RAN and raised fails the task
  with its own error, like real Ansible. Still cut: third-party
  COLLECTION lookup plugins (the bullet below) - same reason as for
  modules/filters, they live inside installed collections, not in the
  playbook tree the runner can see.
- **Arbitrary-Python-module support is scoped to role-private
  `library/*.py` sources** (plus the playbook-adjacent `library/`): a
  module with a resolvable source now RUNS on the target with the
  target's own python3 through the py_module plugin (0.9.819) - previously skipped with a
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
  exit status a caller sees. The feature's own role-root resolution,
  argument-passing protocol, and task-batching interaction were
  independently broken after 0.9.819 introduced it - fixed, and
  confirmed live
  for a self-contained module (`sr_fingerprint`, no unusual imports).
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

### SELinux security-context relabeling is not implemented

- The `file:`/`copy:`/`template:`/`getent:` family manage Unix mode,
  owner/group and (where `libacl` is present) POSIX ACLs, but not SELinux
  security contexts - krikri carries no `libselinux`/`matchpathcon`
  equivalent and never relabels. On an SELinux-*enforcing* host, real
  Ansible's `file:` can flip `changed` based on a context it would fix up
  even when mode/owner already match, so a mode/owner-only task can
  report a different verdict than krikri. This is the one candidate
  source of the round900902 `juju4.adduser` `~/.ssh` extra-`changed`
  report: every re-check on a non-SELinux host (perfbench container,
  0.9.1277) reproduces real's verdict EXACTLY (`run1 changed=true`,
  `run2 changed=false`), and it has never been reproduced locally with
  SELinux enabled. Left as an accepted scope cut rather than an open
  defect - closing it properly means vendoring a real SELinux policy
  query for a single unreproduced, host-flavored report.

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
  output finalization replicates that exception for the inline case
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
### `replace:` pattern syntax is checked by a targeted Python-re scanner, not a full re._parser port

`ansible.builtin.replace` compiles `regexp:`/`after:`/`before:` with Python's own `re` module, outside
its `except re.error` - so a pattern Python rejects kills the module ("Task failed: Module failed:
<re.error text>"). PCRE2 (krikri's engine) accepts a superset of Python's syntax, so krikri runs a
left-to-right Python-re scanner over each pattern first (plugins/replace.cr, `PythonPattern`) and
translates PCRE2 compile errors to Python's wording/position where the mapping is exact. Covered with
real-verified messages: the PCRE group-name spellings `(?<name>...)`/`(?'name'...)` and every other
extension char Python rejects (`(?R)`, `(?&`, `(?|`, `(?1`, ...), the inline-flag section rules,
PCRE-only escapes (`\e`, `\z`, `\K`, `\h`, `\G`, `\C`, `\c`, `\o`, `\p`, `\Q`, `\x{...}`) with the
class-context rules for `\A`/`\B`/`\Z`/`\g`, and `\uXXXX`/`\Uhhhhhhhh` (Python accepts, PCRE2 does
not - rewritten to PCRE2's `\x{...}`). Deliberately left unchecked (they surface with PCRE2's wording
inside the same crash wrapper, or accept where real rejects, and are too rare in roles to justify a
full re._parser port):

- `\N{...}` character names (real resolves them against the Unicode name DB; PCRE2 rejects the syntax,
  so such patterns fail either way - wording differs, and a *valid* name still fails here);
- `\8`/`\9` group-reference semantics (Python counts groups, PCRE2 errors);
- `(?P=name)` resolution and `(?P<>`-shape name errors;
- Python's semantic inline-flag checks (`(?iLmsxua)`'s "cannot use 'L' flag with a str pattern",
  `a`/`u` negation, global-flags placement);
- character-class ranges over escapes (`[\d-e]`).

The surrogateescape twin for undecodable bytes under `encoding:` is the private-use codepoint
U+F780+(byte-0x80) rather than Python's U+DC80+(byte-0x80), because PCRE2 aborts a match whose subject
holds raw surrogates; one undecodable byte is one character to the regex either way and the byte
round-trips on write. The collision risk is the one real carries itself (a file legitimately
containing the mapped codepoint), just in a different range.

### Cosmetic differences (both engines fail; only the wording differs)

These change no outcome and no recap. Listed so they aren't re-reported
as bugs, not because anyone intends to fix them.

- **A `hostvars[host].<missing>` attribute names the wrong type.** Real
  ansible-core fails with `object of type 'HostVarsVars' has no attribute
  'x'`; krikri fails the same task (and `is defined`/`default()` behave
  the same) but says `object of type 'dict'`, since each host's vars reach
  the template engine as a plain dict.

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
  0.9.822.)
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
