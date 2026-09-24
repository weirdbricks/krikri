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

**Currently at `0.9.1269`.**

## Open gaps

- **Round 811000-812999: `k8s` missing module** (`dymurray.
  memcached_operator_role`; real ansible-playbook doesn't complete
  cleanly on the one role that hits it either, low value).
- **Round 700000-701129 + 702000-702046 requeue: 26 single-role missing
  modules** (400-role Galaxy top-download batch, ubuntu+rocky, plus the
  47-role kata-recovery requeue): `os_nova_flavor`, `os_keypair`,
  `os_image_info`, `os_security_group`, `os_keystone_domain`,
  `cloudflare_dns`, `cloudformation`, `mongodb_user`,
  `elasticsearch_plugin`, `acme_certificate`, `postgresql_ext`,
  `flatpak_remote`, `jenkins_script`, `kubevirt.core.kubevirt_vm`,
  `win_shell`, `win_file`, `ansible.windows.win_command`,
  `community.general.apk` (2 roles), `community.general.zypper`,
  `community.general.zypper_repository`,
  `community.general.dnf_config_manager`,
  `community.general.homebrew_cask`, `community.general.launchd`,
  `community.general.dconf`, `community.general.portage` - genuinely
  missing, one role each unless noted. See `ROLES_TESTED.md` for the
  exact affected role per module.
- **Round 700000-701129: `xanmanning.helm` - cosmetic message-only gap,
  not a behavioral divergence.** Re-confirmed live (round 820008): both
  engines fail the SAME task (`Ensure helm_projects_dir exists`) with the
  SAME error class (a strict-conditional-type error - a bare `when:
  helm_projects_dir` truthy-string check under ansible-core's strict
  conditional typing). krikri's message just omits the `at
  '<file>:line:col>'` source-location suffix real Ansible appends when the
  offending value originated from a role default rather than the task
  itself - cosmetic text-diff only, not a different outcome (recap counts
  identical). Left as-is; not worth the source-location-tracking
  architecture for one cosmetic suffix.
- **47-role kata-recovery requeue (round 702000-702046): 47 BOOT_FAILED
  roles from the original ubuntu batch (round 700113-700197), all pure
  Kata infra flakiness** - re-run via Atlantic.net and now reflected in
  `ROLES_TESTED.md` under their final (mostly CLEAN) status. Not a
  krikri gap; noted here only because it's what triggered the Kata
  backend's retirement from `krikri-role-tester` (see `CLAUDE.md`).

- **Low-priority single-role missing modules** (round 601000-601999,
  2026-09-11 batch, one role each unless noted): `docker_volume`,
  `docker_stack`, `community.docker.docker_volume` (2 roles),
  `community.mysql.mysql_replication` (3 roles combined bare+FQCN),
  `community.postgresql.postgresql_membership`,
  `community.rabbitmq.rabbitmq_vhost`, `community.zabbix.zabbix_group`,
  `community.vmware.vsphere_file` (2 roles) - genuinely missing, niche,
  not implemented. `pacman`, `apk`, `community.general.zypper`, `snap` -
  same "is this in scope" alt-package-manager question already open for
  portage/pkgng above. See `ROLES_TESTED.md` for the exact affected role
  per module.
- **Scope question, not yet decided** (2026-09-10/11 batches): `bigip_wait`
  (F5 BIG-IP network-appliance family - `f5devcentral.backup_config`,
  `.bigip_gslb`, `.bigip_onboard`, `.f5app_services_package`),
  `cloudformation` (AWS orchestration - 4 `sansible.aws_*` roles),
  `os_client_config` (`oasis_roles.molecule_openstack_ci`),
  `openstack.cloud.volume_snapshot` (`ome.openstack_volume_storage`) - all
  unimplemented; whether cloud-provider/vendor-appliance orchestration
  modules are in scope for a host-management engine hasn't been decided
  either way.
- **Low-priority single-role missing modules** (2026-09-10/11 batches, one
  role each unless noted): `slack`, `postgresql_ext`, `portage` (Gentoo -
  likely the same package-manager scope question as zypper/pacman),
  `pkgng` (FreeBSD - same question), `ovirt_host_info`, `nuage_vspk` (2
  roles), `manala_files_attributes` (role-private custom module),
  `lxc_container`, `logentries` (deprecated vendor service),
  `k8s` (real ansible-playbook doesn't complete cleanly on the one role
  that hits it either, low value), `django_manage`,
  `community.grafana.grafana_datasource`, `community.general.nmcli`,
  `community.general.cpanm`, `community.docker.docker_container_info`,
  `ansible.windows.win_command` (`riemers.gitlab-runner`, Windows-only).
  See `ROLES_TESTED.md` for the exact affected role per module.

The abandoned 120-role shortlist (`testing/kata/round_new_authors/`,
only 35 roles run before the round was left mid-triage) still has 85
roles never run. The shortlist is at
`testing/kata/round_new_authors/shortlist120.txt` if resuming it -
against Atlantic.net now, Kata having been retired as a backend.


## Deliberate limits (decided, not defects)

Everything here is a decision someone already made, with the reasoning
attached. Nothing here is waiting on anyone. Do not re-litigate without
new evidence - and if new evidence turns up, move the entry to "Open
gaps" rather than arguing with the note in place.

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

### The controller binary still links libxml2.so.2 (via the crinja fork's striptags filter)

- As of 0.9.1281 the remote story is fixed: every XML-consuming module
  (community.general.xml included, rewritten onto the clean-room
  krikri-xml shard with a DOM mutation API, XPath namespace maps and
  libxml2-shaped serialization) no longer touches libxml2, so the fat
  plugin binary uploaded to target hosts no longer links
  `libxml2.so.2` - remote hosts no longer need it at all.
- The remaining link is controller-side only: the vendored crinja
  fork's `striptags` filter uses stdlib `XML.parse_html` (libxml2's
  HTML parser). It lives in the crinja shard (weirdbricks/crinja), not
  this repo, and fixing it means a pure-Crystal HTML-stripping
  implementation plus a fork tag bump. The controller (where krikri
  itself runs) always has Python-level tooling available anyway, so
  this is a much weaker constraint than the old remote requirement.

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
  and the Crinja `.j2`-template side, which additionally had NO
  `query()`/`q()` Jinja global at all before (a template calling
  `query()` failed with "no function with name"). Every unhelpable case
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

### getent's `service:` only ever resolves through the local files backend

- Real `ansible.builtin.getent`'s `service:` param passes `-s <service>`
  to the getent binary, restricting the lookup to one NSS backend (e.g.
  `service: files` to bypass LDAP/SSSD and read /etc/passwd directly).
  krikri's getent plugin reads the local database files directly instead
  of forking getent, so it IS the files backend: `service:` is accepted
  and any value returns the files-backed data. For `service: files` -
  the overwhelmingly common role usage - this is exactly right. A
  request for a genuinely remote backend (`ldap`, `sss`, ...) returns
  local files data where real Ansible on a non-LDAP host would return
  not-found; emulating arbitrary NSS backends is out of scope (it would
  mean running getent or an NSS resolver). Decided in the 0.9.990
  param-coverage audit of getent, live-verified against real
  ansible-playbook 2.19.4 (`service: files` byte-identical facts).

---

For the fixed-bug history (150+ rounds of real-host benchmarking against
production Ansible roles), see `git log`.
