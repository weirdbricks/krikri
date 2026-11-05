# Upgrade plan: parity target ansible-core 2.19.11 → 2.21.6

Status: **profile mechanism dropped — single target**. Decision (2026-11-05):
krikri tracks ansible-core **2.21.6 only**; the `--krikri-argspec-profile`
knob and the 2.19/2.20 alternate snapshots are removed, and
`data/argspecs.json` IS the 2.21.6 capture. The 2.19.11 behavior remains
only in the repo's history and in test comments describing provenance.

## Current state (as of 0.9.2404)

- `ANSIBLE_TARGET_VERSION = "2.19.11"` in `src/krikri/version.cr:9` — also
  the value of the `ansible_version` magic variable.
- `data/argspecs.json` — argspec snapshot captured from 2.19.11; drives
  module-arg validation AND `invocation.module_args` echoing
  (`src/krikri/argspec_validator.cr`, embedded at compile time).
- `data/argspecs_220.json` — 2.20.1 snapshot, selectable via
  `--krikri-argspec-profile=2.20` (added for #910). Default profile is
  still `2.19`.
- krikri-role-tester compares byte-for-byte against a real
  `ansible-playbook` — the controller it installs must match the parity
  target or every round lights up with version-skew noise.
- Known snapshot staleness (unrelated to the upgrade, do NOT "fix" as part
  of it): the committed 2.19 snapshot's `find` `patterns` default is `['*']`
  (2.18-era capture); a fresh 2.19.11 regen says `[]`, same as 2.20/2.21.
  Also `data/argspec_print_names.json` is missing the sysvinit probe entry
  until the next full regen.

## Measured argspec delta 2.19.11 → 2.21.6 (small — 14 changed modules)

Verified by generating a snapshot from ansible-core 2.21.6 on 2026-11-05
(`/tmp/argspecs_221.json`):

| Module | Change |
|---|---|
| `ansible.builtin.stat` | `+get_selinux_context` (bool, default false) |
| `ansible.builtin.blockinfile` | `+encoding` (str, default utf-8) |
| `ansible.builtin.lineinfile` | `+encoding` (str, default utf-8) |
| `ansible.builtin.deb822_repository` | `+exclude`, `+include`, `+install_python_debian` |
| `ansible.builtin.dnf5` | `-install_repoquery` |
| `ansible.builtin.yum_repository` | `-keepcache` |
| `ansible.builtin.slurp` | `+armor` |
| `ansible.builtin.find` | `patterns` default `['*']` → `[]` |
| `ansible.builtin.git` | `gpg_allowlist` entry changed |
| `ansible.builtin.pip` | `mutually_exclusive` gains `['editable', 'requirements']` |
| `ansible.builtin.user` | `required_if` gains `['append', True, ['groups']]` |
| `community.general.cpanm` | `+install_recommendations`, `+install_suggestions`, `+version`, `mode` changed |
| `community.general.filesystem` | `fstype` choices changed |
| `community.general.xml` | `-create_if_missing` |
| `ansible.builtin.homebrew` | new module entry (redirect now resolves) |

Plus 16 entries that fail to resolve on the *current host* (collections
emptied since the 2.19 snapshot was generated: amazon.aws ×7,
community.mysql ×5, community.rabbitmq ×2, containers.podman ×1) — overlay
those verbatim from the 2.19 snapshot at merge time, like the 2.20
snapshot did.

## Phase 0 findings (live-verified vs real 2.21.6)

- **`INJECT_INVOCATION` defaults to false in 2.21** (ansible-core config
  `INJECT_INVOCATION`, version_added 2.21; `AnsibleModule._return_formatted`
  pops `invocation` when unset; the action layer sets
  `_ansible_inject_invocation` from `ansible_inject_invocation` /
  `ANSIBLE_INJECT_INVOCATION` / `defaults.inject_invocation`). Real 2.21.6
  module results carry NO `invocation` key by default - verified with the
  #909 repro playbook: `r.results[0].invocation` errors under real 2.21.6.
  krikri still always emits `invocation` today, so this is now the
  **largest known divergence** and the top work item:
  - [ ] Gate krikri's invocation echo behind the same knob (default OFF):
        parse `defaults.inject_invocation` from ansible.cfg, the
        `ANSIBLE_INJECT_INVOCATION` env var, and the
        `ansible_inject_invocation` var, in ansible's precedence order.
  - [ ] When OFF: every result path that attaches
        `invocation.module_args` (plugins' echoes, action plugins,
        python_module_runner, getent-style manual assembly) must omit it.
  - [ ] When ON: the echo must match 2.21.6's (verified byte-identical
        with `ANSIBLE_INJECT_INVOCATION=1` for stat + find).
  - [ ] Re-triage: with injection OFF by default, many existing pinned
        invocation-echo tests need re-scoping to the ON case.
- **find echoes `patterns: ["*"]` despite the spec default `[]`**: find.py's
  module body rewrites `params['patterns']` before `exit_json`, and
  `_return_formatted` injects the mutated params. argspecs.json's find
  `patterns` default is pinned to `["*"]` (matching the echo), same pin the
  2.19 snapshot carried.
- stat's unsupported-params message under 2.21.6 advertises
  `get_selinux_context` (captured live; test updated).

The argspec surface is therefore NOT the risky part. The risk is behavior
deltas outside the spec tables (below).

## Done already (mechanical swap, one commit)

- [x] `data/argspecs.json` replaced with the 2.21.6 capture (16 host-drift
      entries overlaid from the old 2.19 snapshot; `homebrew` appended);
      `data/argspecs_220.json` deleted.
- [x] `argspec_validator.cr`: profile machinery removed, single embedded
      table again.
- [x] `krikri-playbook.cr`: `--krikri-argspec-profile` removed.
- [x] `version.cr`: `ANSIBLE_TARGET_VERSION = "2.21.6"` (also feeds the
      `__version__` handed to py_module runner probes).
- [x] `executor.cr`: `ANSIBLE_VERSION_MAGIC_VAR` now reports 2.21.6
      (ansible's own dict order kept; live-verified vs 2.21.6).
- [x] Tests updated: `invocation_args_test.cr` (stat echoes
      `get_selinux_context: false` by default now),
      `argspec_validation_test.cr` (stat typo message re-captured from a
      real 2.21.6 run — it now advertises `get_selinux_context`),
      `ansible_version_test.cr` (magic var 2.21.6).
- [x] README compat-target row → 2.21.6.

## Phase 0 — Recon (before further code changes)

- [ ] Read the ansible-core 2.20 and 2.21 porting guides end to end and
      list every behavior change that could affect krikri's hand-rolled
      mirrors: templating/resolution, conditionals, callback output
      shapes, module return shapes, deprecation messages, `ansible_version`
      magic var, error message wording. Record findings as a sub-checklist
      here (one bullet per confirmed difference + which krikri file mirrors
      it).
      - Known 2.20+ area to check specifically: the new templating engine
        continued evolving after 2.19's Data Tagging rewrite; krikri's
        hand-rolled evaluator + krikri-jinja target 2.19 semantics.
- [ ] Diff 2.19.11 → 2.21.6 for each plugin krikri implements natively
      (`plugins/*.cr` mirroring real module code): stat, copy, file,
      lineinfile, blockinfile, template, get_url, user, git, pip, slurp,
      find, package/dnf/yum family, service/sysvinit, uri, archive...
      - Method: for each, diff the module source between the 2.19.11
        checkout and 2.21.6 (`/tmp/ans221/lib/python3*/site-packages/ansible/modules/...`
        vs `/usr/lib/python3/dist-packages/ansible/modules/...`) and note
        anything that changes returned keys, msg wording, changed-detection,
        or check-mode behavior.
- [ ] Decide the `ansible_version` magic var policy: keep reporting 2.19.11
      (profile-independent, safest) vs. track the active profile. **Default
      proposal: track the profile** (report 2.21.6 under the 2.21 profile)
      since a 2.21-parity run should behave like a 2.21 controller — but
      version-comparison conditionals in playbooks (`ansible_version` is
      version-comparable) must then be tested for both profiles.

## Phase 1 — Snapshot + gen tooling

- [ ] Parameterize `scripts/gen_argspecs.py`: `--dist <site-packages>` and
      `--out <path>` CLI args (currently hardcoded globals; today's
      snapshot was made with sed-patched copies — see #910 work). Add
      `--skip-probe` already exists.
- [ ] Generate `data/argspecs_221.json` from a clean venv pinned to
      ansible-core 2.21.6:
      ```
      python3 -m venv --system-site-packages /tmp/ans221
      /tmp/ans221/bin/pip install ansible-core==2.21.6
      python3 scripts/gen_argspecs.py --dist /tmp/ans221/lib/python3.X/site-packages \
          --out data/argspecs_221.json
      ```
- [ ] Overlay the 16 host-drift entries (list above) verbatim from
      `data/argspecs.json`; keep 2.19 key order, append `homebrew`.
- [ ] Re-run the print-names probe against 2.21.6 and decide whether
      print names diverge; if not, share `argspec_print_names.json`
      across profiles (they live inside the snapshot's `print` keys
      today — confirm the shared probe file isn't version-sensitive).
- [ ] Sanity-diff the new snapshot against `argspecs_220.json`: the
      2.20→2.21 delta should be a strict subset of the table above.

## Phase 2 — Code changes

- [ ] `argspec_validator.cr`: accept `"2.21"` in `profile=`; embed
      `argspecs_221.json`; make the **default profile `2.21`** (the 2.19
      and 2.20 profiles stay selectable for A/B comparison and for
      reproducing old rounds).
      - Note the embedded-size cost: three ~180KB JSON blobs compiled
        into every binary that includes the validator. If that matters
        for plugin/daemon startup, consider demoting 2.20 (keep 2.19 +
        2.21) — decide during Phase 4 measurement, don't pre-optimize.
- [ ] `krikri-playbook.cr`: extend the flag's choices/validation to 2.21
      and flip the default; update `--help` text.
- [ ] `version.cr`: `ANSIBLE_TARGET_VERSION = "2.21.6"` (and the
      `--version` "Targets ansible-core" line follows automatically).
      Implement the Phase-0 `ansible_version` decision here.
- [ ] Sweep the codebase for hardcoded `2.19` behaviors that the porting
      guides say changed (output wording, defaults, deprecation gates).
      Each confirmed change = its own fix, not bundled.
- [ ] Plugin-side behavior fixes from the Phase-0 module diffs, one
      logical fix per commit, VERSION bump each (repo convention).

## Phase 3 — Tests

- [ ] Update profile-pinned tests: `test/unit/invocation_args_test.cr`
      (default-profile assertions — `get_selinux_context` ABSENT test
      becomes 2.19-profile-scoped; add 2.21 default assertions),
      `test/unit/argspec_validation_test.cr` (stat typo test asserts the
      2.19 profile's rejection).
- [ ] New tests for each behavior delta found in Phase 0/2, mirroring
      real 2.21.6 behavior.
- [ ] `serial!` discipline for any test touching the profile class var.
- [ ] Full suite: `scripts/minitest.sh` (8 workers). Live docker cases if
      docker-touching code changed: `KRIKRI_DOCKER_TESTS=1`.
- [ ] `./build.sh` + `ameba` clean.

## Phase 4 — Live verification

- [ ] Re-run the #909/#910 repro playbook against a real 2.21.6
      controller (`/tmp/ans221/bin/ansible-playbook`) and krikri default
      profile — must be byte-identical.
- [ ] Ask the user to run a krikri-role-tester batch (`--release` build,
      new commit) with the controller pinned to ansible-core 2.21.6, plus
      a re-run queue of previously-clean roles (copy from
      `ROLES_TESTED.md` / old `queue.txt`). Triage with `triage-round`.
- [ ] Spot-check the known 2.20-era fixes still behave under 2.21 (e.g.
      #908's warnings-module handling).

## Phase 5 — Docs + bookkeeping (one commit at the end)

- [ ] `README.md`: compat-target row + version badge.
- [ ] `KNOWN_MISSING.md`: retire anything 2.21 makes moot; add any new
      deliberate limits the upgrade forces.
- [ ] `ROLES_TESTED.md`: new round rows with timings; note the controller
      version change per row (the table records engine build + round
      context — 2.21 rounds must be distinguishable from 2.19 rounds).
- [ ] Close/reference GitHub issues filed against 2.19-specific behavior
      with the upgrade commit; open issues for confirmed-but-unfixed
      2.21 divergences found in the round.
- [ ] VERSION bump per repo convention (final consolidated bump).

## Risk register

| Risk | Mitigation |
|---|---|
| Templating semantics moved again in 2.20/2.21 (Data Tagging follow-ups) — hand-rolled evaluator and krikri-jinja both affected | Phase 0 porting-guide pass + a dedicated template-semantics probe playbook run against real 2.21.6 before committing to the flip |
| `INJECT_INVOCATION=false` default (2.21) changes every module result | See Phase 0 findings — implement the knob before trusting any round comparison |
| Role-tester comparisons need controller version = parity target; batches against the wrong controller produce pure noise | krikri-role-tester pins/records the controller version in `versions.txt` — verify it installs 2.21.6 before the batch |
| Host collection drift contaminates the snapshot (16 missing entries today) | Overlay policy (Phase 1); consider restoring those collections first so the capture is genuine |
| Embedded snapshot count grows binary size | Measure in Phase 4; demote 2.20 profile if needed |
| Scope creep: "upgrade everything" is open-ended | This doc's rule: argspec + verified behavior deltas only; anything else becomes a tracked GitHub issue, not an unfixed silent gap |
