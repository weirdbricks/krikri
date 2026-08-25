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

**Currently at `0.9.578`.** Vendored `crinja` fork now at tag
`crystal-play-0.9.17` (see `shard.yml`).

---

## Real gaps (worth revisiting)

Note: the round171 `buluma.gitlab` "`package:`/`dnf:` can't resolve a
name-version partial-NEVRA spec" entry that used to be here (`Error:
Unable to find a match: gitlab-ce-19.2.0`) did NOT reproduce on a
dedicated, isolated repro (2026-08-23): a fresh Rocky 9.6 host with the
real `packages.gitlab.com` GitLab CE repo added, both bare `dnf install
-y gitlab-ce-19.2.0` (plain CLI, no release/arch) and this engine's own
`package:`/`dnf:` modules (0.9.549) all resolved and installed
`gitlab-ce-19.2.0-ce.0.el9.x86_64` correctly, cold AND warm-idempotent.
The bare-CLI test alone already disproves the entry's own "library API
more lenient than the CLI verb" theory - plain `dnf install
gitlab-ce-19.2.0` resolves a name-version partial NEVRA fine in
general. Whatever round171 actually hit was either specific to that
one host/moment (a corrupted/partial local metadata cache, a
mid-transaction repo state, etc. - `dnf`'s own error for a genuinely
unresolvable spec doesn't distinguish these from "no such NEVRA
exists") or has since been fixed as a side effect of unrelated
package.cr/dnf.cr work between 0.9.4xx and 0.9.549 - not confirmed
either way. Revisit only if a live round hits this again, this time
capturing `dnf --debuglevel=10 install -y <spec>` output and the exact
package/repo before the host is destroyed, rather than reconstructing
from a recap diff after the fact.

Note: 0.9.474's entry here claiming `openssl_dhparam:`/
`openssh_keypair:` had "no plugin, no `AVAILABLE_PLUGINS` entry" was
itself wrong; both had been implemented, if more simply, since
`0.9.121`/`0.9.125`. 0.9.475 upgraded both to more fully match their
real modules regardless - see `git log`.

- **`ansible-playbook`'s CLI flag surface is now fully covered by name
  (0.9.565), but four flags are accepted-and-inert and two short forms
  differ.** `--help` lists every flag real ansible-core 2.19.4 does.
  What is NOT fully behavioral:

  * `-M`/`--module-path` and `--vault-id` are accepted and ignored.
    Module path is meaningless here (modules are compiled binaries
    shipped with the engine, not a Python search path), and only a
    single vault password is supported, so a vault identity has nothing
    to select.
  * `--scp-extra-args`/`--sftp-extra-args` are accepted and stored but
    have nothing to attach to: this engine moves files over `ssh` plus a
    piped stream rather than shelling out to scp/sftp.
    `--ssh-common-args`/`--ssh-extra-args` DO take effect.
  * `--flush-cache` is accepted and correct-by-construction: facts live
    only in a run-scoped store, so there is no on-disk cache to
    invalidate.
  * Short forms match real Ansible as of `0.9.566`: `-C` is `--check`,
    `-D` is `--diff`, `-c` is `--connection`. **`-c` previously meant
    `--check` in this engine and no longer does** - a breaking change,
    made deliberately so a command line copied from `ansible-playbook`
    behaves the same here. `-d` is kept as an extra alias for `--diff`
    (real Ansible has no `-d`, so it collides with nothing).

- **`ansible_distribution` is the os-release ID, capitalized, not real
  Ansible's per-distro display name.** On LMDE 7 real Ansible reports
  `Linux Mint Debian Edition` where this reports `Linuxmint` (both agree
  on `ansible_os_family: Debian` since 0.9.572, and on
  `ansible_distribution_version`). Real Ansible carries a per-distro
  naming table plus distro-specific files (`/etc/linuxmint/info` and
  friends) to produce those display strings; reproducing it for every
  derivative is not justified by anything a role actually gates on -
  roles overwhelmingly branch on `ansible_os_family`, and on
  `ansible_distribution` only for the mainstream names this already
  matches (Ubuntu, Debian, CentOS, RedHat, Fedora, Rocky, AlmaLinux).
  Revisit if a real role is found branching on a derivative's display
  name.

- **Several keywords are still unimplemented and silently ignored:
  `gather_subset:`, `remote_user:` (as a
  play/task keyword - the `-u` CLI flag and `ansible_user` DO work),
  `vars_prompt:` and `debugger:`.** Found in the same scan
  that produced 0.9.571's `serial:` and 0.9.573's `any_errors_fatal:`/
  `max_fail_percentage:` - those two were fixed because ignoring them
  changes whether a bad rollout STOPS. The remaining three do not:
  `throttle:` caps how many hosts run a task at once (a performance and
  load control - this engine already serializes far more than real
  Ansible does by default), `order:` picks the host ordering
  (inventory/sorted/reverse_sorted/shuffle - affects sequence, not
  outcome), and `gather_subset:` narrows which facts are collected (a
  gathering-time optimization; this engine gathers a fixed set). Each is
  accepted and ignored rather than rejected, so a playbook using one
  still runs - it simply does not get the ordering/limiting it asked
  for. Worth implementing if a benchmark round finds a role whose
  behavior actually depends on one. The later additions to this list
  come from the same zero-implementation sweep: `ignore_unreachable:` (per-task tolerance for an
  unreachable host, now that 0.9.570 made unreachable a real outcome),
  `vars_prompt:` (interactive, so of little use to an automated run) and
  `debugger:` (an interactive debugger this engine has no equivalent
  of). `no_log:` was on this list until 0.9.574 - it was fixed rather
  than documented because ignoring it LEAKS SECRETS, and
  `module_defaults:` until 0.9.575 - including its ACTION GROUP keys
  (`group/aws`) in 0.9.576, which read each installed collection's own
  `meta/runtime.yml` exactly as real Ansible does. One residual
  difference there follows from this engine's flat module namespace
  (FQCN and short names are the same module, by design): real Ansible
  scopes a group's members to the collection that defined them, so
  `group/some.coll.grp` containing `debug` applies to
  `some.coll.debug` and NOT to `ansible.builtin.debug`, while here it
  applies to `debug`. There is no separate `some.coll.debug` module in
  this engine for it to mean anything else.

- **Under the default `linear` strategy, a task's per-host result lines
  are printed in HOST order, where real Ansible prints them in
  COMPLETION order.** With two hosts and one of them slow, real Ansible
  reports the fast host first; this engine reports them in inventory
  order once the task has finished everywhere. That is deliberate: the
  parallel path buffers each host's output so concurrent hosts' progress
  lines can never interleave into an unreadable mess. Recap, exit code
  and every result are identical - only the order of two adjacent lines
  differs. `strategy: free` (0.9.578) does interleave, matching real
  Ansible exactly, because there the ordering IS the observable
  behavior.

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
