# Known Missing / Known Limits

The goal is 100% behavioral compatibility with `ansible-playbook`, verified against Ansible runs
rather than assumed, for **core (`ansible.builtin`) modules**. A community module explicitly promoted
to supported owes the same bar; a divergence rooted in an **unsupported** one isn't tracked (see
`krikri-role-tester`'s `COMMUNITY_MODULE_MISSING` classification and `SUPPORTED_COMMUNITY_MODULES`).

**Open gaps (defects with an unknown or unfinished fix) live in
[GitHub issues](https://github.com/weirdbricks/krikri/issues)**, not in this file. Fixes close them
with `Fixes #N` in the commit; round narrative lives in `git log` (e.g.
`git log --all --grep=auth_socket`) and per-role status in `ROLES_TESTED.md`.

This file holds **Deliberate limits** (below): decisions already made, with the reasoning attached;
nothing here is waiting on anyone. An item that turns out to be a defect becomes an issue and is
deleted from here.

## Test-suite environment notes

- The Docker plugin tests (`docker_compose_v2`, the `--check` mode Docker end-to-end test) talk to the
  user's podman API socket. If `podman.socket` is "listening" but `/run/user/$UID/podman/podman.sock`
  is missing (seen after a tmpfiles sweep), run `systemctl --user restart podman.socket`.
- One `statvfs` test can flake under parallel workers (passes alone).
- The PostgreSQL live tests need a throwaway **postgres:16** server on port 15432
  (`podman run -d --name krikri-pg16 -p 127.0.0.1:15432:5432 -e POSTGRES_PASSWORD=rootpass
  docker.io/library/postgres:16`).
- `docker_image_build`'s nonexistent-`path` test skips where `docker` is podman's shim.

## Deliberate limits (decided, not defects)

Do not re-litigate without new evidence - and if new evidence turns up, open an issue rather than
arguing with the note in place.

### Fact gathering does not need Python on the target

Real Ansible's `Gathering Facts` fails on a host with no `/usr/bin/env python3` (`The module
interpreter '/usr/bin/env python3' was not found`, recap `failed=1`). krikri's `setup` is a compiled
binary and needs no Python, so it gathers facts and the play proceeds. This is inherent to the
compiled-module design, not a defect; a role then failing later on that host (e.g. a variable only
defined from facts) is the same role-side gap either way.

### No automatic cross-compilation of plugin binaries for a foreign-arch target

krikri's modules are compiled binaries uploaded to the target and exec'd there, so an x86_64
controller managing an aarch64 target (a Raspberry Pi) needs binaries built for aarch64 - real
Ansible ships Python modules and has no equivalent constraint. krikri probes every target's
architecture over its own SSH channel (`uname -m`, folded into the upload path's existing
listing round trip, remembered in the plugin-state cache as `_arch` so warm runs never re-probe)
and then:

- same arch as the controller: the default `plugins/` binaries, exactly as before (unchanged
  path, byte-for-byte);
- different arch, and a `plugins-<arch>/` directory exists next to the `krikri-playbook`
  executable (or `bin/plugins-<arch>/` in the checkout): those binaries are selected, compared
  by md5, and uploaded like any other - one fat-plugin binary per arch dir serves every module
  name, mirroring build.sh's hardlink model;
- different arch, no `plugins-<arch>/` build: the run fails immediately with
  `PluginArchUnsupportedError` naming the missing directory and the remedy, before any
  multi-MB upload of a binary the target's kernel would refuse with exec-format error. The
  host is NOT booked UNREACHABLE (it answered - the controller has nothing runnable for it);
  its first task fails with the same message and the host halts from there.

The deliberate limit: krikri does not cross-compile those binaries for you. Crystal has no
practical turnkey cross-build for this project's plugin set (each plugin links the Crystal
stdlib against target-arch libgc/libyaml/libpcre, so a proper cross toolchain plus per-arch
native libraries would be needed), so the supported flow is: run `./build.sh` on a machine of
the target's architecture (a Pi, an ARM cloud box, an emulated/chroot arm64 environment) and
copy the resulting `bin/plugins/` directory to the controller as
`<krikri-install-dir>/plugins-<arch>/`. Verified live (2026-10-11) against a real sshd target
reporting aarch64 (a `/usr/local/bin/uname` shim inside an ubuntu:22.04 podman container
standing in for the CPU, since this dev box has no qemu-user-static/binfmt registration and
registering binfmt_misc needs root): the per-arch build was selected, uploaded and executed on
the target (remote file md5-identical to `plugins-aarch64/command`, not the default binary),
and the no-build case failed with the actionable message. A genuine foreign-CPU exec was not
exercised - nothing on this machine can execute aarch64 code - but the exec surface itself is
the same code path the same-arch run has always used. Decided 2026-10-11.

### Docker TCP-unreachable wording embeds a Python heap pointer

- A docker module run with `DOCKER_HOST` pointing at a closed TCP port fails with
  `Error connecting: Error while fetching server API version: HTTPConnectionPool(host='...',
  port=N): Max retries exceeded with url: /version (Caused by NewConnectionError('<urllib3.
  connection.HTTPConnection object at 0x7f...>: Failed to establish a new connection: [Errno 111]
  Connection refused'))` - the `object at 0x...` address is a live Python heap pointer, printed
  by real itself. Three runs of real ansible-playbook 2.19.11 against the same closed port
  produced three different addresses (`0x7f0a371d01a0`, `0x7f364e4d41a0`, `0x7fb1ca5c81a0`,
  2026-10-10), and krikri's own rendering (same wording, its `ex.object_id` in place of the
  Python address) varies the same way run to run - the wording, chain shape and errno match;
  only the per-process address differs on BOTH engines, so byte-for-byte comparison of this
  one field is meaningless. (krikri's errno is recovered through a blocking connect re-probe,
  0.9.1611: Crystal's own non-blocking connect surfaces EINPROGRESS without ever reading
  SO_ERROR, so the caught errno was never the verdict real's blocking socket reports.)
  Every other docker failure surface (SDK and CLI) is verified -
  see issue #6. Decided 2026-10-10.

### `password_mechanism=sshpass` is not implemented (askpass is always the fallback)

ansible-core 2.19 defaults `password_mechanism` to `ssh_askpass` and only needs the `sshpass` program when
the option is set to `sshpass` explicitly (without it installed, real fails the host with `to use the
password_mechanism=sshpass, you must install the sshpass program`). krikri has no such option: with a
connection password it uses `sshpass -e` when the program exists and otherwise OpenSSH's `SSH_ASKPASS`
(helper in a fresh 0700 directory, password via `SSHPASS` in the environment only), so a play that sets
`ansible_ssh_password_mechanism: sshpass` without `sshpass` installed succeeds here where real fails.
Decided 2026-10-08: lenient direction, not worth emulating.

### `timedout.frame` deprecation warning is not printed

Real ansible-core 2.19.11 prints a stderr `[DEPRECATION WARNING]: The `timedout.frame` task result key is
deprecated` (with an Origin block) when a registered timed-out result is templated. krikri enforces
`timeout:` and matches the result values and key order but does not emit that warning: stderr only, no
effect on task status or stdout. Decided 2026-10-07: not worth matching.

### Callback-plugin emulation covers exactly two shapes, and errors on everything else

There is no generic callback-plugin architecture. `ANSIBLE_CALLBACKS_ENABLED` recognizes exactly
`ansible.posix.profile_tasks` (plus the legacy short form `profile_tasks`) and
`ANSIBLE_STDOUT_CALLBACK` recognizes exactly `oneline` (plus a no-op `default`, which is what
krikri's hardcoded display already is); every other value is a hard startup error
(`[ERROR]: Could not load 'X' callback plugin.`, rc 1) instead of upstream's behavior. Real 2.19.11
warns-and-SKIPS an unknown `callbacks_enabled` entry (`[WARNING]: Skipping callback plugin 'X',
unable to load`) and fails hard only for an unloadable stdout callback - krikri errors hard for
BOTH, on purpose (product decision, 2026-10-10): a run that silently produces different output
than the callback the user asked for is worse than no run. Consequences of that decision:

- `profile_tasks`' own config surface is not implemented: `PROFILE_TASKS_TASK_OUTPUT_LIMIT` stays
  at the default 20 rows, `PROFILE_TASKS_SORT_ORDER` stays at the default descending, and
  `PROFILE_TASKS_SUMMARY_ONLY` is not honored. The -vv+ per-row `task path:` line under each recap
  row is not rendered either.
- Other aggregate callbacks (`profile_roles`, `profile_json`, `community.general.*` timings) and
  other stdout callbacks (`minimal`, `dense`, `json`, `-t/--tree`) are not implemented and error.
- `ANSIBLE_CALLBACK_WHITELIST` (removed upstream >= 2.12) is deliberately NOT read.

On the oneline side, two scope bounds: -v/-vv/-vvv output is not reshaped by the callback beyond
suppressing the default callback's own artifacts (task banners, `task path:`, NOTIFIED HANDLER
lines) - controller-side verbose output is unchanged - and a task-level error's [ERROR] chain
block collapses to oneline's own `An exception occurred ...` line plus the FAILED! dump, as the
real callback's exception branch does. Also accepted: looped `include_tasks:`/`include_role:`
iterations print one line per iteration under oneline where real prints the whole loop as a
single aggregate (the per-iteration results never reach this engine as one aggregate shape).
Decided 2026-10-10.


### Console-output differences from ansible-core 2.19.11 that cannot be matched

krikri aims for byte-for-byte identical stdout/stderr/exit code to `ansible-playbook`
2.19.11 (checked with `scripts/output_parity.sh` and the per-module
`krikri-playbook-generator`). The known exceptions:

- Python interpreter-discovery warnings (`Host ... is using the discovered Python interpreter ...`):
  krikri has no interpreter to discover.
- Random per real run: temp file/dir names, string-set order (`union`/`intersect`/... on lists of
  strings), and the order of several invalid options in one error message. Integer set order *is*
  reproduced.
- `community.general.filesystem`'s `value of fstype must be one of: ...` is built by real from a
  Python set of strings, so **Python string-hash randomization** reorders it per process -
  unmatchable by design; the generator masks it (`FSTYPE-SET-ORDER` in masks.cr).
- `unarchive`'s "Failed to find handler for ..." message joins the per-handler failure reasons
  (`Command ... could not handle archive`, `Unable to find required ... binary`) from a Python set
  of strings, so **string-hash randomization** reorders them per process (every sample differs,
  even cold vs warm of one round) - unmatchable by design; krikri emits a fixed order
  (issue #255, earlier #112).
- `-vvv` module-execution mechanics lines (`ESTABLISH LOCAL CONNECTION ...`, `EXEC`/`PUT`,
  `Using module file ...`, `Pipelining is enabled.`): no interpreter, module file or staged tmp dir
  exists here, and those lines embed per-run random `ansible-tmp-<epoch>-<pid>-<random>` paths. Masked
  in `scripts/output_parity.sh`.
- `copy:`/`template:` at `-vvv` carry Ansible's `invocation.module_args` block naming its random staged
  Python module file; krikri emits none (the deterministic check-mode content-copy shape IS
  reproduced). Masked in `scripts/output_parity.sh`.
- Malformed `-e '{...'` JSON: Ansible prints a multi-part stderr chain and exits 4; krikri prints one
  line and exits 1.
- `--version`: Ansible's block names Ansible's version, config file and Python paths - facts a non-Python
  engine cannot truthfully reproduce.
- `--help`/unknown option: Ansible's listing comes from its own option set (including options krikri
  lacks) and an unknown option is argparse's `usage: ...` + `error: unrecognized arguments: ...` with
  exit 2; krikri prints its own usage, exit 1. Matching it would mean embedding Ansible's help text.
- Multi-host task-line ordering: Ansible's order for 2+ hosts comes from hash-randomized set iteration
  and fork scheduling (two Ansible runs already disagree byte-for-byte); krikri uses inventory/pattern
  order, so `scripts/cli_output_parity.sh` runs its execution cases against single-host play
  patterns and sorts the `hosts (N):` block in `--list-hosts`.
- `group_vars/`/`host_vars/` adjacent to the PLAYBOOK: Ansible 2.19.11 does NOT load them (only
  inventory-adjacent ones), krikri loads both, so such playbooks see variables real leaves undefined.
- Quote-soup task arguments (single-quoted Jinja with embedded escaped quotes as YAML quote soup):
  krikri's YAML/arg split keeps backslashes verbatim where Ansible's splitter unescapes them, so both
  "succeed" with different bytes; clean quoting is identical.
- Broken `with_*` loop source (`with_subelements:` missing its subkey term): Ansible fails with the
  lookup-plugin error plus a bare `Origin: <unknown>` / `invoke_lookup()` block; krikri degrades the
  loop to a failed task with the finalization chain. (The with_dict-on-None shape left this class in
  round 5410000: it now fails with the dict lookup's own refusal wording, byte-identical.)
- `template:` with `output_encoding:` as a YAML list of plain strings (`[a, b]`) reports Ansible's
  `unknown encoding: a,b` instead of the Python type error: the params wire comma-joins such a list,
  making it indistinguishable from STRING `"a,b"`, which real itself reads as a codec name.
- `include_role`/`import_role` with SEVERAL of `defaults_from`/`handlers_from`/`tasks_from`/
  `vars_from` wrong-typed: real picks which to report by Python set order (the same playbook
  alternates), so krikri cannot match it. Masked in `scripts/output_parity.sh` and the generator;
  message text and type still have to match.
- String-list or dict literal where Ansible's module crashes on the type, on a param the wire flattens:
  `debconf` with a plain-string-list or dict `value:`, and the Python `repr` of an all-string list in
  `copy`'s `remote_src` missing-source message. Only non-string scalars and lists with a non-string
  member are reproduced.
- Python-set iteration order in results: `openssl_csr`/`openssl_certificate` `public_key_fingerprints`
  and `postgresql_privs`'s multi-privilege list come from a Python set/frozenset in real
  (nondeterministic across Ansible runs themselves); krikri keeps the declared order. Other
  `ansible-core` releases may differ; 2.19.11 is the reference.
- `apt:`/`apt_repository:` update-cache retry warnings against a repo with no Release file
  (`webbylab.nginx-proxy`, #220): real's python-apt exception text includes a libapt-only
  `W:Repositories should provide a clear-signed InRelease file...` line the apt CLI never prints, and
  which attempt quotes which lines varies run to run on the same host (two real runs disagreed on
  attempts 1 and 4). The `Sleeping for N seconds` values are random jitter in both engines. Krikri
  reproduces the failure, retry count and final classification but not these bytes.

### Differential-fuzz residual leniency between the two Jinja evaluators

- What remains after triaging `bin/differential_fuzz` is deliberate, not defect: two-raw-string and
  numeric-string-vs-number orderings, per-filter argument type leniency (`| sum`/`| abs` on strings,
  `| split(dict)`), the unimplemented `%` modulo, `not (...)` around an unimplemented inner construct,
  bare-callable attributes (`str.count`), and the lenient chain off a lenient undefined for bracket
  indexing (`missing_var[9]` stays the "undefined" sentinel - the load-bearing shape behind
  `x | default(other.thing.y)`). These live as tight predicates in
  `src/krikri/differential_fuzz/runner.cr` (`KNOWN_DIFFERENCES`); the fixed-seed CI slice is
  `test/unit/differential_fuzz_test.cr`.

### Unsafe-data taint is a provenance-closed registry, not an AnsibleUnsafe type

- Real marks host-controlled strings with a type (`AnsibleUnsafeText`) that survives every
  operation; krikri registers the hostile TEXTS in a global registry closed under derivation -
  once a render decision establishes (by resolved name, expression provenance or substring
  containment) that an output was fed by execution data, the transformed output is registered too,
  so every later re-render refuses it by text. Same verdict as the type for every shape tested,
  but structurally approximate: a NEW re-render path must extend the hostile matrix in
  `test/integration/unsafe_data_test.cr`, not be assumed safe.

### `fetch:` refuses a destination that escapes `dest`, stricter than Ansible

- A `src` whose `..` components carry the composed `dest/<host>/<src>` path outside `dest`
  fails with "Detected directory traversal, expected to be contained in ..." instead of writing
  there. Ansible 2.19.11 writes through: its CVE-2019-3828 traversal guard never fires in this case
  (observed behavior). Deliberate: `src` can come from host-controlled data (e.g. `find:` results) and a
  controller-side write outside `dest` is exactly that CVE. Non-escaping paths match real
  byte-for-byte.

### `ansible_version` is pinned to a fixed ansible-core release, not this project's own version

- `ANSIBLE_VERSION_MAGIC_VAR` reports `2.19.4` regardless of which `ansible-playbook` is
  installed on the machine running krikri. Deliberate: version-gated role features expect a
  2.x-shaped comparison target, and this project's sub-1.0 version would make every such min-version
  check fail unconditionally. It will not drift to match whatever is locally installed.

### `aem_design.aem_license`'s `no_log`-vs-fail-hard divergence is a human security judgment call

- A `no_log: true` task masking a license-key value diverges from Ansible in a way that is
  borderline security-sensitive (fail hard vs. silently proceed on a masking edge case), not a
  clear-cut behavioral bug. Deliberately left unfixed - a human should decide, not an automated pass.

### Role-private custom `action_plugin`s are not supported (module execution is; action plugins are not)

- Found via the `amtega.*` Galaxy collection (~28 roles), which depend on `amtega.check_platform`'s
  role-private `action_plugins/_check_platform.py` - a real `ActionBase` subclass running on the
  controller with access to `action_loader`, `templar` and `connection` internals. Role-private
  `library/*.py` custom **modules** already run here; custom **action plugins** are different in kind -
  controller-side Python reaching into Ansible's own plugin-loading/templating/connection APIs, meant
  to run inside a `ansible-core` process rather than be dispatched to a target.
- Supporting them means either embedding a real Python interpreter with equivalent internal APIs or
  building a bespoke API surface with no other use, for an extension point most Galaxy roles never
  ship. Decision: krikri reports the plugin name as an unimplemented module rather than skipping.

### Unimplemented community.general filter long tail (usage-audited, watchlist not backlog)

- Unimplemented: the dict-key filters (`keep_keys`, `remove_keys`, `replace_keys`, `dict_kv`,
  `groupby_as_dict`), the `lists_*` family (`lists_union`, `lists_difference`, `lists_intersect`,
  `lists_symmetric_difference`), `accumulate`, `counter`, `crc32`, `version_sort`, `random_mac`,
  `unicode_normalize`, `from_csv`, `from_ini`/`to_ini`, `from_toml`/`to_toml`, `json_diff`,
  `json_patch`, `hashids`, `reveal_ansible_type`, the `to_<time-unit>` family and `to_prettytable`.
- They ARE reachable by a role (that is how `lists_mergeby` was found), but a Sourcegraph audit of
  public GitHub YAML showed real usage is almost nil: hits are dominated by the collection's own
  docs/tests and third-party tutorial/vendored copies. The only real-role hits were one `version_sort`,
  one `keep_keys`, one `counter` and zero for `dict_kv`/`groupby_as_dict`/`remove_keys`/`replace_keys`/
  `lists_*`, while the same search for `dict2items` matches hundreds of genuine roles. Decision: none
  go in a backlog on spec; each is implemented on first live hit by a benchmark role.
- **ansible-core builtins** are effectively fully covered - the only absent names are `random`,
  `rejectattr` (deliberately excluded from `KNOWN_FILTER_NAMES`), `groupby`, and the Windows-only
  `win_basename`/`win_dirname`/`win_splitdrive`.

### ansible.netcommon IP filters are implemented even where the Ansible host lacks the collection

- krikri implements the `ansible.netcommon` filter family (`ipaddr`, `network_in_usable`, ...)
  natively, so a role using one renders fine here while `ansible-playbook` on a host without the
  `ansible.netcommon` collection installed fatals with `No filter named 'ansible.netcommon.<filter>'`.
  `jtprogru.hosts` is the precedent: such roles diverge BY DESIGN - the collection gap is on the
  Ansible side, and krikri having the filter is not a defect.

### Init systems and package managers

- **`service:` on an upstart host** - detection covers systemd, OpenRC and SysV (Ansible's own branches,
  in its own precedence order), so such a host is never silently driven as SysV, but upstart itself is
  not implemented: its enable path writes an `/etc/init/<name>.override` whose contents depend on the
  initctl version. Fails with a clear "not supported" rather than guessing.
- **`service_facts:` upstart / chkconfig / OpenRC scans** - systemd and SysV (`service --status-all`)
  are implemented and merged Ansible's way; the other three branches are not. On such a host the systemd
  scan still runs and an empty result is correctly reported *skipped*, not as an empty
  `ansible_facts.services` dict.
- **`package:` backends beyond apt/dnf/yum** - detection uses the same path table and priority as
  `ansible_pkg_mgr`, so the module and the fact a role gates on cannot disagree, but only apt/dnf/yum
  have backends; zypper/pacman/apk/pkgng fail by name ("package manager 'pacman' is not supported by
  this engine"). Out of scope: this engine targets Ubuntu and RHEL-family hosts only. apk is doubly
  out of reach - Alpine is musl and this engine's glibc-linked plugin binaries cannot execute there, so
  the upload fails before any module runs; a musl plugin build is the prerequisite, not an apk backend.

### Arbitrary Python

- **Role-private custom `lookup_plugins/*.py` lookups run on the controller**
  (`PythonLookupRunner`): `lookup('name', ...)`/`query('name', ...)` for a plugin the role ships in
  its own `lookup_plugins/` (or the playbook-adjacent one) dispatches to the controller's own python3
  and runs the plugin's `LookupModule.run(terms, variables, **kwargs)`; a lookup plugin's name IS its
  file name, so no introspection pass is needed. Wired into BOTH templating engines separately: the
  hand-rolled `{{ }}` evaluator's `evaluate_custom_python_lookup` and the krikri-jinja side
  (`krikri_jinja_lookups.cr`, which also serves `query()`/`q()`). Unhelpable cases (no python3,
  `ansible` not importable, no `LookupModule` class) degrade to undefined/`[]`; a plugin that RAN
  and raised fails the task with its own error, like real.
- **Arbitrary-Python-module support is scoped to role-private `library/*.py` sources** (plus the
  playbook-adjacent `library/`): a module with a resolvable source RUNS on the target with the
  target's own python3 through the py_module plugin. Still cut: a module reference with NO library
  source anywhere (parse-time warning, and exit 4 for a reachable one - Ansible's own code for refusing
  a playbook it can't resolve a module for) and every THIRD-PARTY COLLECTION module (next bullet),
  which lives inside installed collections rather than in the playbook tree the runner can see. The
  exit-status half stays divergent for source-less modules: WHICH TASKS RUN differs (Ansible refuses at
  parse time and runs nothing; this engine runs the rest of the play), not the exit status a caller
  sees.
- **Third-party COLLECTION modules and filters, same cut** (e.g. the `bodsch.*` author's
  `bodsch.core`/`bodsch.systemd` collections): Ansible runs these as ordinary Python, so a MODULE
  reference reports "unavailable modules" and skips the task while a FILTER reference fails with
  Ansible's own "No filter named 'x'." rather than silently passing the operand through un-filtered.
  Every `bodsch.*` role calls at least one of these, so that author's roles keep diverging by design.

### SELinux security-context relabeling is not implemented

- The `file:`/`copy:`/`template:`/`getent:` family manage Unix mode, owner/group and (where `libacl`
  is present) POSIX ACLs, but not SELinux contexts - krikri carries no `libselinux`/`matchpathcon`
  equivalent and never relabels. On an SELinux-*enforcing* host, Ansible's `file:` can flip `changed`
  based on a context it would fix up even when mode/owner already match. This is the one candidate
  source of `juju4.adduser`'s `~/.ssh` extra-`changed` report, never reproduced with SELinux enabled.
  Accepted scope cut - closing it means vendoring a real SELinux policy query for a single
  unreproduced, host-flavored report.

### Fact caching

- **Only the `jsonfile` backend** (`src/krikri/fact_cache.cr`): by far the most common real-world
  choice, and the only one worth a from-scratch implementation without a client library to lean on.
  `redis`/`memcached` would need real client libraries this project doesn't carry; the built-in
  `memory` backend needs no support at all (this engine's in-run `@facts` store already IS that).
  Revisit only if a real role needs a non-jsonfile backend.

### Templating

- **A tuple-bearing value stored in a var, then `| string`'d later, renders as a bracketed list
  instead of a parenthesized tuple.** Ansible's native-types finalization converts a Python tuple to a
  list at every rendered-output position EXCEPT when `| string` applies Python's own `str()` first;
  krikri replicates that for the inline case (`{{ d1 | dictsort | string }}`), but a tuple crossing
  INTO a var first (`t1: "{{ (1, 2) }}"`) loses its tuple-ness when stored, since krikri's vars
  world is JSON. Recovering that means carrying a real tuple type through the whole vars pipeline,
  for a shape nothing in the role corpus hits.

### `replace:` pattern syntax is checked by a targeted Python-re scanner, not a full re._parser port

`ansible.builtin.replace` compiles `regexp:`/`after:`/`before:` with Python's own `re`
module, outside its `except re.error` - so a pattern Python rejects kills the module ("Task
failed: Module failed: <re.error text>"). PCRE2 (krikri's engine) accepts a superset of Python's
syntax, so krikri runs a left-to-right Python-re scanner over each pattern first
(`plugins/replace.cr`, `PythonPattern`) and translates PCRE2 compile errors to Python's
wording/position where the mapping is exact.

Covered with real-verified messages: the PCRE group-name spellings `(?<name>...)`/`(?'name'...)`
and every other extension char Python rejects (`(?R)`, `(?&`, `(?|`, `(?1`, ...), the inline-flag
section rules, PCRE-only escapes (`\e`, `\z`, `\K`, `\h`, `\G`, `\C`, `\c`, `\o`, `\p`, `\Q`,
`\x{...}`) with the class-context rules for `\A`/`\B`/`\Z`/`\g`, and `\uXXXX`/`\Uhhhhhhhh` (Python
accepts, PCRE2 does not - rewritten to `\x{...}`).

Deliberately left unchecked (they surface with PCRE2's wording inside the same crash wrapper, or
accept where Ansible rejects): `\N{...}` character names; `\8`/`\9` group-reference semantics; `(?P=name)`
resolution and `(?P<>`-shape name errors; Python's semantic inline-flag checks (`(?iLmsxua)`'s
"cannot use 'L' flag with a str pattern", `a`/`u` negation, global-flags placement);
character-class ranges over escapes (`[\d-e]`).

The surrogateescape twin for undecodable bytes under `encoding:` is the private-use codepoint
U+F780+(byte-0x80) rather than Python's U+DC80+(byte-0x80), because PCRE2 aborts a match whose
subject holds raw surrogates; one undecodable byte is one character to the regex either way and the
byte round-trips on write. The collision risk is the one real carries itself, just in a different
range.

### Cosmetic differences (both engines fail; only the wording differs)

These change no outcome and no recap. Listed so they aren't re-reported as bugs, not
because anyone intends to fix them.

- **A `hostvars[host].<missing>` attribute names the wrong type.** Ansible fails with
  `object of type 'HostVarsVars' has no attribute 'x'`; krikri fails the same task (and
  `is defined`/`default()` behave the same) but says `object of type 'dict'`, since each
  host's vars reach the template engine as a plain dict.
- **`version_compare` was removed in ansible-core 2.19**: a role using that filter fails on
  both engines (the role is broken against 2.19 either way), only the wording differs -
  Ansible's `No filter named 'version_compare' found.` vs krikri's
  `unknown filter "version_compare"`.
- **An erroring task NAME prints an inline marker instead of Ansible's warning.** When a task's
  `name:` itself fails to template (e.g. it reads an undefined `_latest_release.json`), Ansible emits
  `[WARNING]: Encountered 1 template error` and the task runs on; krikri runs it too but renders an
  inline `<< error ... >>` banner marker in the task header instead of the warning line. No outcome or
  recap changes (found via `coopdevs.backups_role`).

### Test-environment notes: output that is nondeterministic by nature

- **`samba-tool` stderr differs on every run (`uspdev.sambadc`).** A failed `samba-tool domain
  provision` embeds python log timestamps, pids, ASLR-randomised stack-frame addresses and a random
  "first record" in the LDB repack lines in its JSON `stderr`. Two runs of real Ansible differ from
  each other the same way, so `krikri-role-tester` masks these in `Compare::MASKS`
  (`samba-log-timestamp`, `samba-pid`, `samba-stack-address`, `samba-repack-record`). Not a krikri
  gap; the Samba 4.15 token-stack panic itself reproduces identically on both engines.

- **Host-key fingerprints and `stat` timestamps differ per host (`HomeSecExplorer.sshaudit`).** The
  role regenerates SSH host keys, so the `ssh-audit` `(fin) ssh-ed25519/ssh-rsa: SHA256:...` lines
  echoed by its results `debug` loop are random on every host, and the `with_items` dump of
  `find`/`stat` results for the removed host keys carries `atime`/`mtime`/`ctime` of the moment they
  were created. The ansible and krikri runs are on different hosts, so these values cannot match;
  the structure around them (item repr, `__hsesa_sshaudit_out` var dump) does. Not a krikri gap.

- **Mounting tmpfs over `/tmp` kills real Ansible's own module run (`hannseman.raspbian`).** Ansible
  unpacks each AnsiballZ payload into `/tmp/ansible_<module>_payload_*`; `mount:` of a tmpfs on `/tmp`
  hides that directory mid-run, so ansible-core fails with "Module result deserialization failed" and
  stops the play (exit 2), leaving every later task unapplied (warm run then shows `changed` where
  krikri shows `ok`). krikri's plugins are standalone binaries with no payload in `/tmp`, so the mount
  succeeds and the play continues. An artifact of Ansible's execution model, not a krikri gap.

### Everything else

- **`ansible-playbook`'s CLI flag surface is fully covered by name, and all but one flag is
  behavioral.** `--help` lists every flag ansible-core 2.19.4 does, including its own long
  aliases (`--inventory-file`, `--vault-pass-file`).
  * `-M`/`--module-path` is accepted and ignored, a scope cut rather than an oversight: real searches
    those directories for PYTHON modules while every module here is a compiled binary, and faking it
    would silently look for a same-named compiled binary in a directory of `.py` files this can never
    execute.
  * `--scp-extra-args` extends the scp command lines in `SSHManager#upload_file`/`#download_file`,
    alongside `--ssh-common-args` (which real applies to scp as well - only `--ssh-extra-args` is
    ssh-only). `PluginManager` also falls back to scp for the plugin-binary push when rsync is missing.
  * `--sftp-extra-args` is accepted and inert (nothing here ever invokes `sftp`); `--flush-cache` is
    correct (facts live only in a run-scoped store, so no on-disk cache exists).
  * Short forms match Ansible: `-C` is `--check`, `-D` is `--diff`, `-c` is `--connection`.
    **`-c` previously meant `--check` in this engine and no longer does**, a deliberate breaking change
    so a copied command line behaves the same here. `-d` is kept as an extra alias for `--diff`.
- Cloud provider modules: only a narrow AWS/EC2 slice is implemented - `amazon.aws` `ec2_instance`,
  `ec2_key`, `ec2_security_group`, `ec2_ami_info`, `ec2_vpc_net_info`, `ec2_vpc_subnet_info`,
  `ec2_metadata_facts` and `iam_user_info` (a hand-built SigV4 API client, `plugin_helpers/ec2_api.cr`;
  none can be exercised against a real account by the test rounds, see below) - plus the `aws_ec2`
  inventory plugin. Everything else (`community.aws`, other `amazon.aws` modules, `azure_rm_*`,
  `google.cloud`, `openstack.cloud`, `community.vmware`) is not implemented and not planned: each
  needs a real per-provider API client with request signing/auth, not "another module that shells
  out to a CLI tool". Revisit only if a specific need justifies it.
- YAML-defined inventory plugins (`plugin:` sources): `host_list`, `ini`, `yaml`, `constructed` and
  `amazon.aws.aws_ec2` are implemented via `src/krikri/inventory_plugins.cr`; aws_ec2 talks to the real
  EC2 API with SigV4 through the vendored `awscr-signer` shard, credentials from the standard `AWS_*`
  environment variables. Deliberate approximations: default `hostnames` order is `ip-address`,
  `private-ip-address`, `instance-id`; constructed `filters` are AND-combined `key=value` / bare-key /
  `*` / `!`-negation entries, not Ansible's richer condition syntax; keyed_groups with a dict value make
  one group per key; a non-empty group-name prefix defeats `leading_separator: false`. Other collection
  inventory plugins (azure, gcp, openstack, ...) are unimplemented and follow the cloud modules' rule.
- More of the same "genuinely unimplemented plugin, referenced only in a task this platform never
  actually reaches" class - same root cause each time (this engine's eager parse-time module check
  counts a reference regardless of a gating `when:`, matching real, but the local comparison side has
  the collection installed and never hits the check): `zypper` (`weareinteractive.docker` - SUSE-only)
  and `community.general.clustering.consul.consul_acl` (`mrlesmithjr.consul` - also showing the "WHICH
  TASKS RUN differs" side: Ansible refuses at parse time with zero tasks run, this engine runs the whole
  play first before the same rc=4 - covered by the role-private-custom-modules entry above).
- The legacy free-form `action: "<templated module name> key=val ..."` syntax is implemented (free-form
  string, its `{module: ..., args: {...}}` dict form, and a runtime-templated module name via
  `TaskExecutor#resolve_templated_action`); `weareinteractive.users_oh_my_zsh`'s shape is covered by
  `playbook_parser.cr`'s `ACTION_DIRECTIVE_KEYS` branch.
- `docker_*`'s `api_version:` pin - not implemented, not planned: `docr` uses unversioned endpoint URLs
  throughout, and they negotiate fine against current Docker/Podman.
- `meta:` - every action in Ansible's `meta` choices list is supported (`clear_facts`, `flush_handlers`,
  `end_host`, `end_play`, `clear_host_errors`, `noop`, `refresh_inventory`, `end_batch`, `end_role`,
  `reset_connection`), each matched to Ansible's observed behavior. Non-obvious ones: `end_play` and
  `clear_host_errors` are genuinely GLOBAL (every currently-active / every-failed host, even one whose
  `when:` skipped the meta task), while `end_host` is per-host only; `clear_host_errors` exempts a host
  from later plays and from the run's exit code but does NOT resume it in the CURRENT play;
  `refresh_inventory` re-reads a dynamic script's output in place but does NOT add newly-discovered
  hosts to the CURRENT play's host loop, only a LATER play's; `end_batch` behaves like `end_play` while
  `serial:` batching isn't modeled.
- `config`/`inventory_hostnames` lookups are implemented; `inventory_hostnames` needed no inventory
  plumbing - Ansible's plugin builds its throwaway InventoryManager purely from `variables['groups']` and
  runs the standard host-pattern machinery over THAT (`ExpressionEvaluator#lookup_inventory_hostnames`,
  spec in `inventory_hostnames_lookup_spec.cr`); `groups` also gained its missing `ungrouped` key.
  Known shared limitation: a wantlist/query list result renders `["a","b"]` in debug msg where real
  prints Python's `['a', 'b']` repr.
- `win_*` filters - Windows-only, irrelevant to this project's targets.
- `community.crypto`'s remaining modules. Implemented: `openssl_dhparam`, `openssh_keypair`,
  `openssl_privatekey`, `openssl_csr`, `openssl_pkcs12` (`action: export`/`parse`), `x509_certificate`
  (providers `selfsigned` and `ownca`) and the info/read-only half (`openssl_privatekey_info`,
  `x509_certificate_info`, `openssl_csr_info`, `openssl_publickey`, `openssl_publickey_info`,
  `get_certificate`) - what the role corpus touching this collection calls. Built on the `openssl` CLI
  rather than the `dirless/x509-crystal` shard, which has no CSR-based issuance. Still unimplemented,
  none seen in a role yet: `luks_device`, the `acme`/`entrust` providers, `openssl_pkcs12` export's
  `encryption_level: compatibility2022`, and the CRL/revocation family - all fail with a clear "not
  supported" message.
- `community.general.vdo` - unimplemented; untestable so far, no real role sets a non-empty
  `vdo_devices`.
- `gluster.gluster.gluster_volume` - unimplemented; causes a cosmetic parse-time task-drop vs. Ansible's
  "skipping" recap line, not a runtime crash.
- `community.general.zypper_repository` - unimplemented; same cosmetic parse-time-drop class, no
  zypper/openSUSE host ever tested.
- `community.general.homebrew`/`homebrew_tap` - unimplemented; reachable in practice via the
  linuxbrew roles (`ctorgalson.linuxbrew`, `markosamuli.linuxbrew`), which then diverge by design:
  krikri skips those tasks, ansible runs them (and the Linux brew path fails on this hardware
  anyway - Homebrew's x86_64 build needs an SSSE3 CPU).
- `ansible.posix.firewalld` - `zone:` defaults to the system default zone (`firewall-offline-cmd
  --get-default-zone`) and Ansible's `permanent`/`immediate`/`offline` validation is matched to Ansible's observed behavior, so
  `offline: true, permanent: true` isn't required explicitly. A running firewalld daemon (auto-detected
  via `firewall-cmd --state`) plus a requested or defaulted `immediate:` change is serviced through
  `firewall-cmd` (the D-Bus client CLI), and a `target:` operation in the immediate context fails with
  the Ansible module's "Zone operations must be permanent..." rather than being silently serviced offline.
  Still unimplemented: bare defaults against a host with no firewalld daemon.

## Plugin key-order probe coverage

`PluginResult#key_order` (or an omit-`changed` wire) pins a plugin's keys to Ansible 2.19.11's order. Probes: `testing/keyorder_probes/kop_*` roles, run via `krikri-role-tester run` with `local:` queue entries and compared by `krikri-role-tester keyorder` (`--values` for values, not just shapes). Add to this list when another module family is probed.

### Verified

- `kop_snap`, `kop_iptables`, `kop_apt_fail` (rounds 1100100+): `snap`, `iptables`, `apt` real-mutation/failure shapes.
- `kop_docker_build`, `kop_docker_invalidrepo` (rounds 1600100/1800100, 5331000): `docker_image_build` buildx gate, CLI image lookup, both resolve_repository_name refusals (`http://foo`, `registry.example.com-/thing`), on a real docker.io 26.1.3 + buildx host, byte-identical cold and warm. The refusals escape the module body uncaught and register as `msg: "Task failed: Module failed: <raw text>"` with keys failed/changed/exception/msg.
- Docker plugins: API failures, container start failures, daemon-unreachable wording (SDK and CLI modules) and `docker_network` `ipam_config` verified against community.docker 5.2.1 on a podman socket. TCP-unreachable wording is a deliberate limit (see above).

### Not a gap to close

- `homebrew*`, `ovirt_auth`/`redhat_subscription`/`rhsm_*` (macOS-first, or need a live oVirt engine / Red Hat entitlement; well under 2% of roles).
- `ec2_*`, `iam_user_info`, `nsupdate`, `rabbitmq_*` (need an external account or appliance neither engine can reach).
- Host noise (apt/dnf output text, per-host keys/UUIDs, snap revisions, mount/systemd dependency ordering) is not a krikri difference.

---

For the fixed-bug history (150+ rounds of real-host benchmarking against production
Ansible roles), see `git log`.
