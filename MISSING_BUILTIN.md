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

**Lookups** - biggest gap of the three. `env`, `url`, `first_found`
existed already; `vars`, `file`, `pipe`, `template`, `password` done
(`0.9.465`-`0.9.466`, both evaluators - see the module list above).
`0.9.468` added 8 more, `ExpressionEvaluator` only (Crinja `lookup()`
parity for these is a separate, still-open gap - see the note below):
`dict`, `list`, `items`, `together`, `nested`, `lines`, `varnames`,
`sequence`. All 8 always return real JSON array text (not real
Ansible's own default comma-joined-scalar behavior for a bare, no-
`wantlist` call) - these are essentially always consumed as a `loop:`/
`with_X:` source or piped through `| list`/`| flatten`, both of which
need a real array; live-verified as real `loop:` sources (`with_
sequence`/`with_nested`/`with_together`/`with_dict`-shaped playbooks).
Still missing: `config`, `csvfile`, `indexed_items`, `ini`,
`inventory_hostnames`, `nested_subelements` (real name: `subelements`),
`random_choice`, `unvault`.

**Filters** - `b64encode`/`b64decode`/`from_json`/`from_yaml`/`to_yaml`/
`checksum`/`union` done (`0.9.465`, both evaluators). `0.9.467` added 14
more, both evaluators: `path_join`, `splitext`, `urldecode`, `urlsplit`,
`zip`/`zip_longest` (capped at 2 extra list arguments in the Crinja
registration - the declared-keyword-args form needed to dodge the
`arguments.varargs` multi-positional-arg splitting bug, see the
`version` test's own comment - real 4+-way zip is rare), `product`
(same cap), `regex_escape`, `to_nice_json`, `human_readable`/
`human_to_bytes`, `md5`/`sha1` (standalone). `abs` turned out to
already exist (audit correction). Still missing: `combinations`,
`commonpath`, `expanduser`, `expandvars`, `extract`, `from_yaml_all`,
`items` (as a filter - real Ansible has no such filter, this was
probably the `items` LOOKUP mis-scraped into the filter list by the
original audit), `log`, `normpath`, `permutations`, `pow`,
`rekey_on_member`, `relpath`, `symmetric_difference`, `to_uuid`,
`unvault`, `vault`, `win_basename`/`win_dirname`/`win_splitdrive`.

**Tests** - `subset`/`superset`/`contains` done (`0.9.465`, both
evaluators). `any`/`all` turned out to already be registered in Crinja
(audit correction). `0.9.467` added `exists`/`file`/`directory`/`link`/
`link_exists`/`same_file` (both evaluators - `conditional_evaluator.cr`
+ `jinja_filters.cr`; always check the CONTROLLER's filesystem, same
rule `lookup('file', ...)` follows). Found and fixed a real ordering
bug while adding these: `" is link_exists"` contains `" is link"` as a
substring, so the naive per-test-name `.each`/`condition.includes?`
loop misfired on `link` before ever reaching `link_exists` - fixed by
checking the longer/more-specific name first. Still missing: `abs` (as
a test - real Jinja2/Ansible docs list it under both filters and tests;
only the filter form was verified real, this may be a docs-scrape
artifact, not investigated further), `mount`, `timedout`/`started`/
`finished`/`reachable`/`unreachable` (async/host-check tests), `urn`,
`vault_encrypted`, `vaulted_file`.

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
`0.9.466` done: `Crinja.function(:lookup)` in `jinja_filters.cr`, bringing
`env`/`vars`/`file`/`pipe`/`template`/`password` lookup support to real
`.j2` template files (previously `.j2`-only path had ZERO lookup types
at all - `lookup(...)` failed the whole render regardless of type).
Live-verified via a real `template:` task rendering a `.j2` file that
uses all 5 non-`env` lookup types together.

`0.9.467` done: 14 filters + 6 path-check tests, both evaluators (see
above). Full suite green throughout; live-verified filters via real
`debug:`-task rendering (assert-form comparisons against inline `[...]`
literals hit the pre-existing list-literal-argument limitation
documented above, not a bug in the new filters - confirmed by checking
each value individually instead).

`0.9.468` done: 8 more lookups, `ExpressionEvaluator` only (see above).
Live-verified as real `loop:` sources for `sequence`/`nested`/
`together`/`dict`-shaped iteration, matching the classic `with_X:`
idioms these replace.

The remaining long tail (everything else in the missing lists above,
plus Crinja `lookup()` parity for this round's 8 new types, plus
`url`/`first_found` inside a `.j2` file specifically) stays open,
revisited if a live benchmark round actually hits one.
