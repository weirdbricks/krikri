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

**Currently at `0.9.539`.** Vendored `crinja` fork now at tag
`crystal-play-0.9.16` (see `shard.yml`).

---

## Real gaps (worth revisiting)

- **Undefined-variable rendering is lenient almost everywhere; real
  Ansible is strict by default for module-arg templating.** 0.9.517
  narrowed this (was previously fully open, see git log for the
  `robertdebock.bios_update` repro that found it): `VarSubstitutor#
  substitute`'s module-arg call site (`#substitute_task_params`, the one
  place that assembles a task's final param hash - also reached by
  `changed_when:`/`failed_when:`) now raises `UndefinedVariableError`
  (caught and converted into a clean failed-task result, matching real
  Ansible's own "Finalization of task args ... failed") when a `{{ }}`
  span's ENTIRE content is a bare variable reference (`foo`, `foo.bar`,
  `foo['bar'][0]` - no filters/operators/function calls) that resolves
  to nothing. Deliberately scoped no further than that: any expression
  using a filter/operator/function call still goes through the lenient
  path regardless, since this hand-rolled evaluator's own known
  syntax-coverage gaps (documented throughout `expression_evaluator.cr`)
  already fall back to the same `"undefined"` sentinel for reasons
  unrelated to the variable genuinely being undefined - conflating the
  two would turn an evaluator limitation into a spurious task failure.
  Also NOT touched: `when:`/plain (non-module-arg) `#substitute` calls,
  and Crinja's own `{% %}` block-tag rendering - all still fully lenient,
  by design (see `ConditionalEvaluator`'s own truthiness handling for
  why `when:` in particular stays permissive). A genuinely undefined
  variable reached through a filter chain, or through `when:`, is still
  an open gap - revisit with a dedicated pass if a live round finds one
  that changes final task-pass/fail state, the same way this one did.

- **Crinja parser can leak a stale `trim_left`/`left_is_block` state
  across a nested block's own end-tag boundary.** Found while verifying
  the explicit-dash whitespace-control fix (round170, `crystal-play-
  0.9.16`): the sibling text immediately AFTER certain nested blocks
  can come back with a spurious `trim_left = true` it never earned from
  an actual adjacent `-` or the implicit `trim_blocks` config, silently
  eating a real newline real Jinja2 keeps. Minimal repro (in the Crinja
  repo, not crystal-ansible): `<div>\n    {% if true -%}\n\n
  yay\n    {% endif %}\n</div>` (the `endif` has NO dash at all) still
  loses the newline before `</div>`. Confirmed pre-existing, not a
  0.9.16 regression. Root cause is in `~/git_work/crinja/src/parser/
  template_parser.cr` - `@trim_left`/`@left_is_block` are shared
  instance variables that likely need saving/restoring around the
  recursive `parse_node_list(true)` call for a tag's own block, the
  same class of fix `parse_fixed_string`'s own reset-after-use already
  applies for the non-nested case. See that fork's own `PATCHES.md`
  (0.9.16 entry) for the full writeup. Not attempted yet - needs its
  own dedicated parser-state trace.

- **A `None`/null Jinja value can render as the literal string `"none"`
  (with a missing preceding newline) instead of an empty string, in a
  specific end-of-template position.** Found round170 verifying the
  whitespace-control fix against `buluma.collectd`'s real
  `collectd.conf.j2`: a bare `{{ collectd_conf_extra }}` (default
  `null`) at the very end of the template, immediately after a `{%
  for %}...{% endfor %}` block and some static text, rendered as
  `none` glued directly onto the preceding line with no newline -
  real Ansible renders it as nothing at all (the blank line stays
  blank). NOT reproducible in isolation (a bare `{{ null_var }}` alone,
  or even the same var referenced via a role's own defaults with a
  trivial one-task role, both correctly render as empty) - only shows
  up in this specific "after a completed for-loop, at true end of a
  large multi-hundred-line template" shape, so likely related to (but
  not confirmed identical to) the Crinja parser leak above rather than
  crystal-ansible's own value-formatting code. Needs a dedicated
  isolated repro built up incrementally from the working one-line case
  toward the full template shape to pin down exactly which construct
  triggers it, before attempting a fix.

- **A LOOPED task whose `when:` raises an exception (e.g. `mounts |
  selectattr(...) | first` on an empty match) shows `skipped=1` in the
  recap instead of real Ansible's `failed=1`.** Fixed in 0.9.539: the
  solo-task case (no `loop:`) now matches real Ansible exactly (`Error
  while evaluating conditional: ...`, `failed=1`, exit 2 - or `ok`/
  `ignored` if `ignore_errors:` is set), and critically the crash this
  used to cause (an unhandled exception killing the whole process,
  regardless of loop:) is gone everywhere. Only the LOOPED case's exact
  recap wording is still off - `execute_looped_task`'s own stats
  aggregation treats every `when_passes? == false` per-item result as
  an ordinary skip, with no way yet to distinguish "this item's when:
  raised" from "this item's when: was false". The real fix needs
  `when_passes?`'s failure path to signal a per-item FAILURE distinctly
  (not just `false`) up through the loop aggregator, which doesn't
  currently have a channel for that. Not attempted - `when_passes?`'s
  own 0.9.539 fix already covers the crash (the important part) and the
  exit code is still correct either way; only the displayed counter
  differs, for this fairly rare combination (a when: that raises AND is
  inside a loop:).

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
