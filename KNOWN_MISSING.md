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

**Currently at `0.9.603`.** Vendored `crinja` fork now at tag
`crystal-play-0.9.17` (see `shard.yml`).

---

## Real gaps (worth revisiting)

The five entries that used to be here - the nested-undefined chain
(`0.9.599`), `notify:` validation timing (`0.9.600`), the
`ansible_distribution` display name, the `debugger:` assignment
commands, and `--scp-extra-args` (`0.9.601`) - are all fixed; see
`git log`. The three below were found while verifying those, on
ansible-core 2.19.4, and are NOT fixed.

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

- **`buluma.httpd`'s "Configure httpd" rewrites its config on every real
  Ansible warm run and not on this engine's.** Same round-183
  comparison; both engines otherwise agree task for task on that
  playbook prefix. Unconfirmed whether this is the scoping difference
  above showing up in `httpd_config_src`/`httpd_config_dest`, or
  something separate - it was not chased once the entry it came from
  turned out to be role-side churn. This engine reporting FEWER changes
  is the less dangerous direction, but it is still a divergence.

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
- `community.crypto.x509_certificate` / real CA issuance - a full,
  correct X.509 CA implementation is out of scope for a single module;
  blocks `robertdebock.ca` specifically. Note (0.9.475): the sibling
  `dirless/x509-crystal` shard already does self-signed/CA-signed X.509
  cert generation (ECDSA/RSA) via direct `LibCrypto` bindings - the
  expensive part of this scope cut - so a future attempt at this module
  should start there rather than from scratch, though it's not a
  drop-in (still needs CSR-based issuance from arbitrary subject/SAN
  fields, `state=absent`, revocation, etc. that shard doesn't expose).
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
