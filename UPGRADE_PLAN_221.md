# Upgrade plan: parity target ansible-core 2.19.11 → 2.21.6

Status: **plugin source-diff pass complete at 0.9.2430 — pending live verification**.
Decision (2026-11-05): krikri tracks ansible-core **2.21.6 only** — the
`--krikri-argspec-profile` knob proposed earlier was dropped before it
shipped; `data/argspecs.json` IS the 2.21.6 capture, and
`ANSIBLE_TARGET_VERSION` / the `ansible_version` magic variable report
2.21.6. The 2.19.11 behavior survives only in repo history and in test
comments describing provenance.

Branch: `crush/ansible-221-upgrade` (worktree
`/home/labros/git_work/krikri-worktrees/ansible-221-upgrade`).

## Done

- [x] **Mechanical swap** (`a29f6ef30`): `data/argspecs.json` replaced with
      the ansible-core 2.21.6 capture (16 entries whose collections no
      longer resolve on this host overlaid verbatim from the old 2.19
      snapshot; `ansible.builtin.homebrew` appended); profile machinery
      removed from `argspec_validator.cr` and `krikri-playbook.cr`;
      `version.cr` + magic var → 2.21.6; stat/lineinfile unsupported-
      parameter messages re-captured from real 2.21.6 runs.
- [x] **INJECT_INVOCATION=false default** (`febe7655c`): 2.21 module
      results carry no `invocation` key unless the setting is enabled.
      krikri resolves the same knob per task (`ansible_inject_invocation`
      var > `ANSIBLE_INJECT_INVOCATION` env > off; the ansible.cfg ini
      tier stays unsupported like every other config-backed setting —
      krikri has no INI parsing). Echo build gated at `attach_invocation`;
      native plugins' own echoes and real Python modules' kwargs shed the
      key when off; the register strip only applies while off (2.21
      relaxed it for solo results when on; looped top-level aggregates
      never carry one). Byte-verified on/off × solo/looped vs real 2.21.6.
      Known deviations (deliberate):
      - a custom Python module on a target WITH ansible-core installed
        runs against the target's real basic.py (pre-shim behavior kept),
        which rejects the `_ansible_inject_invocation` wire key — so the
        flag is only sent on the shim path, and a custom module's result
        carries no controller-injected echo even with the setting on.
        Real 2.21 is immune (AnsiballZ bundles the controller's
        basic.py); making krikri always-bundle is a separate
        architectural change.
      - the `ansible_inject_invocation` VAR tier is honored where
        vars_context exists (the attach sites); a var-only override on a
        solo register still gets the top-level strip (27 register_result
        call sites, most without vars in scope).
- [x] **Registered result shape rework** (`32c93d9c0` + follow-ups): 2.21
      rebuilds every result on the UnifiedTaskResult dataclass. krikri
      normalizes at the single register choke point (ResultShape):
      declared-field lead (changed, failed, unreachable, skipped,
      ansible_facts, exception, finished, msg, rc), the skip-reason body,
      the when-verdict pairs + attempts/retries band, a loop item's
      wrapper keys ahead of the module payload, then the module's own keys
      in their prior relative order. Live-verified across
      stat/file/copy/getent/command/fail/raw/debug/set_fact, solo +
      looped, ok/failed/skipped/suppressed. Behavior deltas fixed along
      the way:
      - changed/failed backfilled on EVERY registered result (2.19 left
        when:-skips without `failed`); `skipped` exported only when true;
        the empty-loop aggregate carries both `skip_reason` and
        `skipped_reason`.
      - command/shell adopt 2.21's module key order (stdout, stderr, cmd,
        then the derived lines) and the reworded non-zero-rc msg
        ("The command exited with a non-zero return code." — raw.py kept
        the 2.19 wording, discriminated by an explicit raw-dispatch
        marker).
      - the controller exception placeholder "(traceback unavailable)"
        belongs only to actually-failed results; suppressed ones carry
        `failed_when_suppressed_exception` (synthesized for fail_json
        results that never had an exception to move).
      - until/retries: attempts key from the attempt loop (non-looped
        until tasks keep it too — live-verified; the debug-module until
        case where real 2.21 shows no attempts is a known
        micro-divergence), and 2.21 dropped the exception from
        until-exhausted loop items.
- [x] **Native-scalar param finalization** (`10b0f8308`): a str-typed
      option carrying a native YAML bool literal finalizes through Python
      str() ("True"/"False") — krikri's demotion shipped the lowercase
      YAML spelling and, e.g., executed the `false` binary where 2.21
      executes a literally-named "False" (rc 2 ENOENT). An explicit null
      command source reaches run_command as None →
      `TypeError("Argument 'args' to run_command must be list or
      string")`, rc 257, cmd kept null, no stdout/stderr keys. A null
      debug msg (literal or templated) drops the msg key from the
      registered dict. Templated vars already rendered Python-style; only
      the literal demotion was wrong.
- [x] **Test sweep**: ~130 assertions across the key-order/shape suites
      re-scoped to the 2.21 shapes; echo-machinery specs run with
      `ANSIBLE_INJECT_INVOCATION=1`; default-off shapes pinned by updated
      specs. Full suite green at 0.9.2408.

## Measured argspec delta 2.19.11 → 2.21.6 (small — 14 changed modules)

| Module | Change |
|---|---|
| `ansible.builtin.stat` | `+get_selinux_context` (bool, default false) |
| `ansible.builtin.blockinfile` | `+encoding` (str, default utf-8) |
| `ansible.builtin.lineinfile` | `+encoding` (str, default utf-8) |
| `ansible.builtin.deb822_repository` | `+exclude`, `+include`, `+install_python_debian` |
| `ansible.builtin.dnf5` | `-install_repoquery` |
| `ansible.builtin.yum_repository` | `-keepcache` |
| `ansible.builtin.slurp` | `+armor` |
| `ansible.builtin.find` | spec default `patterns` `['*']` → `[]` (echo stays `["*"]` — the module rewrites params before exit_json; pinned) |
| `ansible.builtin.git` | `gpg_allowlist` entry changed |
| `ansible.builtin.pip` | `mutually_exclusive` gains `['editable', 'requirements']` |
| `ansible.builtin.user` | `required_if` gains `['append', True, ['groups']]` |
| `community.general.cpanm` | `+install_recommendations`, `+install_suggestions`, `+version`, `mode` changed |
| `community.general.filesystem` | `fstype` choices changed |
| `community.general.xml` | `-create_if_missing` |
| `ansible.builtin.homebrew` | new module entry (redirect now resolves) |

The argspec surface was NOT the risky part — the behavior deltas above
were, and they are done.

## Remaining work

- [x] **Per-plugin module source diffs** (2.19.11 → 2.21.6): swept all
      36 natively-implemented modules whose `.py` differs between the two
      releases (diff `/tmp/ans221/lib/python3*/site-packages/ansible/modules`
      vs `/usr/lib/python3/dist-packages/ansible/modules`). Fixed in 0.9.2409
      - 0.9.2430:
      - `install_repoquery` dropped from yum/dnf/dnf5/package (2.21 removed
        it from the shared spec).
      - `getent`: empty `split:` fails with 2.21's wording.
      - `tempfile`: `prefix:`/`suffix:` must be single name components.
      - `slurp`: `armor` (2.21's new param) implemented, incl. the
        controller-deserializer failure on non-UTF-8 content.
      - `stat`/`find`: `disk_usage_bytes` (2.21); find drops
        block_size/device_type and keeps blocks/disk_usage_bytes last.
      - `stat`: `get_selinux_context` (2.21's new param).
      - `file`: EACCES-as-absent warning; warnings ride the result.
      - `known_hosts`: hashed-host mismatch carries the lookup's rc/stderr.
      - `apt`: recreate a missing apt lists cache before any branch.
      - `copy`: `directory_mode:` now applies to a pre-existing
        `remote_src:` dest root.
      - `git`: " HEAD" checkout-failure wording, `track_submodules`
        compares each submodule against its configured branch, and a
        sha-looking `version:` is validated with a dry-run fetch.
      - `user`: result `groups` is the account's real membership, `seuser`
        on a non-SELinux host warns instead of failing, placeholder homes
        (`/nonexistent`, `/dev/null`, `/var/empty`) are not created, and
        2.21's append-requires-groups `required_if` is pinned.
      - `get_url`/`uri` (+ new `PluginHelpers::UrlMask`): credentials in a
        `url:` are masked in every echoed field/message; `uri` now also
        uses URL userinfo as basic auth and strips it from the reported
        URL, and derives `redirected` from the masked URL like real.
      - `lineinfile`/`blockinfile` (+ new `PluginHelpers::TextFileIO`):
        `encoding:` honored (iconv/CPython-codec names), undecodable
        content and unknown codec names fail with 2.21's messages.
      - `pip`: `editable:` now precedes every package (one `-e` each).
      Unchanged after review: `cron`, `service`, `template`, `script`,
      `group` (the `force` guard is BSD/macOS/BusyBox-only; Linux keeps
      `groupdel -f`), `unarchive` (its zip date_time tuple change has no
      counterpart - krikri shells out to unzip), `apt_key`,
      `apt_repository`, `yum_repository`, `dnf` (beyond install_repoquery),
      `assemble`, `expect`, `command`, `wait_for`, `wait_for_connection`,
      `deb822_repository`, `rpm_key`, `iptables`.
- [ ] **Deferred module behavior gaps** found by that sweep (each
      deliberate, to be handled or issue-filed after the first round):
      - `pip` check-mode name resolution: 2.21 resolves bare package names
        through `pip install --dry-run --report` (pip >= 24.1) before
        deciding `changed`, and warns on older pip. krikri keeps its own
        check-mode heuristic (issue #794 lineage).
      - `iptables`: 2.21 de-duplicates `-m <match>` extensions against the
        ones already emitted (`loaded_extensions`); krikri can emit the same
        `-m` twice (cosmetic only - iptables accepts it).
      - `package_facts` on Alpine: 2.21 queries apk with
        `--fields name,version --format json` and maps "(none)" values;
        krikri's apk path was not re-verified against that.
- [ ] **Porting-guide pass** (2.20 + 2.21) for areas the probing can't
      reach: deprecation gates, lookup/filter behavior, connection-level
      changes. The live probing already covered templating scalars,
      result shapes, and the invocation knob.
- [ ] **Known micro-divergences** (documented, deliberate or deferred):
      - copy/lineinfile diff dicts: real 2.21 orders
        `before, after, before_header, after_header`; krikri emits
        `after, after_header, before, before_header` — low-priority shape
        fix, probe playbook `/tmp/nat5.yml`.
      - debug-module until tasks: real 2.21 shows no `attempts`;
        krikri keeps it (plain tasks and handlers DO carry it — the
        debug-action result replacement swallows it upstream in real).
      - custom-module injection echo (see the INJECT_INVOCATION
        deviation above).
- [ ] **Phase 4 — live verification** (blocked on the user running it):
      - re-run the #909/#910 repro against real 2.21.6 — byte-identical
        (already done ad hoc for stat; re-confirm on the release build).
      - krikri-role-tester batch (`--release` build of the merged commit)
        with the controller pinned to ansible-core 2.21.6, plus a re-run
        queue of previously-clean roles. Triage with `triage-round`.
        NOTE: `krikri-role-tester` must install ansible-core 2.21.6 on
        its controllers or every comparison is version-skew noise.
- [ ] **Phase 5 — docs + bookkeeping** (one commit after the round):
      - README version badge + compat row (compat row already updated).
      - `KNOWN_MISSING.md`: add the no-INI-parsing note for
        `inject_invocation` if not already covered by the generic
        no-ansible.cfg entry; retire anything 2.21 makes moot.
      - `ROLES_TESTED.md`: new round rows with timings, controller
        version visible per row.
      - Close/reference GitHub issues filed against 2.19-specific
        behavior; open issues for confirmed-but-unfixed 2.21 divergences.

## Risk register

| Risk | Mitigation |
|---|---|
| Untested plugin-level 2.19→2.21 module changes surface in the round | Per-plugin source diffs (Remaining work); each confirmed change = its own fix + test |
| Role-tester controllers on the wrong ansible-core version produce pure noise | Verify the controller installs 2.21.6 before the batch (`versions.txt` records it) |
| Host collection drift contaminates future snapshot regens | 16 known-drift entries documented above; consider restoring those collections before the next `gen_argspecs.py` run |
| Templating semantics beyond scalars moved in 2.20/2.21 (Data Tagging follow-ups) | Scalar conversion + result shapes verified live; remaining templating surface covered by the porting-guide pass |
| Scope creep | Rule: argspec + verified behavior deltas only; anything else becomes a tracked GitHub issue, not an unfixed silent gap |
