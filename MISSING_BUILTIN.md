# Missing `ansible.builtin` modules

Comparison of the full `ansible.builtin` collection module list (per the
official docs index) against what's registered in `AVAILABLE_PLUGINS`
(`src/crystal_play/playbook_parser.cr`) and `plugins/*.cr` today. Engine-level
action keywords (`import_playbook`, `import_role`, `import_tasks`,
`include_role`, `include_tasks`, `include_vars`, `meta`, `add_host`,
`validate_argument_spec`) are already handled outside the plugin system and
are excluded here. `mount_facts` is also excluded - already covered inside
`plugins/facts.cr`'s `gather_mount_facts`, not a standalone gap. `reboot` is
excluded - deliberately handled controller-side in `TaskExecutor#execute_reboot`
rather than as an uploaded plugin binary (see that method's comment).

**Status (`0.9.464`): all 10 items below are done** - see `KNOWN_MISSING.md`
rounds 148 (items 1-5) and 149 (items 6-10) for implementation detail and
live-verification notes.

This module-level list is now fully closed. The next layer of gaps - the
much larger Jinja2 filter/test/lookup surface used inside `{{ }}`
expressions rather than task modules - is tracked below, in this same
file.

1. **`script`** (done, `0.9.463`) - transfers a local (controller-side) script to the target
   and executes it. Common in bootstrap/init tasks across many roles. Needs
   the same controller->target SCP-staging pattern already used for
   `unarchive`'s `stage_unarchive_remote_src` / `copy`'s
   `stage_large_copy_source` (`src/crystal_play/task_executor/executor.cr`),
   since `src:` here always names a file on the controller, not the target.

2. **`assemble`** (done, `0.9.463`) - concatenates fragment files from a `src` directory into
   one `dest` file. Shows up in hardening/config-management roles that drop
   `.d`-style fragments (sudoers.d, sshd_config.d) and assemble them.
   Same controller-side-directory staging problem as `assemble`'s `src:`
   - mirrors `stage_directory_copy_source`.

3. **`tempfile`** (done, `0.9.463`) - creates a temporary file/directory on the target and
   registers its path. Common as an intermediate step ("create tempfile,
   register, use path, cleanup") in many roles' download/build tasks.
   Pure target-side plugin, no controller-side staging needed - cheapest of
   the batch to implement correctly.

4. **`known_hosts`** (done, `0.9.463`) - manages `~/.ssh/known_hosts` entries (add/remove a
   host key). Shows up in roles that clone git repos over SSH or manage
   trust for internal git/CI hosts. Target-side plugin, no staging needed.

5. **`raw`** (done, `0.9.463`) - executes a raw command over the connection plugin without any
   module-argument machinery (real Ansible's escape hatch for hosts with no
   Python). Since crystal-ansible never ships Python modules to begin with,
   its real gap here is narrower than in real Ansible: what's missing is
   just recognizing `raw:` as a task and giving it `shell:`-equivalent
   semantics (module-arg style: a raw command string, not key=value params,
   same as `command`/`shell`'s bare-string task-arg handling already listed
   in `AVAILABLE_PLUGINS`'s "raw command line" module set) - currently
   `raw:` tasks are silently dropped at parse time as "Plugin not
   available" instead. Cheap once recognized: reuse the `shell` plugin
   binary/executor path, don't build a new one.

6. **`group_by`** (done, `0.9.464`) - dynamically creates inventory groups based on facts,
   mid-play. Lower priority for this project - relevant to complex
   multi-host orchestration playbooks, but the benchmark-round workflow
   here mostly tests single-role plays against 1-2 hosts, where `group_by:`
   rarely appears.

7. **`set_stats`** (done, `0.9.464`) - sets custom values shown in the playbook stats/recap.
   Purely a reporting feature, never affects a role's actual converged
   state - low priority for a correctness-focused benchmark harness.

8. **`dpkg_selections`** (done, `0.9.464`) - sets a package's dpkg selection state (e.g.
   `hold`). Niche; only shows up in roles that explicitly pin/hold Debian
   packages outside of `apt`'s own more common approach.

9. **`expect`** (done, `0.9.464`) - automates interactive prompts (pty-based). Real
   implementation cost is high (pty handling, timeout/response matching)
   for a module that appears rarely in the roles this project benchmarks
   against.

10. **`subversion`** (done, `0.9.464`) - checks out an SVN working copy. SVN itself is
    largely extinct in the roles this project has encountered (round 16's
    "svn" mention was a package-swap test, not this module) - lowest
    priority.

Not re-litigated here (already confirmed present, not gaps):
`dnf5` (aliased through `plugins/package.cr`'s dnf/yum handling),
`gather_facts` (implicit play-level fact gathering, well-exercised),
`sysvinit` (service-manager-type detection already handled in
`facts.cr`/`service_facts.cr`), `validate_argument_spec` (role-level
internal feature, `role_loader.cr`/`executor.cr`).

## Plan

All 10 module-level items done (`0.9.463`-`0.9.464`). Continuing below
with the filter/test/lookup layer.

---

# Missing `ansible.builtin` filters/tests/lookups

Same comparison exercise, one level down: the Jinja2-adjacent plugins used
*inside* `{{ }}` expressions (`{{ x | filter }}`, `{{ x is test }}`,
`{{ lookup('type', ...) }}`) rather than as task modules. This codebase
has **two independent evaluators** for these (see the repo's own
`CLAUDE.md`) - the hand-rolled `{{ }}` evaluator
(`ExpressionEvaluator`/`ConditionalEvaluator`/`FilterEngine`, under
`src/crystal_play/variable_substitutor/`) for plain task-param
substitution, and the vendored Crinja shard (`jinja_filters.cr` registers
custom additions into `Crinja.filter`/`Crinja.test`) for real `.j2`
template files. A gap can exist in either, both, or neither - each is
checked and fixed independently, same as any other bug class here.

Full real name lists (ansible.builtin collection, official docs):
Filter/Test/Lookup Plugins - see this file's own git history (round 149's
audit) for the complete lists; not repeated here to keep this file
focused on gaps, not the full reference list.

## Status: fully closed except Windows-only filters (`0.9.469`)

All three lists are now closed except `win_basename`/`win_dirname`/
`win_splitdrive` (Windows-only, irrelevant - this codebase targets Linux
managed hosts exclusively) and `config`/`inventory_hostnames` lookups
(deliberately not implemented - `config` reads real ansible-core's own
configuration system, which this codebase has no equivalent of at all;
`inventory_hostnames` needs the full `Inventory` object threaded through
`ExpressionEvaluator`, which is built fresh per task from a plain
`Hash(String, JSON::Any)` with no access to `TaskExecutor`'s own
`@inventory` - revisit either if a real role needs one).

Two corrections the original audit got wrong, found while implementing:
`abs` (filter) and `any`/`all` (tests) already existed; `abs` as a
*test* was never confirmed real (may be a docs-scrape artifact, `abs`
only exists as a filter in the ranged-checked ansible-core source).

**`0.9.467`** - 14 filters + 6 path-check tests, both evaluators:
`path_join`, `splitext`, `urldecode`, `urlsplit`, `zip`/`zip_longest`
(capped at 2 extra list arguments in the Crinja registration - the
declared-keyword-args form needed to dodge the `arguments.varargs`
multi-positional-arg splitting bug, see the `version` test's own
comment), `product` (same cap), `regex_escape`, `to_nice_json`,
`human_readable`/`human_to_bytes`, `md5`/`sha1` (standalone);
`exists`/`file`/`directory`/`link`/`link_exists`/`same_file` tests
(always check the CONTROLLER's filesystem, same rule `lookup('file',
...)` follows - found and fixed a real ordering bug here: `" is
link_exists"` contains `" is link"` as a substring, so the naive per-
test-name loop misfired on `link` before ever reaching `link_exists`).

**`0.9.468`** - 8 more lookups, `ExpressionEvaluator` only at the time:
`dict`, `list`, `items`, `together`, `nested`, `lines`, `varnames`,
`sequence`. Live-verified as real `loop:` sources.

**`0.9.469`** - closes everything else:
- Filters, both evaluators: `expanduser`, `expandvars`, `normpath`,
  `relpath`, `commonpath`, `log`, `pow`, `to_uuid`, `symmetric_
  difference`, `combinations`, `permutations`, `rekey_on_member`,
  `extract`, `from_yaml_all`, `vault`/`unvault` (the FILTER forms -
  encrypt/decrypt using an explicit filter-argument secret, backed by
  the project's own real `Vault` module - `src/crystal_play/vault.cr`,
  already used for `--vault-password-file`/`ansible-vault`-format
  files elsewhere in this codebase).
- Tests, both evaluators: `mount` (shells to the real `mountpoint(8)`
  utility rather than hand-rolling a device/inode stat comparison),
  `vault_encrypted`, `vaulted_file`, `urn`, `started`/`finished`/
  `timedout`/`reachable`/`unreachable` (async/host-check tests, on a
  registered result dict - deliberately NOT reusing the existing
  `#result_field` helper, since real Ansible's own async_status/
  wait_for_connection result shape represents these as an INTEGER 0/1,
  not a JSON bool, which `#result_field`'s `.as_bool?` check would
  silently treat as always-false).
- Lookups: 6 more in `ExpressionEvaluator` (`indexed_items`,
  `random_choice`, `subelements`, `csvfile`, `ini`, `unvault` - the
  LOOKUP form, decrypting a file with the RUN's own session-wide vault
  secret, distinct from the filter form's explicit argument), plus
  full Crinja `lookup()` parity for all 14 non-`env`/`vars`/`file`/
  `pipe`/`template`/`password` types added since `0.9.466` (capped at
  4 extra positional arguments beyond `type`, same declared-args
  tradeoff `zip`/`product` already made - covers every lookup type
  registered, including the 3-argument `subelements`).

Real bug found and fixed along the way: `lookup('random_choice', ...)`
initially returned its scalar result via `.to_json` (matching the
always-array convention the `0.9.468` lookups use), which wrongly
quoted a string result (`"only"` instead of `only`) when rendered bare
- fixed to use the same `@lookup.format_value` plain-text rendering
`vars`/`env` already use, since `random_choice` (like real Ansible's
own implementation) returns one scalar, not a list.

Full suite green throughout (1441 examples by the end). Live-verified:
the `0.9.469` filters via real `debug:`-task rendering; `unvault` (both
filter and lookup forms) against a file encrypted with the real
`ansible-vault` CLI itself, decrypted via `--vault-password-file` end to
end; the 6 new lookups via a real playbook (`csvfile`/`ini` against real
files, `subelements`/`indexed_items` as real `loop:` sources); full
Crinja `lookup()` parity via a real `.j2` template rendered through an
actual `template:` task, exercising `subelements` and `sequence`
together.
