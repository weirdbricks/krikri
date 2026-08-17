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

**Status (`0.9.463`): items 1-5 below are done** - see `KNOWN_MISSING.md`
round 148 for implementation detail and live-verification notes. Items
6-10 remain open, ranked by expected impact on the real-host benchmark
rounds this project runs against actual Ansible roles/collections; revisit
if one of them actually surfaces in a live round rather than proactively.

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

6. **`group_by`** - dynamically creates inventory groups based on facts,
   mid-play. Lower priority for this project - relevant to complex
   multi-host orchestration playbooks, but the benchmark-round workflow
   here mostly tests single-role plays against 1-2 hosts, where `group_by:`
   rarely appears.

7. **`set_stats`** - sets custom values shown in the playbook stats/recap.
   Purely a reporting feature, never affects a role's actual converged
   state - low priority for a correctness-focused benchmark harness.

8. **`dpkg_selections`** - sets a package's dpkg selection state (e.g.
   `hold`). Niche; only shows up in roles that explicitly pin/hold Debian
   packages outside of `apt`'s own more common approach.

9. **`expect`** - automates interactive prompts (pty-based). Real
   implementation cost is high (pty handling, timeout/response matching)
   for a module that appears rarely in the roles this project benchmarks
   against.

10. **`subversion`** - checks out an SVN working copy. SVN itself is
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

Items 1-5 done (`0.9.463`). Revisit 6-10 if one actually surfaces in a
live benchmark round rather than proactively.
