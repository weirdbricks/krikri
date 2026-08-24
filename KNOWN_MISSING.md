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

**Currently at `0.9.549`.** Vendored `crinja` fork now at tag
`crystal-play-0.9.17` (see `shard.yml`).

---

## Real gaps (worth revisiting)

- **Undefined-variable rendering is lenient almost everywhere; real
  Ansible is strict by default for module-arg templating and `when:`.**
  0.9.517 raised `VarSubstitutor::UndefinedVariableError` for a bare
  module-arg reference; 0.9.548 (round172's `buluma.git_tag` repro,
  Rocky 9.6 - `when: git_remote != '' and git_remote != None` with
  `git_remote` genuinely undefined) closed the matching gap for
  **task-level `when:`**: `ConditionalEvaluator.evaluate`'s new
  `raise_undefined:` flag (passed only from `Executor#when_passes?`,
  which already converts any raised exception into a clean failed-task
  result via `WhenEvaluationError`) raises
  `ConditionalEvaluator::UndefinedVariableError` when evaluation reaches
  a bare/dotted variable reference that resolves to nothing - same
  narrow REGEX_BARE_VAR_REF-shaped scope as 0.9.517, verified
  byte-identical against real `ansible-playbook`'s own error message,
  `failed=1`, and exit code 2. A filter/function chain (`| default(...)`,
  `lookup(...)`, any `is <test>`) still falls back to the lenient
  `"undefined"` sentinel regardless, for the same reason 0.9.517 didn't
  touch those either.

  **Still NOT covered** (0.9.548 only wired `raise_undefined:` into the
  single task-level `when_passes?` call site, which is exception-safe
  by construction): `block:`/`include_tasks:`'s own multi-host
  `partition_by_when`, `execute_block`'s single-host `when:`,
  `run_include_tasks_once`/`run_include_role_once`, and
  `execute_handler_plugin_once`'s handler `when:` - none of these five
  call sites currently rescue an exception out of
  `ConditionalEvaluator.evaluate` at all, so passing `raise_undefined:
  true` there today would resurrect the exact "crashes the whole
  process" regression 0.9.539 fixed for the main path, not fail cleanly.
  Revisit by giving each its own `WhenEvaluationError`-shaped rescue (or
  routing them through `when_passes?` itself) if a live round finds a
  genuinely-undefined variable inside a `block:`/`include_tasks:`/
  `include_role:`/handler `when:` that changes final task-pass/fail
  state, the same way round172 did for the plain-task case.

- **`package:`/`dnf:` install may fail to resolve a `name-version`
  partial-NEVRA spec real Ansible's own dnf module resolves fine.**
  Found live benchmarking round171's `buluma.gitlab` on Rocky 9.6: its
  own `Install gitlab` task installs `"gitlab-ce-19.2.0"` (name-version,
  no release/arch) from a repo added earlier in the SAME play. Real
  `ansible-playbook` (via python-dnf's native bindings, not the `dnf`
  CLI) installed it successfully; this engine's `package.cr`/`dnf.cr`
  (which shell out to plain `dnf install -y <spec>`) failed with `Error:
  Unable to find a match: gitlab-ce-19.2.0` - reproduced identically on
  a COLD run and again on a WARM rerun of the same host over 15+ minutes
  later (rules out a repo-metadata-freshness race - the failure is
  deterministic, not a timing flake). Likely cause: the real dnf
  *library* API's NEVRA-partial matching is more lenient than what the
  bare `dnf install` *CLI* verb accepts for a name-version-only spec
  with no release/arch component - not yet confirmed by direct
  reproduction against a real dnf CLI outside Ansible entirely (the
  round171 host pair was destroyed before this could be isolated
  further). Revisit with a dedicated, cheaper repro (a minimal playbook
  installing a real name-version-pinned RPM from a small test repo,
  not the full `buluma.gitlab` role) rather than guessing a fix from
  this one observation.

- **A task-level `import_role:`/`import_tasks:` that hits the
  fact-in-static-import restriction (see 0.9.549 below) still only
  fails that ONE task, not the whole playbook at true parse time.**
  0.9.549 fixed the exact round172 `buluma.php_versions` repro (a
  templated `import_tasks:` path used via a top-level `roles:` list,
  parsed eagerly before any execution starts) to raise
  `StaticImportUndefinedError` and abort the whole playbook load,
  matching real Ansible's `rc=4`/zero-tasks-run exactly. The SAME
  detection now also fires correctly for `import_role:`/`import_tasks:`
  reached dynamically (a task-level `import_role:` mid-play) - verified
  directly: the error message is byte-identical to real Ansible's - but
  because this engine's `include_role:`/`import_role:` share one
  runtime-loading code path (`Executor#run_include_role_once` ->
  `RoleLoader.load_single_role`, a documented pragmatic approximation,
  see `Task#is_static_import`'s own comment), the raise there is caught
  by that call site's generic `rescue ex` and turned into an ordinary
  failed-task result instead of propagating to abort the whole run.
  Verified live: real Ansible refuses to run ANYTHING (rc=4, "before"
  task never even reached); this engine now runs "Gathering Facts" and
  any earlier tasks first, then fails the `import_role:` task itself
  with the correct message (`failed=1`) - the right diagnosis, wrong
  blast radius. Revisit only if a live round finds a role where tasks
  BEFORE the static import having already run (vs. real Ansible's
  nothing-runs-at-all) changes observable end state beyond the task
  list itself (e.g. a side-effecting earlier task, file writes,
  notifications) - unlikely, since a real role hitting this restriction
  at all is already a broken role by real Ansible's own rules.

Note: 0.9.474's entry here claiming `openssl_dhparam:`/
`openssh_keypair:` had "no plugin, no `AVAILABLE_PLUGINS` entry" was
itself wrong; both had been implemented, if more simply, since
`0.9.121`/`0.9.125`. 0.9.475 upgraded both to more fully match their
real modules regardless - see `git log`.

## Explicit scope cuts (not gaps to fix - documented so they aren't re-litigated)

- Cloud provider modules (`amazon.aws`/`community.aws` - `ec2_instance`,
  `s3_object`, IAM, security groups, etc.), `azure_rm_*`, and dynamic
  cloud inventory *plugins* (`aws_ec2.yml` et al.) - not implemented,
  not planned. These are a fundamentally different kind of module (HTTP
  calls to a cloud API from the controller, needing real request
  signing/auth, not shell commands run on a managed target) - a real
  API client built from scratch, not "another module that shells out to
  a CLI tool" like everything implemented so far. Revisit only if a
  specific real-world need justifies the investment.
- Role-private custom modules (a role's own `library/*.py`, outside the
  `ansible.builtin`/`community.*`/etc. plugin set this engine ships as
  native binaries) - there's no generic arbitrary-Python-module runner,
  so these can't execute at all. The task is skipped with a
  parse-time warning ("Plugin not available: <name>") rather than
  crashing the run, but anything downstream depending on its result
  sees an undefined value, which can cascade into broader task-status
  divergence for roles that lean on this (seen repeatedly benchmarking
  `linux-system-roles`: `sr_fingerprint`, `timesync_provider`,
  `kernel_settings_get_config`, `blivet`).
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
