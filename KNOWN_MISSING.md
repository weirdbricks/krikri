# Known Missing / Known Gaps

The goal is 100% behavioral compatibility with `ansible-playbook`, verified against Ansible runs
rather than assumed, for **core (`ansible.builtin`) modules**. A community module explicitly promoted
to supported owes the same bar; a divergence rooted in an **unsupported** one isn't tracked here (see
`krikri-role-tester`'s `COMMUNITY_MODULE_MISSING` classification and `SUPPORTED_COMMUNITY_MODULES`).

This file tracks what's missing **today** - no implementation history, per-round narrative or
root-cause analysis, which live in `git log` (e.g. `git log --all --grep=auth_socket`). When an item
gets fixed, delete its bullet; the fixing commit is the record.

**Open gaps** is defects with an unknown or unfinished fix. **Deliberate limits** is decisions already
made, with the reasoning attached; nothing there is waiting on anyone. An item that stops being a
defect moves down or gets deleted.

**Currently at `0.9.1495`.**

## Open gaps

- **Registered-result key order: what is verified and what is not.** `PluginResult#key_order` (or an
  omit-`changed` wire) pins a plugin's keys to Ansible 2.19.11's order. Probes: the
  `testing/keyorder_probes/kop_*` roles, run through `krikri-role-tester run` with `local:` queue
  entries and compared by `krikri-role-tester keyorder` (`--values` for values, not just shapes).
  - Not verified: `snap` (snapd too heavy for a probe round); `iptables`'s real-mutation variants.
  - Not a gap to close: `homebrew*` and `ovirt_auth`/`redhat_subscription`/`rhsm_*` (macOS-first, or
    needing a live oVirt engine / Red Hat entitlement, together well under 2% of roles) and `ec2_*`,
    `iam_user_info`, `nsupdate`, `rabbitmq_*` (need an external account or appliance neither engine
    can reach).
  - One known value difference left as is: `apt`'s failure results on the mutating paths, matched to
    Ansible's command construction and wording but never verified end-to-end on a real host. Host noise
    (apt/dnf output text, per-host keys/UUIDs, snap revisions, mount/systemd dependency ordering) is
    not a krikri difference.
- **PostgreSQL:** the deprecated aliases (`port`, `host`, `login`, `unix_socket`, `db`) register
  Ansible's deprecation, connection-failure results use libpq's own wording (byte-identical, including
  every `getaddrinfo` failure code), and `postgresql_query` without a database name warns like real.
  Still different: a server that accepts and immediately closes the connection. Real prints `server
  closed the connection unexpectedly ...`; krikri flaps between `Connection refused ...` (RST lands on
  `connect()`; `connect_strerror` hardcodes that text for every `Socket::ConnectError`, masking
  ECONNRESET/EHOSTUNREACH/ENETUNREACH) and Crystal's raw `read (#<TCPSocket:0x...>): Connection reset by
  peer`. crystal-pg has no connect timeout, so libpq's `timeout expired` is unreachable. The live tests
  on port 15432 need a **postgres:16** server.
- **Docker plugins:** API failures (`docker_container`/`docker_image` pulls, `docker_network`,
  `docker_login`, `docker_image_build`) render Ansible's Python-SDK wording, verified byte-for-byte
  against community.docker 5.2.1 on a podman socket for pull, network-create and login failures. Still
  different: `docker_container` does not report container *start* failures (real: `Error starting
  container <id>: <SDK text>` on e.g. a port conflict); daemon-unreachable wording (real: `Error
  connecting: Error while fetching server API version: ...`) differs in every module; `docker_network`
  has no `ipam_config`. `docker_image_build`'s SDK-error path could not be provoked (podman has no
  buildx, real fails at its own probe first), so that wording is aligned but unverified live.
- **Performance, profile first** (`--timing-profile`, warm run, `--forks 1`): not yet done and not worth
  starting without a profile showing the bucket - `ip` forks per interface in `gather_network_facts`
  (`ip -j` shape must be pinned against real output) and the Python-interpreter spawn in
  `gather_python_facts` (`type`/`has_sslcontext` need it); the vars-hash dup in
  `VarSubstitutor#ensure_owned!` and the second substitutor in `JinjaRenderer#jinja_resolver`;
  `ConditionalEvaluator` re-parsing and fully converting the vars hash per call instead of caching a
  compiled condition; `ENV` re-converted on every jinja render; the daemon path parsing then
  re-serializing the plugin config; a local daemon for `ansible_connection=local` (one fork per task
  today). Short-circuit `and`/`or`, unknown-test failure and strict-undefined must survive any change.

## Deliberate limits (decided, not defects)

Do not re-litigate without new evidence - and if new evidence turns up, move the entry to
"Open gaps" rather than arguing with the note in place.

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
  loop to a failed task with the finalization chain.
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
- Cloud provider modules (`amazon.aws`/`community.aws`, `azure_rm_*`) - not implemented, not planned:
  controller-side HTTP calls to a cloud API needing real request signing/auth, i.e. a real API client
  built from scratch, not "another module that shells out to a CLI tool". Revisit only if a specific
  need justifies it. (The inventory half of this is implemented; see below.)
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
- `ansible.posix.firewalld` - `zone:` defaults to the system default zone (`firewall-offline-cmd
  --get-default-zone`) and Ansible's `permanent`/`immediate`/`offline` validation is matched to Ansible's observed behavior, so
  `offline: true, permanent: true` isn't required explicitly. A running firewalld daemon (auto-detected
  via `firewall-cmd --state`) plus a requested or defaulted `immediate:` change is serviced through
  `firewall-cmd` (the D-Bus client CLI), and a `target:` operation in the immediate context fails with
  the Ansible module's "Zone operations must be permanent..." rather than being silently serviced offline.
  Still unimplemented: bare defaults against a host with no firewalld daemon.

---

For the fixed-bug history (150+ rounds of real-host benchmarking against production
Ansible roles), see `git log`.
