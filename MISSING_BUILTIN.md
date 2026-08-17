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
expressions rather than task modules - is tracked separately (see the
filter/test/lookup audit results from this same session; write-up
pending in a follow-on file).

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

**Lookups** - biggest gap of the three. `env`, `url`, `first_found`
existed already; `vars`, `file`, `pipe`, `template`, `password` done
(`0.9.465`, `ExpressionEvaluator#evaluate_lookup` only - the plain `{{ }}`
task-param path; a `.j2` template file calling `lookup(...)` directly
remains unsupported, Crinja has no `lookup` global function registered
at all, a separate, still-open gap). Still missing: `config`, `csvfile`,
`dict`, `indexed_items`, `ini`, `inventory_hostnames`, `items`, `lines`,
`list`, `nested`, `random_choice`, `sequence`, `subelements`, `together`,
`unvault`, `varnames`.

**Filters** - `b64encode`/`b64decode`/`from_json`/`from_yaml`/`to_yaml`/
`checksum`/`union` done (`0.9.465`, both evaluators - `filter_engine.cr`
and `jinja_filters.cr`). Still missing: `combinations`, `commonpath`,
`expanduser`, `expandvars`, `extract`, `from_yaml_all`, `human_readable`,
`human_to_bytes`, `items`, `log`, `md5`/`sha1` (as standalone filters -
only exist as an algorithm selector inside `hash`/`password_hash`),
`normpath`, `path_join`, `permutations`, `pow`, `product`,
`regex_escape`, `rekey_on_member`, `relpath`, `splitext`,
`symmetric_difference`, `to_nice_json`, `to_uuid`, `unvault`,
`urldecode`, `urlsplit`, `vault`,
`win_basename`/`win_dirname`/`win_splitdrive`, `zip`, `zip_longest`.

**Tests** - `subset`/`superset`/`contains` done (`0.9.465`, both
`conditional_evaluator.cr` and `jinja_filters.cr`). `any`/`all` turned
out to already be registered in Crinja (the original audit's list was
wrong on these two - corrected here). Still missing: `abs`, `directory`,
`exists`, `file`, `link`, `link_exists`, `mount`, `same_file`,
`timedout`/`started`/`finished`/`reachable`/`unreachable` (async/host-
check tests), `urn`, `vault_encrypted`, `vaulted_file`.

Known limitation shared by every filter/test added in this pass that
takes another list as an argument (`union(other)`, `is subset(other)`,
`is superset(other)`) in the hand-rolled `{{ }}` evaluator: `other` must
be a variable reference, not an inline `[...]` list literal -
`resolve_expression`/`resolve_test_operand` have no list-literal parser
(only a `{...}` dict-literal one) - a pre-existing gap already shared by
`intersect`/`difference`, not introduced by this pass. Real playbooks
almost always pass a variable here anyway.

Original ranking (all 8 done in `0.9.465`, see `KNOWN_MISSING.md` for
implementation/verification detail): `lookup('vars', ...)`,
`lookup('file', ...)`, `lookup('template', ...)`, `lookup('pipe', ...)`,
`b64encode`/`b64decode` filters, `to_yaml` filter, `is subset`/
`is superset`/`is contains` tests, `lookup('password', ...)`.

## Status

`0.9.465` done: the 8 ranked items above, plus `from_json`/`from_yaml`/
`checksum`/`union` filters (found while implementing the ranked set -
`from_json`/`from_yaml` are `to_json`/`to_yaml`'s natural mirror,
`union`/`checksum` were cheap once `b64encode`'s registration pattern
was in place). Live-verified via a real playbook run (all 5 lookups +
6 filters/tests exercised together, `crystal spec` 1361 examples green).
The remaining long tail (everything else in the missing lists above)
stays open, revisited if a live benchmark round actually hits one -
`lookup('vars'/'file'/'pipe'/'template'/'password', ...)` inside a real
`.j2` template file (as opposed to a task param) is the one gap from
this pass most likely to actually surface that way, since Crinja has no
`lookup()` global function registered at all yet.
