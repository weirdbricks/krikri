# Crystal Play - Roadmap to Ansible Parity

**Currently at `0.9.171`** - real-host benchmark rounds against
production Ansible roles keep finding and closing bugs past the "Phases
0-5 complete" milestone below; see the `linux-system-roles` benchmark
round entry (search this file for `0.9.158`) for the most recent one.
The narrative below is largely historical (last fully rewritten at
`0.9.84`) and is not re-litigated on every release - treat version
numbers cited inline as "true as of when that paragraph was written,"
and prefer `git log`/this file's own newest entries over the framing
text below for current state.

**Status as of 2026-08-05 (currently at `0.9.84`):** **all of Phase 0 through
Phase 5 are done** - see the checkboxes in each phase section below (roles,
import/include, vault, every Phase 3 plugin, every Phase 4
advanced-execution feature, and all eight Phase 5 modules: `set_fact`
`0.9.24`, `get_url` `0.9.25`/`0.9.32`, `blockinfile` `0.9.26`, `uri` `0.9.27`,
`assert` `0.9.28`, `wait_for` `0.9.29`, `fetch` `0.9.30`, `pause` `0.9.31`).
**All four cross-cutting engine gaps this roadmap has ever tracked are now
fixed:** dotted-variable access in bare conditionals (`0.9.34`), the recap
`ok`/`changed` counter overlap (`0.9.35`), `become:`/`become_user:`
privilege escalation (`0.9.41`), and Jinja2 filter-chaining (`0.9.42`). The
per-plugin scope-cut grab-bag is fully closed for every plugin that had one
at Phase 5's completion: `stat`'s `get_mime`/`get_attributes` (`0.9.36`),
`find`'s `age`/`age_stamp`/`contains`/`read_whole_file` (`0.9.37`),
`archive`'s `exclude_path` (`0.9.38`), `ufw`'s `insert_relative_to`
(`0.9.39`), and `mysql_db`/`postgresql_db`'s `state: dump`/
`import`(`restore`) (`0.9.40`, `.bz2`/`.xz` compression added `0.9.43`)
have all shipped - work has now moved on to closing the *remaining*
documented per-plugin scope cuts one at a time in pursuit of fuller
`ansible-core`/`community.*` parity, most recently `postgresql_privs`
(`0.9.44`, previously not implemented at all), `mount`'s `remounted`
state (`0.9.45`), `wait_for`'s `state: drained` (`0.9.46`), and
`apt_repository`'s `ppa:` shorthand (`0.9.47`), `user`'s `password:`/
`update_password:`/`password_lock:` (`0.9.48`), `mount`'s
`state: ephemeral` (`0.9.49`), `yum_repository`'s tuning-knob
expansion plus a real `baseurl:`/`gpgkey:` multi-value list-join bug fix
(`0.9.50`), and `docker_container`'s `networks:` plus `docker_network`'s
`connected:`/`appends:` (`0.9.51`, along with a real engine-level bug fix
to how list-of-dict module params get encoded - see that entry), and
`mysql_db`'s `.zst` compression plus `postgresql_db`'s `.tar`/`.pgc`/
`.dir` `pg_restore`-based formats (`0.9.52`), `mysql_db`'s
`config_file:`/`name: all`/remaining `mysqldump` tuning knobs (`0.9.53`),
`postgresql_privs`' `type: language`/`tablespace`/`type`,
`ALL_IN_SCHEMA`, `session_role:`, and `fail_on_role:` (`0.9.54`), and
`docker_*`'s TLS options for connecting to a remote Docker daemon
(`0.9.55`), `postgresql_privs`' `type: foreign_data_wrapper`/
`foreign_server`/`parameter`/`group` (`0.9.56`), and `docker_*`'s
`tls_hostname:` plus `DOCKER_TLS`/`DOCKER_TLS_VERIFY`/`DOCKER_CERT_PATH`
environment variable fallbacks (`0.9.57`), and four real bugs found via a
genuine real-SSH benchmark against real remote hosts - not a local
container - comparing crystal-ansible against real `ansible-playbook`
end to end (`0.9.58`, see that entry) - see "Also still
open" near the end of
Phase 5 for what's left and the running list of what's already been
closed past that point. **All four cross-cutting engine gaps are closed, and as of `0.9.82` no
cross-cutting engine gap remains open at all** - the last one (magic
variables invisible to bare `when:`/`assert: that:`/`until:`/
`changed_when:`/`failed_when:` conditions) is fixed; see that entry.
Engine performance work `0.9.66`-`0.9.81` closed two full review
documents; see those entries for the measured before/after against real
hosts. All 793 specs pass in an environment with
`mysql`/`mysqldump`/`psql`/`pg_dump`/`pg_restore` client binaries on
`PATH` and a live MySQL/MariaDB + PostgreSQL server reachable at
`127.0.0.1:13306`/`15432`; without those (neither installed on this host
by default) the same 2 exceptions as always apply - see the `0.9.40`
entry for how dump/restore was originally verified anyway, and the
`0.9.52` entry below for how a real server *was* reached this time
(client binaries extracted from the same Docker images used for the
`0.9.52` verification itself, onto `~/.local/bin`, not a permanent host
change), `ameba` clean
on all new/touched code. A Docker-based compatibility harness (`compat/`,
see `compat/README.md`) runs the same playbooks through real
`ansible-playbook` and `crystal-ansible` side by side and diffs the
resulting filesystem state + exit codes - ground truth instead of
assumptions; **39/39 compat playbooks pass** (`mount`'s own `remounted`/
`ephemeral`, `wait_for`'s own `drained:`, `apt_repository`'s own `ppa:`,
`user`'s own `password:`, `docker_container`/`docker_network`'s own
`networks:`/`connected:`, and `mysql_db`/`postgresql_db`'s own `0.9.52`
formats all happened outside the harness instead, for different reasons
documented in their own `0.9.45`-`0.9.52` entries - see each for how it
was verified instead;
`yum_repository`'s `0.9.50` work is covered by an extended
`23-yum-repository.yml` harness entry instead) - see each entry below and
`compat/README.md`'s Coverage section for what each one caught.

Two cross-cutting efforts also landed since Phases 3/4 were marked done:

- **Native syscall conversion (0.9.15-0.9.23):** a survey found most plugins
  shelled out to `/bin/bash` subprocesses for operations Crystal can do with
  stdlib syscalls. Nearly all are now native (5x-250x faster, and more robust -
  no reliance on command exit codes): `stat`/`find` (0.9.15), `archive`
  tar/gz/zip/xz/bz2 (0.9.16-0.9.18), `file` (0.9.19), `apt_repository`/
  `yum_repository` (0.9.20), `authorized_key` (0.9.21), `mount` (0.9.22),
  `sysctl` (0.9.23). The
  deliberate exceptions - genuine system/network operations with no faithful
  native Crystal equivalent - are documented per-plugin and stay shelled out
  (`apt`/`dnf`/`package` package-manager calls, `mount`/`umount`,
  `sysctl -w`/`-p`, `service` systemctl, `git`, `ufw`, `firewalld`). Plugins
  that genuinely support remote hosts (`mount`, `sysctl`, `authorized_key`)
  keep an SSH branch per converted call; the pure-local file plugins do not.
  The `compat/Dockerfile` image build was fixed (it had silently broken when
  `archive` went native - the image lacked the `-dev` link deps) and switched
  to a **debug** build for faster iteration; the `authorized_key` playbook was
  extended to cover user home resolution.

- **Bug-fix history:** the harness plus manual testing, self-review, and unit
  tests found and fixed many real bugs across Phases 1-4 (FQCN mis-registration,
  templating/boolean-render divergences, `grep`-exit-code edge cases, variable/
  include parsing gaps, `find`/`archive` path-matching bugs, check-mode guards,
  and more). These are recorded in the commit history (`git log`); they are not
  repeated here to keep this header scannable.

**The real parity gap (Phase 5, now complete):** the roadmap's earlier claim of
"full parity for Linux server automation" was overstated - several *very common*
`ansible.builtin` modules were entirely missing (`set_fact`, `get_url`,
`blockinfile`, `uri`, `assert`, `wait_for`, `fetch`, `pause`), each failing
with "Plugin binary not found." All eight have now shipped (`0.9.24`-`0.9.31`,
see each entry under Phase 5 below for what was actually implemented,
including several points where this roadmap's own scoping - written before
any of them were built - turned out to be wrong once checked against real
`ansible-playbook` runs). The remaining lower-priority scope cuts and engine
gaps are listed at the end of the Phase 5 section.

This roadmap sequences work into phases, with the test-foundation phase
(Phase 0) landing first so every phase after it ships with a regression net
instead of drifting untested.

---

## Phase 0 - Foundation (do this before adding anything else)

There is currently no `spec/` directory, no test framework dependency, and no CI.
Every plugin added past this point needs a regression net or the project will drift
the same way it did between January and now.

1. Add `crystal spec` scaffolding (`spec/spec_helper.cr`).
2. Unit specs for the pure-logic pieces (no I/O): `conditional_evaluator.cr`,
   `variable_substitutor/*` (filters, comparisons, expression eval),
   `playbook_parser.cr` (YAML -> task struct).
3. Integration specs that run the built binary against the existing
   `testing/*.yml` fixtures in `--check` mode and assert exit code + expected
   changed/ok counts. This turns the current manual fixtures into real
   regression tests for free.
4. GitHub Actions workflow: build + `crystal spec` + `ameba` on every push.
5. Bump to `0.2.0` once this lands.

**Every phase below ships plugins/features with specs, not just code.**

---

## Phase 1 - Essential gaps (~2-3 weeks)

- [x] Loop constructs (`0.2.1`): `loop`/`with_items` (already parsed but
  previously never executed - was a dead field), `with_dict`, `with_nested`,
  `with_sequence`, `with_indexed_items` resolved at parse time via the new
  `LoopResolver` module; `with_fileglob` resolved at execution time (needs
  `{{ vars }}` substitution + filesystem access); `until`/`retries`/`delay`
  retry a task against a condition on its registered result (skipped
  entirely in `--check` mode, since most modules refuse to act in check
  mode anyway and retrying would just burn `retries * delay` seconds for
  nothing). Looped + registered tasks aggregate into
  `{"changed": .., "failed": .., "results": [...]}`, matching Ansible's
  shape. Covered by unit specs (`loop_resolver_spec.cr`,
  `playbook_parser_spec.cr`) and an integration fixture
  (`testing/test-loop-quick.yml`). Access patterns that don't fit the
  existing evaluator: tuple items (`with_nested`, `with_indexed_items`) use
  bracket indexing (`item[0]`, `item[1]`), not Ansible's dot-tuple access
  (`item.0`) - fine for a from-scratch reimplementation, just not
  pixel-perfect Jinja2 compatibility.
- [x] Plugins (`0.3.0`): `user`, `group` (via `getent`/`useradd`/`usermod`/
  `userdel`/`groupadd`/`groupmod`/`groupdel` - `user`'s own password
  management shipped in `0.9.48`, see that entry near the end of Phase 5;
  `group` never had one to begin with - confirmed via real Ansible's own
  `group.py` argument_spec, which has no `password:` parameter at all,
  so there was never a scope cut to close there); `git` (clone/checkout/update via the `git` CLI); `cron`
  (file-based only - `cron_file:`, matching Ansible's `/etc/cron.d` style;
  deliberately does NOT manage a live user crontab via the `crontab`
  command, since mutating this process's real login crontab as a side
  effect of a test run isn't a risk worth taking); `authorized_key` (with a
  non-standard `path:` override for safe testing against a scratch file
  instead of a real user's `~/.ssh/authorized_keys`). Decision/parsing
  logic factored into pure, I/O-free modules under
  `src/crystal_play/plugin_helpers/` (`user_state.cr`, `group_state.cr`,
  `cron_table.cr`, `authorized_keys_file.cr`) and unit tested directly;
  plugin wrappers integration-tested by piping JSON at the real compiled
  binaries the way `PluginManager` does (`spec/integration/{user,group,
  git,cron,authorized_key}_spec.cr`), with `user`/`group` exercised in
  `--check` mode only (or read-only `getent` lookups / genuine absent-state
  no-ops) since those tests run on a developer's real machine, not just a
  throwaway CI container, and must never actually create/modify/delete a
  real system account or group. Also fixed three real, previously-shipped
  bugs found while wiring these up: `lineinfile` read its config from
  `ARGV[0]` (nothing ever passes argv - `PluginManager` always pipes JSON
  over stdin, so this plugin silently never ran for real), then after that
  fix still read params from the wrong JSON nesting level (top-level
  instead of `config["params"]`), and even after both of those, its
  `original_content.split("\n", -1)` doesn't mean "keep trailing empty
  strings" in Crystal the way it does in Ruby - so it never actually split
  the file into lines at all. `lineinfile` is now rewritten onto
  `BasePlugin` like every other plugin, with its matching/insertion logic
  extracted into `src/crystal_play/plugin_helpers/line_editor.cr` and unit
  tested. Also fixed `build.sh`'s staleness check, which only compared
  `crystal-play.cr`'s own mtime and so missed edits under `src/`.
- [x] `block` / `rescue` / `always` error handling (`0.4.0`): `block:` groups
  tasks (which may themselves nest further blocks); on an unrescued failure
  inside the block, the host halts for the rest of the play, matching
  `rescue:`-less Ansible behavior; `rescue:` recovers the block (failure no
  longer halts the play) and moves the recovered failure count into a new
  `rescued=N` recap bucket (mirroring modern `ansible-playbook`'s own
  `rescued=` field) rather than counting it as `failed=`; `always:` runs
  unconditionally - even after an unrescued failure - and can itself
  introduce a new failure that re-halts the play after a successful rescue.
  This surfaced (and required fixing) a genuinely foundational, previously
  dead field: `ignore_errors:` was parsed but never read anywhere in
  `TaskExecutor` - nothing ever stopped executing a play after a task
  failed, so a `rescue:` could never have had anything to actually recover
  *from*. Added per-host halt tracking respecting `ignore_errors:` as the
  base this feature sits on. Fixing that in turn surfaced a second,
  user-visible bug: `crystal-play.cr`'s final "PLAY RECAP" was entirely
  fake - a hardcoded `"ok (playbook complete)"` per host regardless of what
  actually happened (there was even a `# TODO: Get actual stats from
  executor` comment sitting on it), and the process always exited `0`
  regardless of failures. `TaskExecutor#results` is now exposed and
  aggregated across plays into a real recap, and the process exits `2` if
  any host ended up with `failed > 0`. `TaskExecutor` isn't realistically
  unit-testable in isolation (heavy plugin/SSH I/O), so this is covered
  entirely by integration specs driving the real compiled binary for real
  (not just `--check`, since `command`/`shell` skip outright in check mode
  and would never exercise the failure path at all):
  `testing/test-error-handling-quick.yml` (ignore_errors, a rescued block,
  always:) and `testing/test-error-handling-unrescued.yml` (an unrescued
  block failure, asserting the process now exits non-zero). The
  block:/rescue:/always: *parsing* (nesting, block-level when:/tags:/
  ignore_errors:, validate()/stats() recursing into blocks without
  misreporting the "_block" pseudo-module as unimplemented) is pure logic
  and is unit tested directly in `playbook_parser_spec.cr`. Known
  simplification: unlike Ansible, a block's `when:` does not cascade into
  each nested task's own condition - it only gates whether the block runs
  at all, and each nested task still evaluates its own `when:` separately.

**Result:** ~99.95% playbook coverage per prior analysis.

---

## Phase 2 - Organizational (~2-3 weeks)

- [x] Roles (`0.6.0`): `roles/<name>/{tasks,handlers,vars,files,templates,
  defaults,meta}` directory resolution (searched under `<playbook_dir>/roles/`
  then `./roles/`, matching Ansible's common case - not the full
  `ANSIBLE_ROLES_PATH` search); a `roles:` entry can be a bare name or a
  mapping (`role:`/`name:`, `vars:`, `tags:`, and any other inline key -
  Ansible treats those as vars too); `meta/main.yml` `dependencies:` run
  before the role's own tasks, recursively, and each role loads only once
  even if listed directly and pulled in as a dependency; role tasks/handlers
  run before the play's own `tasks:`/`handlers:` (`pre_tasks:`/`post_tasks:`
  aren't implemented, so this is simplified to just roles-then-tasks).
  Variable precedence: `defaults/main.yml` (lowest) < play vars < host vars
  < registered vars < `vars/main.yml` + the role invocation's own `vars:`
  (invocation wins) < the task's own `vars:` (highest) - extending the
  existing (already-simplified) `VariableContext` merge chain with two new
  tiers read directly off the originating `Task`, rather than threading
  extra parameters through every call site. A `copy:`/`template:` `src:`
  that came from a role resolves relative to that role's `files:`/
  `templates:` directory in the executor, before the config is handed to
  the plugin subprocess (which has no concept of roles itself). Implemented
  in a new `src/crystal_play/role_loader.cr`, reusing `PlaybookParser`'s
  existing (now public) `parse_tasks` for tasks/main.yml and
  handlers/main.yml, so role tasks get identical parsing (loops,
  block/rescue/always, until/retries, etc.) to any other task. Unit tested
  directly against real temp role directories
  (`spec/unit/role_loader_spec.cr`, `spec/unit/playbook_parser_spec.cr`'s
  "roles: wiring" group), integration-tested via the CLI
  (`testing/test-roles-quick.yml` + `testing/roles/`), and verified against
  real `ansible-playbook` via the compat harness
  (`compat/playbooks/11-roles.yml` - passed on the first try).
- [x] `import_playbook` / `import_tasks` / `include_tasks` / `include_role`
  (`0.7.0`):
  - `import_playbook:` is a top-level playbook-list entry (`{import_playbook:
    path.yml}` alongside plays, not inside `tasks:` - matches Ansible)
    resolved at parse time: the imported file is parsed recursively and its
    plays spliced in at that position.
  - `import_tasks:` is resolved at parse time too - the imported file's
    tasks are spliced directly into the caller's task list (not wrapped in
    a pseudo-task). Per `ansible-doc`: "Most keywords, including loops and
    conditionals, only apply to the imported tasks, not to this statement
    itself" - so the import's own `when:`/`tags:`/`vars:` are applied to
    **each** imported task individually (`when:` ANDed with any condition
    the task already has). `loop:` isn't supported on `import_tasks:` (use
    `include_tasks:`) and is ignored if present.
  - `include_tasks:` is resolved at **execution** time instead, as a
    pseudo-module (`_include_tasks`) parallel to how `block:` already
    works: the file path may be templated, and `when:`/`tags:`/`vars:`/
    `loop:` (`loop:`/`with_items:` only, not the full loop-source set)
    apply to the include statement itself - gating or repeating the whole
    included set once per loop item, with `item:` and the include's own
    `vars:` propagated into each included task's scope.
  - `include_role:` is the dynamic counterpart to a `roles:` list entry,
    also resolved at execution time (`_include_role` pseudo-module,
    `when:`/`tags:`/`loop:` same as `include_tasks:`), via a new
    `RoleLoader.load_single_role` reusing all of the static `roles:` path's
    machinery (`meta/main.yml` dependencies, `defaults/main.yml`/
    `vars/main.yml`, `files/`/`templates/` dirs). Per `ansible-doc`, `vars:`
    is a sibling task keyword here (not nested inside `include_role:`
    itself, unlike a `roles:` list entry's `vars:` - a real syntactic
    difference, not an oversight). `allow_duplicates:` (default `true` for
    `include_role:`, unlike `roles:`) is approximated by every call loading
    the role fresh; an explicit `allow_duplicates: false` isn't honored.
  - Building `include_role:` surfaced two real, previously-shipped bugs
    unrelated to includes themselves: dynamically-loaded role handlers
    (and, more generally, any two `Task` objects that happen to share a
    `name:`) were each independently matched against the notified-handlers
    set and run once *per Task object* rather than once *per handler
    name* - so `include_role:` combined with `loop:` fired the same
    handler multiple times. `HandlerRunner#run` now tracks "already ran"
    per host, by handler name, fixing this regardless of how many
    Task objects share that name. Second: task-level `vars:` was not
    parsed at all for `import_tasks:`/`include_tasks:` (a very common way
    to use them) - added scoped support for both (not the general
    `vars:` support ordinary module tasks would need - that's a
    separate, pre-existing gap this didn't try to close).
  - Unit tested (`playbook_parser_spec.cr`'s `import_playbook:`/
    `import_tasks:`/`include_tasks:`/`include_role:` parsing groups,
    `handler_runner_spec.cr` for the dedup fix), integration-tested via
    the CLI for the dynamic (execution-time) pieces specifically
    (`testing/test-include-tasks-quick.yml`,
    `testing/test-include-role-quick.yml` + `testing/roles/
    include_role_target/`), and verified against real `ansible-playbook`
    via the compat harness (`compat/playbooks/12` through `15` - all
    passed).
- [x] Vault (`0.8.0`): AES256 encrypt/decrypt, `--ask-vault-pass`,
  `--vault-password-file`, inline `!vault` encrypted values.
  - Format verified against real `ansible-vault` output (not assumed from
    memory): `$ANSIBLE_VAULT;1.1;AES256` header + double-hex-encoded
    `salt\nhmac\nciphertext`, wrapped at 80 columns. PBKDF2-HMAC-SHA256
    (10,000 rounds, 80-byte output) split into a 32-byte AES key, a
    32-byte HMAC key, and a 16-byte CTR IV; PKCS7-padded plaintext under
    AES-256-CTR; HMAC-SHA256 computed over the ciphertext
    (encrypt-then-MAC), checked with a constant-time comparison.
    Implemented in a new `src/crystal_play/vault.cr`, unit tested
    (`spec/unit/vault_spec.cr`) against a ciphertext fixture generated by
    real `ansible-vault` (provenance documented in the spec) plus
    round-trip encrypt/decrypt coverage.
  - `crystal-ansible vault {encrypt|decrypt|view|encrypt_string|rekey}`
    subcommands (`src/crystal_play/vault_cli.cr`), matching real
    `ansible-vault`'s CLI shape - `create`/`edit` (which launch `$EDITOR`)
    aren't implemented. `encrypt_string`'s output format (`name: !vault |`
    followed by the armored block indented with a fixed 10 spaces) was
    verified empirically against real `ansible-vault encrypt_string`, not
    assumed.
  - `--vault-password-file`/`--ask-vault-pass` (the latter prompting with
    echo disabled via `stty -echo`) set a single session-wide
    `Vault.password`, consulted by every file-loading call site instead of
    threading a password parameter through each one: the main playbook,
    recursively-imported playbooks (`import_playbook:`), imported/included
    task files (`import_tasks:`/`include_tasks:`), and role files
    (`tasks/handlers/defaults/vars/meta`, both static `roles:` and dynamic
    `include_role:`) via `Vault.maybe_decrypt`.
  - Inline `!vault`-tagged values (what `ansible-vault encrypt_string`
    produces, pasted into an otherwise-plaintext vars file) are handled
    too: Crystal's YAML parser drops unknown tags and hands back the
    tagged scalar as a plain string, which already looks exactly like a
    vault-encrypted file's content - so a new `Vault.maybe_decrypt_json`,
    applied everywhere a parsed YAML value becomes a `JSON::Any` var
    (play `vars:`, `import_tasks:`/`include_tasks:`/`include_role:`
    `vars:`, role `defaults/main.yml`/`vars/main.yml`, module task
    parameters, inventory host/group vars), recurses into arrays/hashes
    and decrypts any vault-encrypted string leaf it finds.
  - Verified against real `ansible-playbook` via the compat harness: a
    whole vault-encrypted playbook file (`compat/playbooks/16-vault.yml`,
    real `ansible-vault`-encrypted) and an inline `!vault` variable
    (`compat/playbooks/17-vault-inline.yml`, generated with real
    `ansible-vault encrypt_string`), both run with
    `--vault-password-file` against `compat/vault_pass.txt` - both passed.

**Result:** enterprise-ready. Phase 2 is now fully complete.

---

## Phase 3 - Extended plugins (~4-6 weeks)

- [x] `stat` (`0.9.0`; `get_mime`/`get_attributes` added in `0.9.36`):
  read-only file/filesystem status, feeding `register:` +
  `when:`/templating - never reports `changed`. Parameters: `path`
  (required), `follow` (default `false`), `get_checksum` (default
  `true`), `checksum_algorithm` (`md5`/`sha1`/`sha256`), `get_mime`
  (default `true`) and `get_attributes` (default `true`) - both were
  originally left unimplemented as "lower-value, tool-dependent extras,"
  but both default to `true` in real Ansible, meaning most real playbooks
  calling `stat:` with no extra options already expected these fields;
  closed as part of the roadmap's cross-cutting-gaps cleanup rather than
  staying a permanent scope cut. Neither is a missed native-conversion
  opportunity like `stat`'s own core fields used to be - both shell out in
  real Ansible's own `module_utils/basic.py` too (`file
  --mime-type --mime-encoding <path>` for `get_mime`, `lsattr -vd <path>`
  for `get_attributes`; neither has a native Crystal or Python stdlib
  equivalent), so this plugin does the same via the existing local/remote
  `remote_exec` split. Parsing logic (the `"path: mimetype; charset=x"`
  and `"version flags path"` output shapes, plus the `lsattr` single-letter
  flag → attribute-name table, e.g. `e` → `extents`) lives in a new, pure
  `src/crystal_play/plugin_helpers/file_attributes.cr` (unit tested,
  `spec/unit/file_attributes_spec.cr`), verified against a real ext4-backed
  file's actual `file`/`lsattr` output field-for-field, not assumed from
  the real Ansible source's own parsing code (which was also read
  directly, not guessed). On failure - e.g. a filesystem `lsattr` doesn't
  support, like tmpfs, or a missing `file`/`lsattr` binary - falls back to
  real Ansible's own documented fallback values (`mimetype`/`charset:
  "unknown"`; `version: null`, `attr_flags: ""`, `attributes: []`) rather
  than failing the task, verified against a real `ansible-playbook` run
  against exactly such a path (an empty file on tmpfs). Integration tested
  (`spec/integration/stat_spec.cr`, 4 new examples: mime fields present by
  default and absent with `get_mime: false`, attribute fields present by
  default and absent with `get_attributes: false`) and verified against
  real `ansible-playbook` via the compat harness
  (`compat/playbooks/18-stat.yml`, extended to compare `mimetype`/
  `attr_flags` too - passed). Field shape (`exists`/`isreg`/`isdir`/`islnk`/`mode`/
  `size`/`uid`/`gid`/`pw_name`/`gr_name`/`rusr`-`xoth`/`isuid`/`isgid`/
  `lnk_target`/`lnk_source`/`checksum`/etc.) verified field-by-field
  against real `ansible-playbook`'s actual JSON output, not assumed from
  docs. Parsing logic lives in a new, dependency-free
  `src/crystal_play/plugin_helpers/stat_fields.cr` (unit tested directly,
  `spec/unit/stat_fields_spec.cr`) so `find` (below) can reuse it for its
  per-match dicts, which real Ansible documents as "see stat module for
  full output of each dictionary." Integration tested
  (`spec/integration/stat_spec.cr`) and verified against real
  `ansible-playbook` via the compat harness (`compat/playbooks/18-stat.yml`
  - passed).
  - Building `stat` surfaced one real, previously-shipped, unrelated bug:
    boolean variables interpolated directly into template text (e.g.
    `{{ stat_result.stat.exists }}` in a `copy: content:`) rendered
    Crystal's lowercase `"true"`/`"false"` instead of Python/Jinja2's
    capitalized `"True"`/`"False"` - confirmed by diffing against real
    `ansible-playbook`'s actual rendered output, not assumed. Fixed in
    `VariableLookup#format_value` (used by all three of simple/nested/
    indexed lookup), unit tested
    (`spec/unit/variable_lookup_spec.cr`'s boolean-rendering group). This
    is distinct from `ComparisonEvaluator`'s own internal `"true"`/`"false"`
    protocol for `when:` truthiness, which already tolerated both cases
    and was left untouched.
- [x] `find` (`0.9.0`; `age`/`age_stamp`/`contains`/`read_whole_file` added
  in `0.9.37`): recursive file/directory search feeding `register:`,
  reusing `stat_fields.cr` for each match's stat dict. Parameters: `paths`
  (required, comma-separated), `patterns`/`excludes` (comma-separated
  shell globs, or regexes with `use_regex: true`, matched against the
  basename), `file_type` (`file` default/`directory`/`link`/`any`),
  `recurse`, `depth`, `hidden` (a hidden directory is skipped entirely
  when descending, not just direct dotfiles - matches real Ansible's
  `os.walk`-based behavior), `size` (with `b`/`k`/`m`/`g`/`t` suffix and
  negative-for-"at most" support), `age` (same negative-for-"at most"
  sign convention as `size`, with an `s`/`m`/`h`/`d`/`w` suffix - default
  seconds - verified against `find.py`'s own `agefilter()` source and
  `^(-?\d+)(s|m|h|d|w)?$` regex, not guessed), `age_stamp` (`atime`/
  `ctime`/`mtime`, default `mtime`), `contains` (a regex matched against a
  regular file's content, only when `file_type: file` - real Ansible's
  own restriction, verified against its source, not a scope cut here) and
  `read_whole_file` (default `false`: line-by-line, anchored at the start
  of each line via Python's `re.match()` semantics, replicated with a
  `\A`-prefixed Crystal `Regex` rather than Crystal's own unanchored
  default; `true`: search anywhere in the whole file, Python's
  `re.search()` semantics, Crystal's own default matching behavior),
  `get_checksum`/`checksum_algorithm`. `execute` threading a dozen
  separate filter arguments through itself and a same-shaped `match`
  helper pushed its own cyclomatic complexity over `ameba`'s threshold
  once `age`/`contains` joined the existing filters, so the parsed options
  now live in one `record Options` built once, rather than growing the
  parameter list further. Not implemented: `encoding`, `mode`, `limit` -
  all lower-value/rarer options than the core path+pattern+type+age+
  contains search that covers the overwhelming majority of real
  playbooks' `find:` usage. Read-only, never `changed`, like `stat`.
  Integration tested (`spec/integration/find_spec.cr`, 8 new examples:
  `age` positive/negative/`age_stamp`, `contains` line-anchored match/
  no-match/whole-file match/no-content-match, and `contains` being a no-op
  when `file_type` isn't `file`) and verified against real
  `ansible-playbook` via the compat harness (`compat/playbooks/19-find.yml`,
  extended with a `contains:` and an `age: "-1d"` task - passed, originally
  comparing `matched` counts rather than the `files` path list since
  crystal-ansible's filter engine didn't yet support the Jinja2
  `map(attribute=...)`/`sort` filters needed to format that list for a
  stable comparison - fixed once filter-chaining shipped, see the `0.9.42`
  entry near the end of Phase 5; `19-find.yml` now compares the actual
  sorted path list too).
  - Found and fixed one real bug of its own before it shipped: an unset
    `excludes:` (the common case) was checked with the same
    `matches_patterns?` helper used for `patterns:`, which returns `true`
    for an empty pattern list (correct for "no patterns given = match
    everything", wrong for "no excludes given = exclude nothing") -
    excluding every single result. Caught by comparing actual output
    against real `ansible-playbook` before considering this done, not by
    the unit tests (which exercised `matches_patterns?` correctly in
    isolation - the bug was in how `find`'s own `execute` used it for two
    different purposes with opposite empty-list semantics).
  - **Update (`0.9.15`):** both `stat` and `find` originally shelled out
    to `stat`/`md5sum`/`sha1sum`/`sha256sum`/`readlink`/`test -r`/`-w`/
    `-x`/`find` for operations Crystal's own standard library already
    supports natively (`LibC.stat`/`lstat`, `OpenSSL::Digest`,
    `File.readlink`/`realpath`, `File::Info.readable?`/`writable?`/
    `executable?`, `Dir.each_child`) - unlike plugins that shell out
    because Crystal has no equivalent library at all (`apt`/`dnf`/
    `archive`/`firewalld`), this was just an oversight, not a missing-
    capability gap, found while comparing this codebase's plugins
    against real Ansible's own Python module source. Converted both to
    native syscalls/hashing (`BasePlugin#native_stat`/`#native_checksum`,
    a rewritten `plugin_helpers/stat_fields.cr` building the stat hash
    from typed `LibC::Stat` fields instead of parsing `stat -c` shell
    output, and a `Dir.each_child`-based walker replacing the `find`
    shell command in `find.cr`). Benchmarked before and after: `stat`
    **3.8x** faster (31.6ms -> 8.3ms per call, was spawning 5
    subprocesses per call); `find` **35.3x** faster over a 320-file tree
    with checksums (5,005ms -> 142ms per scan, was spawning ~640
    subprocesses per scan - one `stat` + one checksum per matched file).
    Output verified byte-identical against real `ansible-playbook`
    before and after the conversion (mode, size, checksum, permission
    bits, symlink resolution, `find`'s `matched` count). Existing test suites
    (`spec/unit/stat_fields_spec.cr`, `spec/integration/stat_spec.cr`,
    `spec/integration/find_spec.cr`) pass unmodified in behavior; the
    unit spec was rewritten to exercise the new typed API instead of
    parsing synthetic `stat -c` strings.
- [x] `archive` (`0.9.1`): compresses/archives files and directories.
  Registered as `community.general.archive` - verified via `ansible-doc
  archive` that, unlike most plugins in this codebase, it does NOT ship
  with ansible-core (it lives in the separate community.general
  collection), an assumption that was initially wrong and had to be
  corrected after the fact. `PluginManager`'s FQCN-stripping regex
  extended to recognize the `community.general.` prefix too, alongside
  the existing `ansible.(builtin|legacy|posix)` handling. Parameters:
  `path` (required, comma-separated, shell-glob-aware), `dest`
  (required), `format` (`bz2`/`gz` default/`tar`/`xz`/`zip`),
  `force_archive`, `remove`, `exclusion_patterns` (comma-separated
  basename globs), `mode`/`owner`/`group` on the resulting dest file. A
  single regular file with a compression-only format (gz/bz2/xz) and no
  `force_archive:` is compressed directly, not wrapped in a tar - `tar`/
  `zip` formats and multi-path/directory inputs always build a real
  archive, matching real Ansible's own behavior exactly (verified, not
  assumed). `arcroot` is computed via a new
  `src/crystal_play/plugin_helpers/archive_paths.cr` (unit tested,
  `spec/unit/archive_paths_spec.cr`) replicating community.general's own
  `common_path()` formula bit-for-bit. Idempotency is checksum-based like
  real Ansible, but computed via shell tools (tar/zip listings + a
  content checksum) rather than replicating Python's tarfile per-member
  header checksum exactly. `exclude_path` (added `0.9.38`) is narrower
  than its name suggests - re-verified against the same real
  community.general 11.2.1 install's actual archived-members output
  (unchanged since the original "no-op" finding at `0.9.1`): it only
  drops an entry that exactly matches one of the top-level `path:` list
  items (real Ansible's own `self.paths = set(expanded_paths) -
  set(expanded_exclude_paths)`), never a file living *inside* a directory
  being archived - confirmed with two side-by-side real-Ansible runs, one
  targeting a file nested in an archived directory (no effect: both files
  still end up in the archive) and one targeting an exact top-level
  `path:` list entry (real effect: that entry is dropped). Implemented
  faithfully to that narrow behavior rather than left unimplemented -
  `exclusion_patterns:` (which does reach into a directory's own
  contents) remains the option for the common "skip this file" use case.
  The returned `expanded_paths:` result field stays unfiltered by
  `exclude_path:` either way, matching real Ansible's own observed
  output; `single_compress`'s own "how many paths are left" check was
  also switched from the raw expanded `path:` count to the
  exclude-filtered count, matching real Ansible's own `len(self.paths) >
  1` (which already read the *filtered* list, not the raw one - a detail
  exposed by adding `exclude_path:` support, not something visible
  before). Integration tested (`spec/integration/archive_spec.cr`, 3 new
  examples: the nested-file no-op, the top-level-entry exclusion, and
  `expanded_paths:` staying unfiltered) and verified against real
  `ansible-playbook` via the compat harness (`compat/playbooks/20-archive.yml`,
  extended with a two-top-level-path `exclude_path:` task - passed). Also
  not implemented: SELinux options, `unsafe_writes`.
  - Found and fixed three real bugs before shipping, all caught by
    diffing actual output against real `ansible-playbook`, not by unit
    tests in isolation:
    1. Passing a directory argument to `tar`/`zip` AND its own
       recursively-walked children as separate arguments double-included
       the children (tar/zip already recurse into any directory argument
       on their own). Fixed by reading community.general's actual
       `archive.py` source: a requested directory's own entry is never
       added as an archive member, only its descendants (`os.walk`
       adds every subdirectory/file it finds, never the walked root
       itself) - each member is now added individually with the
       archiver's own recursion disabled (`tar --no-recursion`; zip
       needs no `-r` since every member, files and subdirectories alike,
       is already listed explicitly).
    2. `arcroot` was computed via `File.dirname` on a trailing-slash
       path, silently wrong: Crystal's `File.dirname("/a/b/")` returns
       `/a` (one level up), while Python's `os.path.dirname("/a/b/")`
       returns `/a/b` (just strips the trailing slash) - real Ansible's
       `common_path()` formula relies on the latter. Fixed with a
       dedicated `python_dirname` helper.
    3. `exclusion_patterns` were matched against each member's full path
       relative to the archive root via `File.match?`, which doesn't let
       `*` cross `/` - a pattern like `*skip*` silently failed to match
       `sub/skip.txt`. Fixed by matching against the basename instead
       (same convention already used by `find`'s own `patterns:`/
       `excludes:`).
  - Verified against real `ansible-playbook` via the compat harness
    (`compat/playbooks/20-archive.yml` - passed): single-file
    compress-only, whole-directory tar.gz, an idempotent rerun,
    `exclusion_patterns:`, and a partial run with a missing path mixed
    in, compared via `dest_state`/`changed` plus each archive's own `tar
    tzf`/`unzip -Z1` listing (sorted - member order isn't a contract
    either engine guarantees) and decompressed content. Required adding
    `bzip2`/`xz-utils`/`zip`/`unzip` and the `community.general`
    collection to `compat/Dockerfile`.
  - **Update (`0.9.16`):** `tar`/`gz`/`zip` formats converted from
    shelling to the `tar`/`gzip`/`zip` CLIs to native Crystal: `zip` via
    the stdlib's `Compress::Zip`, `tar`/`gz` via `naqvis/crystar` (a new
    direct `shard.yml` dependency, previously only transitive via
    `docr`) wrapped in `Compress::Gzip::Writer` for `gz`. `bz2`/`xz`
    still shell to `tar`/`bzip2`/`xz` - no native Crystal library exists
    for either. Benchmarked before/after against the shell CLIs at two
    scales (320 and 2000 files): `zip` won outright at both (1.6x faster
    both times); `tar`/`gz` won small (1.3-1.4x, subprocess-spawn
    overhead dominates) but lost at 2000 files (1.3-2.0x *slower* than
    real `tar`/`gzip`'s optimized C). Investigating further revealed
    that comparison was measuring the wrong baseline: real Ansible's own
    `community.general.archive` doesn't shell out either - it builds
    archives with Python's `tarfile`/`zipfile` stdlib, which, like
    `crystar`, is pure-language rather than C-accelerated. Benchmarking
    against what real Ansible actually does (Python 3.13 `tarfile`, same
    2000-file tree) rather than the `tar`/`gzip` CLIs it doesn't use:
    crystal-ansible's native tar is **1.3x faster** than real Ansible
    (259ms vs. 347.7ms) and native gz is **2.7x faster** (176ms vs.
    475.4ms). Existing `archive`/`unarchive` test suites
    (29 examples) pass unmodified in behavior.
  - **Update (`0.9.17`):** `xz` also converted to native, after a closer
    shard search than the one that produced the `0.9.16` note above
    turned up `naqvis/xz.cr` - a real `liblzma` C binding (reader +
    writer), not the shell-wrapper dead end the same search found for
    `bz2` (`jhbadger/Bzip`: shells to `bzcat`, read-only, unmaintained
    since 2017 - genuinely nothing usable there, `bz2` stays shell-based).
    New direct dependency, requires `liblzma-dev` at build time (same
    pattern as the existing `libssl-dev` requirement for
    `OpenSSL::Digest`). Unlike `gz` (pure-Crystal `Compress::Gzip` losing
    to C at scale), `xz.cr` binds the same optimized `liblzma` the real
    `xz` CLI uses, so it doesn't hit that scaling problem: native won
    outright at both benchmarked scales (320 files: 67.4ms -> 53.2ms,
    **1.27x**; 2000 files: 297.5ms -> 277.9ms, **1.07x**), no Ansible-
    baseline reframing needed. Correctness verified against the real
    `tar`/`xz` CLIs in both directions (native output readable by real
    `tar`/`xz`; a real-CLI-built `tar.xz` readable as a pre-existing
    `dest`) plus idempotent-rerun behavior. Full project suite (495 examples) passes.
  - **Update (`0.9.18`):** `bz2` converted too - the shard search that
    came up empty for it in `0.9.16` was checked again more thoroughly
    and confirmed genuinely empty (`jhbadger/Bzip` really is just a
    `bzcat` shell wrapper with no writer), so a real one was written from
    scratch: [`weirdbricks/bz2.cr`](https://github.com/weirdbricks/bz2.cr),
    a new public shard binding `libbz2` directly, modeled on `naqvis/xz.cr`'s
    own `Writer`/`Reader` design (bzlib's C API is simpler than lzma's -
    no filter chains/presets, just a block size and work factor - so most
    of xz.cr's structure carried over with small adjustments). Requires
    `libbz2-dev` at build time. No archive format shells out anymore.
    Like `xz.cr`, `bz2.cr` binds a real C library rather than
    reimplementing the algorithm, so it doesn't hit `gz`'s scaling
    problem either: native won outright at both benchmarked scales (320
    files: 37.3ms -> 23.4ms, **1.59x**; 2000 files: 139.8ms -> 121.6ms,
    **1.15x**). Correctness verified the same way as `xz` (round-trip
    against real `bzip2`/`tar` CLIs in both directions, idempotent rerun,
    reading a pre-existing real-CLI-built archive). `bz2.cr` has its own
    8-example spec suite. Full project suite (495 examples) passes.
- [x] `unarchive` (`0.9.2`): extracts an archive into an existing
  directory - the counterpart to `archive`, but registered as
  `ansible.builtin.unarchive` (verified via `ansible-doc unarchive`),
  unlike `archive` itself which lives in `community.general`. Parameters:
  `src`/`dest` (both required), `creates` (skip entirely if this path
  already exists, same idempotency shortcut `command:`/`shell:` already
  support), `exclude`/`include` (comma-separated, passed straight through
  to tar's `--exclude`/zip's `-x` and file-list args - real tar/zip's own
  path-vs-basename matching semantics apply, verified against real
  `ansible-playbook`, which itself just forwards these the same way),
  `keep_newer`, `list_files`, `mode`/`owner`/`group` (applied to the
  *destination directory itself*, not per extracted file - verified
  against real `ansible-playbook`'s actual return value shape, not
  assumed). `dest` must already exist as a directory - crystal-ansible
  fails with the same message real Ansible does rather than
  auto-creating it, matching real behavior exactly.
  - Archive type is auto-detected by attempting to read it (`tar tf`,
    then `unzip -l` as a fallback) rather than by file extension - this
    matches real Ansible's own `can_handle_archive` handler-probing
    approach (confirmed by reading the actual `unarchive.py` source, not
    assumed), and means GNU tar's own compression auto-detection handles
    gz/bz2/xz/plain tar uniformly without needing a `format:` parameter
    the way `community.general.archive` needs one.
  - Idempotency for tar-based archives uses `tar --compare` against
    `dest` - the exact mechanism real Ansible's own `TgzArchive#is_unarchived`
    uses (confirmed via source, then verified empirically: `tar --compare`
    exits 0 with no output when nothing differs, exits 1 with a diff line
    when something does). For zip, a simpler per-member content-checksum
    comparison is used instead of replicating real Ansible's much more
    involved zipinfo/permission-based check - a documented approximation,
    not a claim of bit-for-bit parity.
  - Unit/integration tested (`spec/integration/unarchive_spec.cr`) and
    verified against real `ansible-playbook` via the compat harness
    (`compat/playbooks/21-unarchive.yml` - passed): tar.gz extraction,
    an idempotent rerun, zip extraction, `exclude:`, and `creates:`,
    compared via `changed`/`handler` (the raw extracted archive files
    themselves are deleted before the snapshot for the same
    non-byte-comparable-binary reason `archive`'s compat playbook
    already documents).
- [x] `file` (`0.3.0`, converted to native syscalls in `0.9.19`): the
  `directory`/`file`/`link`/`hard`/`touch`/`absent` states, originally
  built by shelling to `mkdir -p`/`test -f`/`test -e`/`readlink`/
  `rm -f`/`rm -rf`/`ln -s`/`ln`/`touch`/`stat -c '%U'`/`'%G'`/`'%a'`/
  `chown`/`chgrp`/`chmod` (27 separate `remote_exec` calls across the
  file). A broader survey of every plugin's shell-out sites (looking for
  more `stat`/`find`-style oversights, as opposed to genuine
  missing-binding gaps like `apt`/`dnf`) found `file.cr` was by far the
  biggest one - every one of those calls has a direct Crystal stdlib
  equivalent (`Dir.mkdir_p`, `File.exists?`/`File.file?`,
  `File.readlink`, `File.delete?`/`FileUtils.rm_rf`,
  `File.symlink`/`File.link`, `File.utime`, a raw `LibC.lstat` for
  current mode/owner/group since `File::Info#permissions.value` strips
  the setuid/setgid/sticky bits, `File.chown`/`File.chmod` for numeric
  mode). One narrow gap remains by design: *symbolic* mode (`u+x`,
  `go-w`) still shells to real `chmod` to apply - correctly
  reimplementing chmod(1)'s symbolic grammar is separate scope, and it
  was already the weakest-supported path pre-conversion (change
  detection for it was already just an always-mismatching string
  compare). A subtle behavior split was deliberately preserved rather
  than "fixed": GNU `stat -c` without `-L` doesn't follow symlinks while
  `test -e`/`test -f` do, and the original shell version relied on
  exactly that split - the native version keeps it
  (`File.exists?`/`File.file?` follow, `LibC.lstat` doesn't). Also
  found (not introduced) and deliberately left alone: `state: file`'s
  `modification_time`/`access_time` only take effect when
  `owner`/`group`/`mode` also change, since `update_times` sits inside
  the same `if changed` guard as `apply_file_attributes` - a
  pre-existing bug in the shell version too, out of scope for a
  mechanical conversion.
  - No dedicated spec suite existed for `file.cr` before this - new
    `spec/integration/file_spec.cr` (21 examples) covers all six
    states, idempotency, check mode, force-overwrite, symbolic mode,
    setuid/setgid/sticky preservation, and `recurse:`.
  - Benchmarked each state's single-invocation cost (200 iterations
    each, comparing the compiled plugin binary before/after): 2.5x-4.9x
    faster across every state (`state: link`'s create path, with three
    shelled-out checks per call in the old version, shows the largest
    win at **4.85x**). Full project suite (516 examples) passes.
- [x] `apt_repository` (`0.9.3`): adds/removes a Debian/Ubuntu APT source
  line under `/etc/apt/sources.list.d/`. Parameters: `repo` (a plain
  `deb`/`deb-src` line, required), `state`, `filename`, `update_cache`
  (default true), `mode`, `check_mode`. Idempotency checks whether the
  normalized line already appears, enabled, in `/etc/apt/sources.list`
  or any `sources.list.d/*.list` file, not just the target file - matches
  real Ansible's own `SourcesList`, which reads all of them before
  deciding whether an add/remove is a no-op. The default filename is
  derived by a new `src/crystal_play/plugin_helpers/apt_repository_line.cr`
  (unit tested, `spec/unit/apt_repository_line_spec.cr`) that replicates
  real Ansible's own `_suggest_filename` logic exactly - verified by
  reading `apt_repository.py`'s actual source and cross-checking output
  against a direct Python re-implementation of it for several inputs, not
  assumed from docs. Since writing to `/etc/apt/` needs root,
  `spec/integration/apt_repository_spec.cr` exercises `check_mode` only
  (same convention `user_spec.cr`/`group_spec.cr` already use), with the
  real add/remove/idempotency path verified via the compat harness
  instead (`compat/playbooks/22-apt-repository.yml` - passed).
  - Found and fixed a real bug via that compat playbook: `grep -v`
    exits 1 (not just "no lines found *by* -v", but "-v selected zero
    lines to print") whenever a filter removes every line from its
    input - the common case when removing a repo from a single-line
    file. The remove logic was `grep -v ... > tmp && mv tmp file`,
    so that `&&` silently skipped the `mv` on exactly this common case,
    leaving the file untouched while still reporting `changed: true`.
    Caught by running a removal twice in a row against real
    `ansible-playbook` and finding crystal-ansible reported `changed:
    true` both times (real Ansible correctly reported `true` then
    `false`). Fixed by using `;` instead of `&&`.
  - `ppa:` shorthand and `codename:` were added in `0.9.47` - see that
    entry near the end of Phase 5. Not implemented:
    `install_python_apt` (crystal-ansible never shells out to python-apt
    in the first place), `validate_certs`,
    `update_cache_retries`/`update_cache_retry_max_delay`.
- [x] `yum_repository` (`0.9.3`): writes a `.repo` INI file under
  `/etc/yum.repos.d/`. Parameters: `name` (required, the INI section),
  `description` (required when `state: present` - real Ansible validates
  this explicitly, confirmed via actual error message text, not assumed;
  written as the file's `name =` key, a real, confirmed quirk - the
  module's own `name` param is the id/section, `description` is what
  ends up as the `name=` field), at least one of `baseurl`/`mirrorlist`/
  `metalink` (also required, same explicit-validation-message pattern),
  `gpgcheck`/`enabled` (booleans, rendered as `1`/`0`), `gpgkey`/
  `exclude`/`includepkgs` (lists, space-joined on one line), `priority`,
  `state`, `file` (defaults to `name`), `reposdir` (defaults to
  `/etc/yum.repos.d`), `mode`/`owner`/`group`. Each run regenerates the
  INI section from scratch using only the parameters given *that* run -
  verified against real `ansible-playbook`: rerunning with a different
  parameter set drops keys that were present before but aren't passed
  this time, which is real Ansible's actual behavior, not something to
  "fix". Unlike `apt_repository`, this plugin only writes plain files (no
  root needed, no real yum/dnf required either - it's pure file I/O), so
  `spec/integration/yum_repository_spec.cr` exercises the real
  add/idempotency/rewrite/remove paths directly, all verified
  field-for-field and byte-for-byte against real `ansible-playbook`'s
  actual file output before being written. Also verified via the compat
  harness (`compat/playbooks/23-yum-repository.yml` - passed). Not
  implemented: the many lower-value/rarer yum.conf tuning knobs (`async`,
  `bandwidth`, `cost`, `deltarpm_*`, `http_caching`, `ip_resolve`,
  `keepalive`, `keepcache`, `metadata_expire*`, `module_hotfixes`,
  `protect`, `repo_gpgcheck`, `retries`, `s3_enabled`,
  `skip_if_unavailable`, `ssl*`, `throttle`, `timeout`, `ui_repoid_vars`,
  `username`/`password`/`proxy_*`, `unsafe_writes`, `countme`,
  `enablegroups`, `failovermethod`, `include`), SELinux options,
  `attributes`.
- [x] `sysctl` (`0.9.4`): manages a `key=value` entry in a sysctl config
  file, optionally applying it to the running kernel. Parameters: `name`
  (required), `value` (required when `state: present`), `state`,
  `sysctl_file` (default `/etc/sysctl.conf`), `sysctl_set` (also runs
  `sysctl -w` against the running kernel, default false), `reload` (runs
  `sysctl -p <file>` when the file changed, default true - matching real
  Ansible's own default), `ignoreerrors`, `check_mode`. File rewrite
  logic verified by reading the real `ansible.posix` `sysctl.py` source
  directly, not assumed from docs: comments/blanks pass through
  untouched, only the first occurrence of a duplicated key survives a
  rewrite, `state: absent` drops the key's line entirely (not commented
  out). Since `sysctl_file` is a plain parameter (not hardcoded, unlike
  `apt_repository`'s sources.list paths), the real add/update/idempotency/
  remove path is fully testable without root by pointing at a throwaway
  file (`spec/integration/sysctl_spec.cr`), with `reload: false` used
  throughout to avoid ever touching the real running kernel. Verified
  byte-for-byte against real `ansible-playbook`'s actual file output for
  update/append/idempotent-rerun/absent, and via the compat harness
  (`compat/playbooks/24-sysctl.yml` - passed).
- [x] `mount` (`0.9.4`): manages `/etc/fstab` entries and (optionally)
  actually mounts/unmounts a filesystem. Parameters: `path` (required),
  `src`/`fstype` (required when `state: present` or `mounted` - verified
  against real Ansible's actual `required_if`, not assumed), `opts`
  (default `defaults`), `dump`/`passno` (default `0`), `boot` (default
  true - false appends `noauto` to `opts`, matching real Ansible's
  behavior exactly, verified against actual output), `fstab` (default
  `/etc/fstab`), `backup`, `state` (`present`/`absent`/
  `absent_from_fstab`/`mounted`/`unmounted`/`remounted` - `remounted`
  added `0.9.45`, see that entry near the end of Phase 5), `check_mode`.
  Fstab line format and idempotency (matched by `path`, comparing
  src/fstype/opts/dump/passno field-by-field, updating the matching line
  in place rather than removing+re-appending) verified by reading the
  real `ansible.posix` `mount.py` source directly. Like `sysctl`, `fstab:`
  is a plain overridable parameter, so `present`/`absent`/
  `absent_from_fstab` are fully tested for real without root
  (`spec/integration/mount_spec.cr`); `mounted`/`unmounted` (which run
  real `mount`/`umount`) are exercised via `check_mode` only, matching
  `user_spec.cr`/`group_spec.cr`'s established convention. Verified
  byte-for-byte against real `ansible-playbook`'s actual fstab output,
  and via the compat harness (`compat/playbooks/25-mount.yml` - passed).
  `ephemeral` state (its own device-source-conflict-checking logic)
  shipped in `0.9.49`, see that entry near the end of Phase 5. Not
  implemented: Solaris/BSD vfstab handling (Linux fstab format only).
  - Caught and fixed one bug in self-review before it ever reached
    testing: `check_mode` originally only guarded the actual
    mount/umount step, not the fstab file write itself - so `--check`
    would still really rewrite `/etc/fstab`. Fixed by threading
    `check_mode` through the fstab-writing path too, with a regression
    test (`spec/integration/mount_spec.cr`) asserting the file is
    byte-for-byte untouched in check mode.
- [x] `ufw` (`0.9.5`; `insert_relative_to` added in `0.9.39`): manages the
  Uncomplicated Firewall. Registered as `community.general.ufw`, not
  `ansible.builtin.ufw` - verified via `ansible-doc ufw`. Parameters:
  `state` (`enabled`/`disabled`/`reloaded`/`reset`), `logging`, `default`
  (+ `direction`), `rule` (`allow`/`deny`/`reject`/`limit`) plus
  `direction`/`interface`/`interface_in`/`interface_out`/`log`/`from_ip`/
  `from_port`/`to_ip`/`to_port`/`proto`/`name` (app profile)/`comment`/
  `delete`/`insert`/`insert_relative_to` (`zero` default/`first-ipv4`/
  `last-ipv4`/`first-ipv6`/`last-ipv6`)/`route`, `check_mode`. A non-`zero`
  `insert_relative_to:` needs the *actual* rule-number arithmetic, not
  just a command-shape template like every other parameter here: it first
  runs `ufw status numbered` and parses it (`^\[\s*(\d+)\]\s` per line,
  `(v6)` marking an IPv6 rule), then resolves `insert:` to an absolute
  position via the exact same computation as community.general's own
  source (including its "no ipv4/ipv6 rules yet" fallback positions and
  its insert-past-the-last-rule-means-just-append-instead behavior,
  since real `ufw` itself rejects an insert number larger than the
  maximum rule number) - copied field-for-field from `ufw.py`, not
  derived from the docs' prose, and cross-checked against a direct Python
  re-implementation of that same source for 9 inputs covering all four
  non-`zero` values, an empty ruleset, and the past-the-end case, not
  just eyeballed. Lives in `PluginHelpers::UfwCommand.resolve_insert`
  (unit tested, `spec/unit/ufw_command_spec.cr`'s own describe block),
  with the plugin resolving it once via `remote_exec("ufw status
  numbered")` before building the rule command, only when
  `insert_relative_to:` isn't the (common, no-query-needed) `zero`
  default. Command shape (the "long format":
  `ufw [--dry-run] [route] [delete | insert NUM]
  allow|deny|reject|limit [in|out on INTERFACE] [log] [from ADDRESS
  [port PORT]] [to ADDRESS [port PORT]] [proto protocol] [app
  application] [comment COMMENT]`) and the "Skipping" no-op signal
  verified by reading community.general's actual `ufw.py` source
  directly. Pure command-construction logic extracted into a new
  `src/crystal_play/plugin_helpers/ufw_command.cr`, unit tested
  (`spec/unit/ufw_command_spec.cr`) - a real bug was caught writing those
  tests: `from_ip`/`from_port`/`to_ip`/`to_port` are four *independent*
  appends in real Ansible's source (a flat list of key/template pairs,
  each checked on its own), not two ip+port pairs - a port given without
  its matching ip is still appended alone, which an initial
  ip-gated implementation got wrong.
  - **Not compat-harness verified, unlike every other plugin in this
    codebase.** `ufw` refuses to run at all without root - even a bare
    `ufw status` fails with "ERROR: You need to be root to run this
    script" - and the compat harness's container lacks working netfilter
    access even running as root (confirmed: `ufw status` fails inside it
    with an iptables permission error unrelated to ufw itself).
    Confirmed this isn't a crystal-ansible-specific gap: running real
    `ansible-playbook`'s own `community.general.ufw` module against the
    exact same container, even in `--check` mode, fails identically
    (`ERROR: problem running iptables: ... Permission denied`) - so no
    engine could be verified end-to-end here. Test coverage is unit
    tests on the pure command-building logic only.
- [x] `firewalld` (`0.9.5`): manages firewalld zone configuration.
  Registered as `ansible.posix.firewalld`. Parameters: `zone`, `state`
  (`enabled`/`present` add, `disabled`/`absent` remove), `permanent`,
  `offline`, plus exactly one of `service`/`port`/`rich_rule`/`source`/
  `masquerade` (matching real Ansible's own `mutually_exclusive`
  constraint), `check_mode`. Only `offline: true, permanent: true` is
  implemented - this is real Ansible's own "offline mode", which edits
  firewalld's on-disk zone XML via the `firewall-offline-cmd` companion
  tool without needing a running firewalld daemon at all, unlike the
  more common live/D-Bus mode (`offline: false`, the real default) which
  needs an actual running `firewalld` service - the same category of gap
  already excluded for `service:` in this codebase (no init system in
  the compat container). A task without `offline: true` fails with a
  clear message. `firewall-offline-cmd`'s exact command shape and
  quirks - none of which `ansible-doc` documents, since they belong to
  the underlying CLI tool, not the Ansible module - were verified
  empirically against a real firewalld 2.1.1 install in a real
  container, in a new `src/crystal_play/plugin_helpers/firewalld_command.cr`
  (unit tested, `spec/unit/firewalld_command_spec.cr`):
  `--query-<thing>=<value>` exits 0/prints "yes" when present, exits
  1/prints "no" when absent (used for idempotency); `service` removal
  needs the special `--remove-service-from-zone=` form - the plain
  `--remove-service` is a legacy "lokkit" option that flatly refuses to
  combine with `--zone=` at all (a real, confirmed error: "Can't use
  lokkit options with other options") - while `port`/`rich_rule`/
  `source`/`masquerade` removal use the ordinary `--remove-<thing>=`
  form directly.
  - Found and fixed a real bug before it shipped: rule values were
    interpolated into the shell command unquoted, which broke on a
    `rich_rule` value (containing both spaces and embedded double
    quotes, e.g. `rule family="ipv4" source address="..." accept`)
    against a real `firewall-offline-cmd` - caught by actually running it
    in a container, not by unit tests in isolation. Fixed by
    single-quoting every value (double quotes would conflict with a
    rich_rule's own embedded double quotes; single quotes don't need
    escaping them).
  - Unlike `ufw`, this one *is* genuinely verified end-to-end: offline
    mode needs no daemon and no special container capabilities, so both
    real `ansible-playbook` and crystal-ansible run it for real via the
    compat harness (`compat/playbooks/26-firewalld.yml` - passed):
    enabling a service, an idempotent rerun, a rich rule, masquerade,
    disabling the service, and an idempotent disable rerun - compared via
    `changed` plus `--query-<thing>` state checks (not a raw zone-file
    diff: real Ansible's own module leaves the zone XML in a very
    slightly different but behaviorally identical shape - a bare
    `<forward/>` element sometimes survives one path and not the other,
    cosmetic but noisy to diff directly).
- [x] `docker_image` / `docker_network` / `docker_container` (`0.9.12`):
  unlike almost everything else in this codebase, these don't shell out
  to a CLI (`docker`) - like real Ansible's own `community.docker`
  collection, they talk to the Docker Engine API directly over its UNIX
  socket. No maintained Crystal shard for this existed: the two most
  visible candidates (`jeromegn/docker.cr`, `place-labs/crystal-docker`)
  have been unmaintained since 2021; `marghidanu/docr` (last pushed
  2026-06-24) was close but, verified by actually exercising it against a
  real running daemon rather than just reading its code, had a
  connection-lifecycle bug serious enough to make it unusable for a
  multi-call module like this (see below). Forked to
  [weirdbricks/docr](https://github.com/weirdbricks/docr) with the
  authors' blessing, fixed there, and depended on directly
  (`github: weirdbricks/docr` in `shard.yml`) rather than vendoring a
  copy - PR upstream still pending.
  - **Bugs found and fixed in the fork, each reproduced against a real
    daemon before and after** (this sandbox's Podman, in rootless mode,
    which speaks the same Docker Engine API): (1) `Client` wrapped a
    single `UNIXSocket` into `HTTP::Client.new(io)`, which Crystal's
    stdlib marks non-reconnectable - any realistic sequence of calls
    (create, then start, then inspect) eventually hit `"This HTTP::Client
    cannot be reconnected"` once the daemon closed the connection or a
    response body wasn't fully drained. Fixed by subclassing
    `HTTP::Client` and overriding its private `#io` to lazily open a
    fresh socket on demand - the same pattern `HTTP::Client` itself
    already uses to reconnect over TCP/TLS (and the same pattern this
    workspace's own `dirless-http` `TargetedClient` uses for its own
    custom-transport override, independently arrived at). (2) Added
    `DOCKER_HOST` env var support - the hardcoded
    `/var/run/docker.sock` isn't reachable at all under rootless
    Docker/Podman. (3) `Images#push`'s block referenced an undefined
    `response` (no block parameter) - a compile-time `NameError` the
    moment it was actually called; fixed, and wired up the `tag:`/
    `X-Registry-Auth` header it was supposed to send but didn't. (4)
    `LogConfig#config` was typed as non-nullable, but a real daemon can
    return `"Config": null` there (confirmed against Podman's journald
    driver) - `ContainerInspectResponse.from_json` then raises on any
    `inspect` call whose container has a null `LogConfig.Config`, which
    in practice is most containers. Made nullable. (5)
    `Images#delete`'s `force:`/`no_prune:` params were accepted but never
    applied to the request - a `force: true` delete call silently behaved
    like `force: false`.
  - Reused across all three: `Docr::Client`/`Docr::API` for the
    connection and typed *request*-building types (`CreateContainerConfig`,
    `HostConfig`, `NetworkConfig`, `RestartPolicy`, `PortBinding` - safe
    since we control what goes into them, no daemon-response-shape risk).
    For *reading* daemon state, existence checks use a raw
    `Docr::Client#call` (ignoring the body) rather than trusting docr's
    typed `Images#inspect`/`Image` response type, which hasn't been
    exercised as thoroughly as `ContainerInspectResponse` now has -
    deliberately conservative given bug (4) above was exactly this class
    of problem. `ContainerSummary` (from `Containers#list`) is used for
    idempotency instead of a full `inspect`, since it already has
    everything needed (image, command, running state) without pulling in
    the larger, more failure-prone type graph.
  - `docker_image`: `name:`/`tag:` (via a new pure
    `src/crystal_play/plugin_helpers/docker_ref.cr`, unit tested,
    `spec/unit/docker_ref_spec.cr` - also handles the Podman-vs-Docker
    `docker.io/library/` prefix quirk found while testing, via a lenient
    `same?` comparison), `source:` (required when `state: present`,
    verified against real Ansible's own `required_if` - only `pull` is
    implemented, not `build`/`load`/`local`), `state:` (`present`/
    `absent`). Idempotency is presence-only, no digest/update checking.
  - `docker_network`: `name:` (required), `driver:` (default `bridge`),
    `internal:`, `attachable:`, `labels:`, `state:`. Idempotent by name;
    a driver mismatch on an existing network triggers a delete+recreate
    (Docker has no in-place driver change). Not implemented: `connected:`
    (docr itself doesn't implement `NetworkConnect`/`NetworkDisconnect`
    yet), `ipam_config:`, `enable_ipv6:`.
  - `docker_container`: `name:` (required), `image:` (required only when
    a container actually needs to be created/recreated - verified
    against real `ansible-playbook` that `state: stopped`/`absent` on an
    already-existing container needs no `image:` at all, and matched
    that exactly rather than assuming), `state:` (`started`/`stopped`/
    `present`/`absent`), `command:`/`entrypoint:` (plain string, naively
    whitespace-split - same documented limitation as
    `ansible.builtin.command`'s own `cmd:`), `env:`/`labels:` (dicts),
    `ports:` (via a new pure
    `src/crystal_play/plugin_helpers/docker_ports.cr`, unit tested,
    `spec/unit/docker_ports_spec.cr` - handles `host_port:container_port`,
    `host_ip:host_port:container_port`, and a `/udp`-style proto suffix),
    `volumes:` (passed through as Docker's own `Binds:` syntax),
    `restart_policy:`, `network_mode:`, `privileged:`/`auto_remove:`,
    `pull:` (default true), `recreate:` (force recreate even if
    unchanged). Idempotency compares only image (leniently) and command
    against the existing container - and only for whichever of those two
    was actually given, matching real Ansible's "only compare what you
    told me about" behavior - not the ~40-field comparison real Ansible's
    `docker_container` does; any other drifted setting won't trigger a
    recreate on its own without `recreate: true`. A documented, deliberate
    scope cut given the size of that surface. Not implemented: `networks:`
    (multi-network attach - same docr gap as above), `healthcheck:`,
    resource limits, `comparisons:`.
  - Verified end-to-end against a real daemon repeatedly by hand (image
    pull/idempotent/remove/idempotent; network create/idempotent/remove;
    container create+start/idempotent/stop/idempotent/start again/
    recreate-on-command-change/remove/idempotent; ports and volumes
    landing correctly per `docker inspect`) before writing any automated
    test. Integration tested via the CLI against the same real daemon
    (`testing/test-docker-quick.yml` targeting `testservers`, like
    `test-copy.yml`/`test-async-quick.yml`, so a `--check` run against the
    generic empty inventory skips the whole play rather than needing a
    daemon) + `spec/integration/cli_spec.cr`, and verified task-for-task
    against real `ansible-playbook` running the identical fixture -
    output matched exactly, including the `image:`-not-required-to-stop
    behavior above (found by testing against real Ansible, not assumed).
    Requires a real Docker Engine API (Docker or rootless Podman, the
    latter already a hard dependency of `compat/Dockerfile`, so not a new
    requirement for this project) reachable from wherever the play runs -
    not verified/skippable like `ufw`'s environment-constrained entry.
- [x] `mysql_db` / `mysql_user` (`0.9.13`): like the Docker plugins above,
  talks to the server directly over MySQL's own wire protocol (real
  Ansible's `community.mysql` does the same, via PyMySQL) rather than
  shelling out to the `mysql` CLI. No maintained third-party Crystal
  MySQL shard exists, but the official `crystal-lang/crystal-mysql` (+
  `crystal-lang/crystal-db`) does - actively maintained, so used
  directly rather than hunting for alternatives. Verified by actually
  connecting to real running MySQL 8.4 and MariaDB 11 servers rather than
  trusting the README: found it couldn't complete a handshake against
  either at all (long-open upstream issues #62/#99/#123). Forked to
  [weirdbricks/crystal-mysql](https://github.com/weirdbricks/crystal-mysql)
  and fixed there (depended on directly via `shard.yml`, not vendored;
  PR upstream still pending):
  - **caching_sha2_password** (MySQL 8's default auth plugin since 8.0,
    and the *only* one available at all since MySQL removed
    `mysql_native_password` support entirely in 8.4) wasn't implemented -
    the driver only ever declared/computed `mysql_native_password`'s
    challenge-response, so any MySQL 8+ server with default settings
    couldn't authenticate at all (`"packet 254 not implemented"`,
    matching upstream issue #62 - that's the AuthSwitchRequest the server
    sends when the client's guessed plugin is wrong). Fixed by capturing
    the server's actual declared plugin from the handshake (previously
    read and discarded) and implementing both plugins' scramble algorithm
    (verified against PyMySQL's own reference implementation) plus a
    proper AuthSwitchRequest/AuthMoreData state machine - AuthMoreData's
    "full authentication required" sub-case is answered with the
    plaintext password once the channel is already secure (TLS or a unix
    socket), the correct MySQL protocol response there, not a shortcut;
    over a genuinely plaintext, unencrypted TCP connection with a cold
    server-side cache, completing it would need an RSA public-key
    exchange this driver doesn't implement, so that specific combination
    raises a clear error instead of failing deep in a confusing spot.
  - Separately, `write_ssl_request` declared a reduced capability-flag
    subset compared to the real handshake response that followed it -
    some servers hold the client to whatever it announced in the
    SSLRequest for the rest of the connection, so this mismatch got the
    real handshake rejected with `"Client does not support authentication
    protocol requested by server"` under any SSL mode other than
    `disabled`, reproduced against both real MySQL 8.4 and MariaDB 11.
    Fixed by declaring the identical capability set in both packets.
  - The upstream spec suite (run against a live MariaDB 11 instance, not
    part of this project but used to sanity-check the fork didn't
    regress anything) goes from 9 failures/errors on unmodified upstream
    to 7 with this fork - the 2 now-passing were both broken by the
    SSLRequest bug above; the remaining 7 are pre-existing MariaDB
    11-vs-MySQL environment differences (a newer default collation name,
    `performance_schema.session_status` behaving differently, and an
    `Int32`-vs-`Int64` `BIGINT` read mismatch already tracked in issue
    #99), confirmed identical against unmodified upstream.
  - `mysql_db`: `name:` (required), `state:` (`present`/`absent`),
    `encoding:`/`collation:` (validated as bare identifier-safe
    characters only, since they can't go through a bind parameter),
    `login_host:`/`login_port:`/`login_user:`/`login_password:`/
    `login_unix_socket:` (a new pure
    `src/crystal_play/plugin_helpers/mysql_connection.cr`, unit tested,
    builds the connection URI - `login_unix_socket:` takes precedence
    over `login_host:`/`login_port:` when given; also always forces
    `ssl-mode=disabled` on the connection - see the `0.9.40` entry near the
    end of this file for why). `state: dump`/`import` (mysqldump-based
    backup/restore, `0.9.40`; `.bz2`/`.xz` compression added in `0.9.43`)
    - see those entries for the full writeup. Not implemented: `.zst`
    compression (no Crystal zstd binding is vendored in this codebase
    yet), `config_file:` (`~/.my.cnf` credential lookup).
  - `mysql_user`: `name:` (required), `password:` (only applied when
    creating a new user, or when an existing user's password is updated
    under `update_password: always`, the default - matching real
    Ansible's own default, though unlike real Ansible this can't compare
    password hashes to stay idempotent, so it reissues `ALTER USER ...
    IDENTIFIED BY` and reports `changed: true` every time a `password:`
    is given for an existing user; `update_password: on_create` avoids
    this if password drift-detection isn't needed - a documented
    simplification, not an oversight), `host:` (default `"localhost"`,
    verified against real Ansible's own default - not `"%"`), `state:`
    (`present`/`absent`), `priv:` (`"db.table:PRIV1,PRIV2"`, multiple
    grants separated by `/`, same format real Ansible uses - via a new
    pure `src/crystal_play/plugin_helpers/mysql_privileges.cr`, unit
    tested against real `SHOW GRANTS` output captured from a live
    MariaDB server, including the always-present `GRANT USAGE ON *.*`
    identity row every account has regardless of actual privileges,
    which has to be filtered out rather than compared against). A
    privilege mismatch `REVOKE`s everything and re-`GRANT`s the whole
    desired set from scratch rather than computing a minimal add/remove
    delta - simpler, and just as idempotent, just not the smallest
    possible set of statements. Not implemented: `update_password:
    on_new_username`, `plugin:`/`plugin_hash_string:`/
    `plugin_auth_string:` (non-password auth methods), `append_privs:`/
    `subtract_privs:`, `host_all:`, `resource_limits:`, `locked:`,
    `config_file:`.
  - Verified end-to-end against real running MySQL 8.4 and MariaDB 11
    servers by hand (database create/idempotent/remove/idempotent; user
    create/idempotent, privilege set/idempotent/changed, remove/
    idempotent) before writing any automated test. Integration tested
    via the CLI against the same real MariaDB server
    (`testing/test-mysql-quick.yml` targeting `testservers`, like
    `test-docker-quick.yml`) + `spec/integration/cli_spec.cr`, and
    verified task-for-task against real `ansible-playbook` (via a Python
    venv with PyMySQL installed, since this environment's system Python
    is externally managed) running the identical fixture - output
    matched exactly.
- [x] `postgresql_db` / `postgresql_user` (`0.9.14`): same architecture as
  the MySQL/Docker plugins above - talks to the server directly over
  PostgreSQL's own wire protocol (real Ansible's `community.postgresql`
  does the same, via psycopg2) rather than shelling out to `psql`/
  `pg_dump`. Unlike the MySQL driver, **no fork was needed**:
  [will/crystal-pg](https://github.com/will/crystal-pg) (479 stars, used
  by 494 projects, pushed within the week this was written, and
  independently already a dependency of this workspace's own
  `dirless-ops` via `granite`) connected cleanly on the first try against
  a real PostgreSQL 17 server - SCRAM-SHA-256 (the modern default auth
  method, PostgreSQL's rough equivalent of MySQL's `caching_sha2_password`,
  which is exactly where the MySQL driver failed) and SSL both worked
  without any code changes, and a scan of its open issue tracker turned
  up nothing blocking for the narrow CREATE/DROP DATABASE, CREATE/ALTER/
  DROP ROLE, and simple `pg_catalog` query surface these two plugins
  need.
  - Real Ansible splits role management (`postgresql_user`) from
    database/table privilege grants (a separate module,
    `postgresql_privs`, not implemented here either) - `postgresql_user`
    follows that same split rather than folding privileges into user
    management the way this codebase's `mysql_user.cr` does (a real,
    deliberate difference from the MySQL pair, not an inconsistency:
    MySQL's own `GRANT` model ties privileges directly to the user
    account; PostgreSQL's doesn't).
  - `postgresql_db`: `name:` (required), `state:` (`present`/`absent`),
    `owner:`, `encoding:` (both validated as identifier-safe characters
    only, since they can't go through a bind parameter),
    `maintenance_db:` (default `"postgres"`, matching real Ansible -
    PostgreSQL can't `CREATE`/`DROP DATABASE` on the connection's own
    current database), `login_host:` (default `"localhost"` - a
    simplification versus real Ansible's own default of `""`/local unix
    socket, matching this codebase's other plugins' TCP-first default
    instead), `login_port:` (5432), `login_user:` (default `"postgres"`,
    matching real Ansible), `login_password:`, `login_unix_socket:`
    (takes precedence over `login_host:`/`login_port:` when given - via a
    new pure `src/crystal_play/plugin_helpers/postgresql_connection.cr`,
    unit tested; verified against `crystal-pg`'s actual `ConnInfo` parsing
    source that a unix socket path has to go through a `host` query
    param, not the URI's own host component). `state: dump`/`restore`
    (real Ansible's own keyword is `restore`, not `import` like
    `mysql_db`'s equivalent, `0.9.40`; `.bz2`/`.xz` compression added in
    `0.9.43`) - see those entries near the end of this file for the full
    writeup. Not implemented: `.tar`/`.pgc`/`.dir` formats (`pg_restore`-
    based - a genuinely different restore mechanism, not just another
    compression codec) and `.zst` compression (no Crystal zstd binding is
    vendored in this codebase yet), `collation:`/`lc_collate:`/
    `lc_ctype:`/`template:`/`tablespace:`, `force:`, `session_role:`.
  - `postgresql_user`: `name:` (required), `password:` (applied whenever
    given, for both new and already-existing roles - unlike real Ansible,
    which can compare a candidate password against the role's stored
    SCRAM/MD5 verifier to stay idempotent, this always reissues `ALTER
    ROLE ... PASSWORD` and reports `changed: true` whenever a `password:`
    is given for an existing role, the same documented simplification
    `mysql_user.cr` already makes), `state:` (`present`/`absent`),
    `role_attr_flags:` (`"LOGIN,CREATEDB,NOSUPERUSER"`, real Ansible's
    own format - via a new pure
    `src/crystal_play/plugin_helpers/postgresql_role_flags.cr`, unit
    tested, diffed against the role's actual `pg_roles` attribute
    columns verified against a real PostgreSQL 17 server's schema; only
    the flags actually given are compared, so omitting
    `role_attr_flags:` entirely never triggers a change on its own),
    `login_host:`/`login_port:`/`login_user:`/`login_password:`/
    `login_unix_socket:`/`login_db:` (default `"postgres"`, matching real
    Ansible). Not implemented: `expires:`, `conn_limit:`, `comment:`,
    `session_role:`, `fail_on_user:`.
  - Verified end-to-end against a real running PostgreSQL 17 server by
    hand (database create/idempotent/remove/idempotent; role create with
    flags/idempotent, flags changed, remove/idempotent) before writing
    any automated test. Integration tested via the CLI against the same
    real server (`testing/test-postgresql-quick.yml` targeting
    `testservers`, like `test-mysql-quick.yml`) +
    `spec/integration/cli_spec.cr`, and verified task-for-task against
    real `ansible-playbook` (via a Python venv with psycopg2-binary
    installed, same reasoning as the MySQL fixture's PyMySQL venv) running
    the identical fixture - output matched exactly.

**Result:** ~99.99% playbook coverage per prior analysis. Phase 3 is now
fully complete - every plugin originally scoped for it has shipped.

---

## Phase 4 - Advanced execution features (~4-6 weeks)

- [x] `changed_when` / `failed_when` (`0.9.7`): override a task's own
  changed/failed verdict with a condition evaluated against the task's
  result. Parsed identically to `until:` (`Task#changed_when`/
  `Task#failed_when`, plain strings via `safe_yaml_to_string` so a bare
  YAML `false` becomes the string `"false"`). Evaluated in a new
  `TaskExecutor#apply_changed_failed_when`, called right before
  `execute_task_once` returns (so it runs for every path that funnels
  through it: single tasks, each iteration of a looped task, and every
  attempt of a retried task) - same substitute-then-`ConditionalEvaluator`
  pipeline `when:`/`until:` already use. The task's own result is made
  available to the condition under its own `register:` name (e.g.
  `changed_when: "{{ result.rc != 0 }}"`), mirroring real Ansible - a
  register: is not required for a bare literal like `changed_when: false`.
  Note: this codebase's bare (non-`{{ }}`) `ConditionalEvaluator` doesn't
  support dotted variable access (`foo.bar`) at all - only
  `VariableSubstitutor::ComparisonEvaluator`, reached by wrapping the whole
  expression in `{{ }}`, does. This is a pre-existing gap shared with
  `when:`/`until:`, not something new to this feature; any `changed_when:`/
  `failed_when:` referencing a dotted result field needs the `{{ }}` form
  to actually work rather than silently evaluating to a meaningless
  default. Unit tested (`spec/unit/playbook_parser_spec.cr`'s
  "changed_when / failed_when parsing" group) and integration tested for
  real (not just `--check`, since `command:` skips outright in check mode)
  via `testing/test-changed-when-quick.yml` +
  `spec/integration/cli_spec.cr`. Verified against real `ansible-playbook`
  manually (not via the Docker compat harness, which this fixture isn't
  wired into) - output matched task-for-task
  (ok/ok/changed, `changed=1` in the recap), modulo real Ansible's own
  deprecation warning about wrapping conditionals in `{{ }}` (which this
  codebase's evaluator, unlike real Ansible's Jinja2, actually needs for
  the dotted-access case above).
- [x] `delegate_to` / `run_once` (`0.9.8`): `delegate_to:` runs a task's
  actual module/connection against a different host than the one the play
  is iterating - variables, facts, `register:`, and recap stats stay
  attributed to the original host, matching real Ansible (only the
  connection is redirected, not the templating context). May be templated
  (`{{ vars }}`), resolved at execution time against the *original* host's
  vars context, then looked up via a new optional `TaskExecutor#@inventory`
  (the full `Inventory`, not just the play's own resolved host list, since
  a delegate target like `localhost` is often outside the play's own
  `hosts:` pattern) - falling back to a bare constructed `Host` (mirroring
  `Inventory#get_hosts`'s own implicit-localhost behavior) if the target
  isn't in the inventory at all. Implemented by threading a second `Host`
  (`exec_host`, defaulting to the original `host`) through
  `execute_task_once`/`execute_looped_task`/`execute_task_with_retries`,
  used only for the actual `PluginManager.execute_plugin`/
  `ActionPluginManager.execute_action` calls - everything else (`when:`
  substitution, `vars_context`, display, `register:`) keeps using the
  original host. `run_once:` executes the task only for the first host in
  the play's own host list; every other host skips it outright (no
  output/stats, matching real Ansible), but still copies over whatever it
  registered so a later task on those hosts can reference the same
  variable (real Ansible's own run_once + register: interaction is subtler
  in edge cases; this is a documented, simpler approximation, not a claim
  of pixel-perfect parity). Unit tested
  (`spec/unit/playbook_parser_spec.cr`'s "delegate_to / run_once parsing"
  group) and integration tested for real via a new
  `spec/fixtures/inventory-multi-local.ini` (two hosts, both
  `ansible_connection=local` - lets multi-host behavior be exercised for
  real without a second machine to actually SSH into) +
  `testing/test-delegate-run-once-quick.yml` +
  `spec/integration/cli_spec.cr`. Verified against real `ansible-playbook`
  manually against the same inventory/playbook - task-for-task output and
  recap matched (modulo this codebase's own pre-existing, unrelated
  `ok`/`changed` recap-bucket convention being mutually exclusive rather
  than real Ansible's overlapping counters, true of every feature already
  shipped here, not something new to this one).
- [x] `group_vars` / `host_vars` directory loading (`0.9.9`): after parsing
  an INI or YAML inventory, `InventoryParser` now also looks for
  `group_vars/` and `host_vars/` directories next to the inventory *file*
  (not the playbook - real Ansible checks both locations, this only
  implements the inventory-relative one, a documented scope cut). Loads
  `group_vars/all.yml`, `group_vars/<group>.yml` for each group, and
  `host_vars/<hostname>.yml`, applying each host's own `ansible_user`/
  `ansible_port` keys the same way inline inventory vars already do. Only
  the single-file-per-name form is supported, not Ansible's
  directory-of-multiple-files style (`group_vars/<name>/*.yml`) - the
  common case, not full parity. Precedence (implemented via a new
  `apply_vars_file` helper using set-if-absent, called in
  highest-precedence-first order so the first write to a given key wins):
  inline host vars > `host_vars/<host>.yml` > `group_vars/<group>.yml` >
  `group_vars/all.yml` > (already-existing) inline `[group:vars]`/`vars:`
  sections. Real Ansible's actual precedence has `host_vars/` files
  outrank even inline host vars, but that's a rare enough collision that
  matching this codebase's existing "host wins" convention (already used
  for inline group vars, see `apply_group_vars`) was a reasonable trade
  over threading a new "was this explicitly inline" flag through `Host`.
  Unit tested directly against real temp inventory/group_vars/host_vars
  directories (new `spec/unit/inventory_parser_spec.cr` - this component
  had no unit specs at all before this), and integration tested via the
  CLI against a new isolated fixture directory
  (`spec/fixtures/group_host_vars/`) + `testing/test-group-host-vars-quick.yml`.
  Verified against real `ansible-playbook` against the same
  inventory/playbook - output matched exactly.
- [x] Dynamic inventory (`0.9.11`): `InventoryParser.parse` now detects an
  executable inventory path (`File::Info.executable?` - the executable
  bit, not the filename/extension, same rule real Ansible uses) and runs
  it with `--list`, parsing its JSON output in Ansible's standard dynamic
  inventory shape: each top-level key is a group, either a bare host-name
  array (shorthand) or a `{hosts:, vars:, children:}` hash; an optional
  `_meta.hostvars` supplies every host's vars up front. When `_meta` is
  absent, falls back to the older, slower per-host `--host <name>`
  convention real Ansible also supports (one process spawn per host).
  `group_vars:`/`host_vars:` directories (see the entry above) are still
  applied afterward, relative to the *script's* directory. This
  implements the original, universal "any executable, any language"
  dynamic inventory mechanism only - Ansible's newer YAML-defined
  inventory *plugins* (`aws_ec2.yml` and friends, each with its own
  config schema and cloud API calls) are not implemented; this was the
  larger, still-open half of the "Dynamic inventory support +
  group_vars/host_vars directory loading" roadmap item, now closed out.
  Unit tested against real temp executable scripts (`spec/unit/
  inventory_parser_spec.cr`'s "dynamic (executable script) inventory"
  group - full format + `_meta`, shorthand array format, the `--host`
  fallback, a non-zero-exit script raising a clear error, and
  group_vars/ still applying on top) and integration tested via the CLI
  against a real script (`spec/fixtures/dynamic_inventory/inventory.sh`)
  + `testing/test-dynamic-inventory-quick.yml` +
  `spec/integration/cli_spec.cr`. Verified against real `ansible-playbook`
  against the same script/playbook - output matched exactly.
- [x] `async:` / `poll:` / `async_status` (`0.9.10`): runs a module in the
  background up to `async:` seconds, checking every `poll:` seconds
  (default 10, matching real Ansible) until it finishes or the timeout
  elapses; `poll: 0` returns immediately with an `ansible_job_id` instead
  of waiting, to be checked later via `async_status:`. **Local connections
  only** - genuine remote async needs a process that survives the SSH
  session ending, which this codebase's plain exec-over-SSH model doesn't
  support; a non-local `async:` task fails with a clear message rather
  than silently running synchronously. The background job is a real,
  detached OS process (a hidden `crystal-ansible __async_run <module>
  <config> <status>` re-invocation of the same binary spawned via
  `Process.new` without `.wait`), not a Fiber - so it survives even if the
  poll loop or the whole playbook run finishes first, same as real
  Ansible's job outliving the control connection. Job status lives at
  `~/.ansible_async/<jid>` (new `src/crystal_play/async_jobs.cr`,
  `AsyncJobs` - matches real Ansible's own on-disk convention, written
  atomically via write-then-rename), read back by a new `async_status:`
  plugin (`plugins/async_status.cr`, registered as
  `ansible.builtin.async_status`) - only "status" mode, not "cleanup".
  Verified against real `ansible-playbook` and adjusted two details that
  weren't obvious from docs: the `poll: 0` dispatch acknowledgment reports
  `changed: true` (not `false`), and a finished `async_status:` forwards
  the underlying job's own `changed:` value rather than always reporting
  `false`. Unit tested (`spec/unit/playbook_parser_spec.cr`'s "async /
  poll parsing" group, new `spec/unit/async_jobs_spec.cr`) and integration
  tested for real via `testing/test-async-quick.yml` (targets
  `testservers`, like `test-copy.yml`/`test-package.yml`, so a `--check`
  run against the generic empty inventory skips the whole play rather than
  registering a job-less `ansible_job_id` for `async_status:` to choke
  on) + a new `spec/fixtures/inventory-testservers-local.ini` +
  `spec/integration/cli_spec.cr`.
- Cloud plugins (`ec2`, `s3_bucket`, `azure_rm_*`) - optional, lowest ROI
  per usage stats (~5% of playbooks)

**Result:** Phases 1-4 complete as of `0.9.23` (the core engine, all Phase 3
plugins, and all advanced-execution features). Full *routine* Linux parity is
the Phase 5 goal below - the common-module gaps it tracks are what a "full
parity" claim was previously missing.

---

## Phase 5 - Missing common modules (the real parity gap) (~2-3 weeks)

This is the **current priority**. The checked phases below cover a lot, but not
some of the most frequently-used `ansible.builtin` modules - each of these is
entirely missing today, and a playbook using any of them fails with "Plugin
binary not found". The concrete defect is checked into this roadmap so helper
agents can pick one up independently; each entry below gives the parameters,
the implementation approach for *this* codebase (action-plugin vs module,
native vs exec, local/remote, check-mode), and the verification plan (unit spec
+ compat playbook diffed against real `ansible-playbook`, following the
established `compat/` pattern).

The action-plugin layer lives in `src/crystal_play/action_plugin_manager.cr`
(an `ACTION_PLUGINS` registry; today it only handles `template`) - action
plugins run on the control node and never touch the target. Modules are
`plugins/<name>.cr` binaries (see `plugins/template.cr` for the standalone-binary
shape) dispatched via `bin/plugins/`. Follow the existing conventions: `ameba`
clean, unit specs where the logic is pure, integration specs via
`spec/integration/cli_spec.cr`, `PluginSpecHelper.run`, and a compat playbook
under `compat/playbooks/NN-*.yml` diffed 1:1. Bump version (patch, `0.9.x`) per
commit.

Recommended order (by real-world frequency, descending): `get_url` + `set_fact`
first, then `blockinfile`, `uri`, `assert`, `wait_for`, `fetch`, `pause`.

- [x] `set_fact` (`0.9.24`): sets arbitrary variables for subsequent tasks on
  the same host. Parameters: any number of `key=value` pairs (values already
  templated by `TaskExecutor` before any plugin sees them), plus `cacheable:`
  (accepted and ignored - there's no fact-cache plugin here to persist into).
  Implemented as a plain module (`plugins/set_fact.cr`), not an action plugin
  as originally scoped in this entry: set_fact needs no controller-only
  special-casing because it does nothing controller-specific - it just echoes
  its own params back as `ansible_facts` (typed via best-effort bool/int/
  float/string coercion, since every param arrives as a plain string), the
  same result field the existing `facts` plugin already returns from
  `gather_facts_for_all_hosts`. `TaskExecutor` gained a small generic
  `merge_ansible_facts` step (called after every single and every looped task
  execution, not just fact-gathering) that merges any task result's
  `ansible_facts` into that host's fact store; `build_vars_context` already
  applied `@facts` after every other variable tier, which gives set_fact the
  high precedence real Ansible's own docs describe, with no extra precedence
  logic needed. Never reports `changed`, and is safe under `--check` since it
  never touches the filesystem or network. Registered in
  `PlaybookParser::AVAILABLE_PLUGINS` and `build.sh`'s `PLUGINS` list like any
  other module. Unit/integration tested
  (`spec/integration/set_fact_spec.cr`: ansible_facts shape, bool/int/float/
  string coercion, `cacheable:` not leaking through as a literal fact) and
  via the CLI directly (`spec/integration/cli_spec.cr`'s dedicated
  `test-set-fact-quick.yml` assertion: a later `debug:` sees a string and an
  int fact, a `when:` gates on a bool fact, and a second `set_fact:` on the
  same key overwrites it for a task afterward). **Update (`0.9.32`):**
  verified against real `ansible-playbook` via the compat harness
  (`compat/playbooks/27-set-fact.yml` - passed).
- [x] `assert` (`0.9.28`): fails (or passes) based on a list of `that:`
  conditions, for role pre-flight validation. Parameters: `that:` (required;
  either a list of condition strings or, per real Ansible, a single bare
  string), `fail_msg:` (alias `msg:` - a real, still-working alias kept
  from a pre-2.7 rename, verified via `ansible-doc`, not assumed obsolete),
  `success_msg:`. Implemented as a **plain module**
  (`plugins/assert.cr`), not the control-node-only action plugin this
  entry originally scoped: `that:` conditions only ever reference
  variables already resolved into `@vars` (the plugin process already
  receives the full vars_context every other plugin's params were already
  substituted against), so there's no filesystem/network access or
  controller-vs-target split to make - the same "doesn't need
  action-plugin machinery" finding `set_fact` made in `0.9.24`. Reuses
  `ConditionalEvaluator`/`VarSubstitutor` directly (both plain, dependency-
  light classes, not something `TaskExecutor`-only) for the identical
  bare-vs-`{{ }}` dotted-access pipeline `when:`/`until:`/`changed_when:`
  already use. `that:` needed a small playbook-parser special case
  (`playbook_parser.cr`'s `parse_module_params`): the generic YAML-list
  stringifier joins array params with a comma, which would silently
  corrupt any condition containing one (e.g. `x in [1, 2, 3]`), so `that:`
  is JSON-encoded instead (`Array(String).from_json` on the plugin side) -
  a real, if narrow, correctness bug in the generic path that this entry's
  original "same `ConditionalEvaluator` pipeline" framing didn't surface,
  found while actually wiring the list through rather than assumed. Two
  more behaviors were verified against real `ansible-playbook` runs rather
  than trusted from `ansible-doc`, both different from this entry's
  original guess: evaluation **stops at the first failing condition**
  (conditions are not aggregated - `ansible-doc`'s "optional custom
  message" phrasing doesn't actually say either way), and a failed result
  carries `assertion:` (the raw, unsubstituted condition text) and
  `evaluated_to: false` alongside `msg:`; the default messages are
  exactly `"Assertion failed"` / `"All assertions passed"`. Never
  `changed`; runs and evaluates identically under check mode (there's no
  state change to gate on). Integration tested
  (`spec/integration/assert_spec.cr`, 8 examples): missing `that:`, all-
  pass with the default success message, first-failure with the default
  fail message plus `assertion:`/`evaluated_to:`, custom `fail_msg:`, the
  `msg:` alias, custom `success_msg:`, a `{{ }}`-wrapped dotted condition,
  and `changed: false`. Also verified end-to-end through the real compiled
  `crystal-ansible` binary against a playbook mirroring the real-Ansible
  comparison fixture above - task-for-task output matched. **Update
  (`0.9.32`):** verified against real `ansible-playbook` via the compat
  harness (`compat/playbooks/31-assert.yml` - passed).
- [x] `get_url` (`0.9.25`): downloads a URL to a file. Parameters: `url`
  (required), `dest` (required; a directory `dest` downloads to
  `dest/<basename of the URL path>`, matching real Ansible), `mode`/`owner`/
  `group` (applied via the existing shared `apply_owner_group_mode`),
  `force` (default `no`), `checksum` (`"sha256:<hex>"`-style, algorithm
  read via `native_checksum` - same helper `stat`/`find` already use),
  `url_username`/`url_password` (HTTP basic auth), `validate_certs`
  (default `yes`; `no` sets the TLS context's `verify_mode` to `NONE`),
  `timeout` (default 10, applied to both connect and read), `headers`
  (comma-separated `Key: Value` pairs - simpler than real Ansible's own
  format but covers the common case), `http_agent` (default
  `"ansible-httpget"`, matching real Ansible's own default User-Agent),
  `backup`. Implemented as a plain module (`plugins/get_url.cr`), not the
  local-only/remote-exec-fallback split this entry originally scoped:
  fetches natively via stdlib `HTTP::Client` in every case, including
  remote hosts, with **no** `curl`/`wget` fallback needed at all - the
  scoping note above assumed a plugin process only ever runs on the
  control node, but (re-discovering the same fact `native_stat`'s doc
  comment already recorded) `PluginManager` uploads and executes this
  same compiled plugin binary directly on the target host for non-local
  connections, so an `HTTP::Client` call made from inside this process
  already runs on whichever host - local or remote - the task is
  targeting, the same reason `stat`/`find`'s native syscalls already work
  remotely with no SSH branch. Downloads to a `<dest>.<pid>.tmp` sibling
  file first, verifies the checksum there (deleting the tmp file on any
  failure, never disturbing an existing `dest`), then `File.rename`s it
  into place - so a failed or checksum-mismatched download can't corrupt
  or partially overwrite a pre-existing `dest`. A checksum mismatch on an
  *existing* `dest` triggers a re-download regardless of `force:` - the
  checksum is treated as its own freshness check, matching real Ansible's
  behavior (not deriving `force:` from checksum presence would leave
  `checksum:`-only playbooks unable to ever self-heal a corrupted
  download). Redirects (3xx + `Location:`) are followed manually up to 10
  hops, since Crystal's `HTTP::Client` doesn't do this itself - a real gap
  in the sense that most `get_url:` targets in practice (GitHub releases,
  CDN-fronted downloads) redirect at least once. Check mode reports
  `changed` without making any request. Not implemented: `checksum_url`
  (fetching the expected checksum from a second URL rather than passing it
  literally), `unredirected_headers`, `ciphers`, client TLS certs
  (`client_cert`/`client_key`), `use_proxy`/proxy env handling, `unsafe_writes`,
  SELinux options - all lower-value than the core
  fetch+checksum+idempotency path. Unit-shaped logic (checksum parsing,
  existing-dest skip/force/checksum-mismatch branching, redirect
  resolution) lives directly on the plugin class rather than a separate
  `plugin_helpers/` module, since none of it is meaningfully testable
  without also exercising `native_checksum`/the filesystem - covered
  instead by a dedicated integration suite
  (`spec/integration/get_url_spec.cr`, 9 examples) against a real
  in-process `HTTP::Server` (stdlib, not `python3 -m http.server`, so the
  spec has no external process dependency): new download, checksum match/
  mismatch, idempotent rerun, skip-without-force, overwrite-with-force,
  check mode, a 404, a redirect, and missing-required-argument errors.
  **Update (`0.9.32`):** verified against real `ansible-playbook` via the
  compat harness (`compat/playbooks/28-get-url.yml` - passed). Doing so
  surfaced a real result-field bug this entry's own initial testing
  missed: the changed-download result field was named `checksum`, but
  real Ansible's actual `get_url` module returns `checksum_src` (plus a
  `checksum_dest` that stayed `null` in every case checked) - a made-up
  name never cross-checked against a real result payload. Fixed by
  renaming the field and always hashing with `sha1` (real Ansible's own
  default algorithm) rather than the hardcoded `sha256` used before, and
  by dropping the checksum value entirely (both fields `null`) from the
  already-exists-and-matches fast-skip path, matching real Ansible's own
  observed behavior there exactly. Separately (found by hand-testing
  against a real local server, not by the compat playbook itself, which
  doesn't exercise this path): real Ansible's own no-`checksum:` rerun
  idempotency isn't a `File.exists?` shortcut at all - it sends a real
  conditional GET (`If-Modified-Since`) and treats the server's `304 Not
  Modified` as "unchanged," which this codebase's simpler
  dest-exists-so-skip approximation doesn't replicate. Left as a
  documented, deliberate simplification rather than implemented: the
  compat playbook uses an explicit `checksum:` (via a `stat:` computed
  ahead of time) for its idempotency check instead of depending on this
  divergent path, which is a real, if narrow, remaining scope gap.
- [x] `blockinfile` (`0.9.26`): inserts/updates/removes a marker-delimited
  block of text in a file - the natural follow-on to the already-native
  `lineinfile`. Parameters: `path` (required), `block` (alias `content`;
  a missing or empty `block` is treated as `state: absent` regardless of
  `state:`, matching real Ansible - verified, not assumed), `state`
  (present/absent, default present), `marker` (default
  `# {mark} ANSIBLE MANAGED BLOCK`), `marker_begin`/`marker_end` (default
  `BEGIN`/`END`, substituted into `{mark}`), `insertafter`/`insertbefore`
  (same regex/EOF/BOF semantics `lineinfile` already implements -
  `LineEditor.insertion_index` made public and reused directly rather than
  duplicated), `create`, `mode`/`owner`/`group` (via the shared
  `BasePlugin#apply_owner_group_mode`), `backup`. Marker-matching/insertion
  logic factored into a new pure `src/crystal_play/plugin_helpers/block_editor.cr`
  (`BlockEditor`, unit tested directly, `spec/unit/block_editor_spec.cr`):
  begin/end markers are matched by exact line equality (not regex), an
  existing block's position never moves - only its interior is replaced -
  and a begin marker with no matching end line found after it (a block
  torn apart by hand-edits) is treated as "not found," taking the same
  fresh-insert path a missing begin does, rather than erroring or matching
  partially. Every one of these behaviors, plus the exact message text
  (`"Block inserted"`/`"Block removed"`/`""` on no-op/`"File created"` when
  the write happens on the same call that created the file), was verified
  against real `ansible-playbook` runs (not assumed from `ansible-doc`)
  before being encoded - `File created` also came out of that
  verification and is a real, if slightly surprising, quirk of the
  upstream module rather than a crystal-ansible invention.
  Integration tested (`spec/integration/blockinfile_spec.cr`, 9 examples):
  fresh insert + idempotent rerun, content update in place,
  `state: absent` removal, empty-block-means-absent, custom markers,
  `insertbefore`, file creation, missing-file-without-create failure, and
  check mode. **Update (`0.9.32`):** verified against real
  `ansible-playbook` via the compat harness
  (`compat/playbooks/29-blockinfile.yml` - passed).
- [x] `uri` (`0.9.27`): makes an HTTP request (API calls, health checks,
  webhooks). Parameters: `url` (required), `method` (default GET), `body`,
  `body_format` (`raw` default/`json`/`form-urlencoded` - real Ansible's
  own three most-used values, not the `json`/`form`/`raw` this entry
  originally guessed at; `form-multipart` isn't implemented), `headers`
  (a JSON-object string - the playbook parser already JSON-encodes any
  YAML dict param before a plugin sees it, the same convention
  `docker_container.cr`'s `env:`/`labels:` already rely on), `status_code`
  (comma-separated ints, default `200`), `return_content`,
  `url_username`/`url_password`, `validate_certs`, `timeout` (default 30,
  matching real Ansible's own default - not `get_url`'s 10),
  `follow_redirects` (`safe` default - GET/HEAD only; `all`/`yes`; `none`/
  `no`). Two behaviors this entry's scoping got wrong were caught only by
  actually running real `ansible-playbook` against a local test server
  side by side, not by trusting `ansible-doc`: (1) **real Ansible's `uri`
  module has no check-mode support at all** - even a bare GET is skipped
  outright under `--check` (`"This action (uri) does not support check
  mode."`), not just mutating methods as this entry assumed, so
  crystal-ansible's version skips unconditionally under `check_mode:`,
  the same `skipped: true` convention `command.cr` already uses for its
  own check-mode gap; (2) **`changed:` is always `false`**, verified
  against the real module's actual Python source (`resp['changed'] =
  False`, only ever flipped by `dest:`-file-writing, which isn't
  implemented here) - it is not a POST/PUT/DELETE-vs-GET/HEAD distinction
  at all, contrary to this entry's original guess. Redirects are followed
  manually (`HTTP::Client` doesn't do this itself, same as `get_url`), with
  a 303 (or a 301/302 responding to a POST) downgrading the follow-up
  request to GET, matching real browser/urllib behavior; `redirected:` in
  the result reflects whether a hop actually happened. A JSON
  `Content-Type` response always populates both `content` and `json` in
  the result regardless of `return_content:` (matches real Ansible
  exactly - `return_content:` only gates plain-text bodies). `location:`
  is included whenever a `Location` header is present, even when the
  redirect wasn't followed. `form-urlencoded` bodies are properly
  form-encoded (`URI::Params.build`) from the JSON-object `body:` the
  playbook parser hands over, not passed through as literal JSON text.
  Not implemented: `dest:` (download-to-file, `get_url:`'s job), `src:`,
  `force_basic_auth`, `creates:`/`removes:`, `unix_socket`, client TLS
  certs, `use_proxy`, SELinux options, `unredirected_headers`,
  `use_gssapi`/`use_netrc` - all lower-value than the core
  request+status+content path. Integration tested
  (`spec/integration/uri_spec.cr`, 12 examples) against a real in-process
  `HTTP::Server` (same pattern `get_url_spec.cr` established): GET with
  and without `return_content`, automatic JSON parsing, a failing status
  code and a custom `status_code:` list accepting it, a POST body with a
  registered status, form-urlencoded encoding, redirect-followed with
  `redirected: true`, `follow_redirects: none` leaving the 302 unfollowed,
  `changed: false` on a mutating POST, and the check-mode skip. **Update
  (`0.9.32`):** verified against real `ansible-playbook` via the compat
  harness (`compat/playbooks/30-uri.yml` - passed).
- [x] `wait_for` (`0.9.29`): polls until a port/file/regex-in-file condition
  is met, used to gate tasks on readiness. Parameters: `host` (default
  127.0.0.1)/`port` (wait until connectable, mutually exclusive with
  `path`), `path` (wait until file exists/absent), `search_regex` (matched
  against a file's content only - not an open socket's, per this entry's
  own original scope), `state` (`started`/`present` for up,
  `stopped`/`absent` for down), `timeout` (default 300), `delay` (sleep
  before polling starts), `connect_timeout` (default 5), `sleep` (default
  1), `msg` (overrides the default timeout message). Native `TCPSocket`
  connect attempt for `port`, `File.exists?` for `path`, `File.read` +
  `Regex#match` (multiline) for `search_regex`. Two behaviors were
  verified against real `ansible-playbook` runs rather than assumed from
  `ansible-doc`, one of which this entry's own scoping got wrong: (1)
  **with no `port:`/`path:` given, `wait_for:` always sleeps for the
  *full* `timeout:`** ("used without other conditions it is equivalent of
  just sleeping," confirmed to genuinely not return early) - an initial
  implementation treated the no-condition case as trivially
  already-satisfied and returned instantly, which is wrong; (2) **real
  Ansible's `wait_for` has no check-mode support at all**, skipping
  outright under `--check` with the exact text
  `"remote module (wait_for) does not support check mode"`, reused
  verbatim here via the same `skipped: true` convention `command.cr`/
  `uri.cr` already use for their own check-mode gaps. Timeout messages
  match real Ansible's own wording exactly (verified, not guessed):
  `"Timeout when waiting for #{host}:#{port}"`,
  `"Timeout when waiting for file #{path}"`, and
  `"Timeout when waiting for search string #{regex} in #{path}"`. A
  successful `search_regex` match populates `match_groups` from the
  regex's own capture groups (excluding the full match at index 0, which
  real Ansible's own `match_groupdict`/`match_groups` output likewise
  excludes) - `match_groupdict` itself is always returned empty (named
  captures aren't implemented, a documented simplification). Never
  `changed`. `state: drained` and its `exclude_hosts`/
  `active_connection_states` options were added in `0.9.46` (see that
  entry near the end of Phase 5) - not a scope cut anymore. Integration tested
  (`spec/integration/wait_for_spec.cr`, 12 examples): mutually-exclusive
  `port:`/`path:` validation, the check-mode skip, a closed-port timeout
  with the exact message, a custom `msg:`, an already-open port
  succeeding immediately (via a real `TCPServer` bound to an OS-assigned
  port), `state: stopped` against an already-closed port, an
  already-existing path, a missing-path timeout with the exact message,
  `state: absent` against an already-missing path, a matching
  `search_regex`, a non-matching `search_regex` timeout with the exact
  message, and `changed: false`. **Update (`0.9.32`):** verified against
  real `ansible-playbook` via the compat harness
  (`compat/playbooks/32-wait-for.yml` - passed). Building that playbook
  found a real, unrelated bug (fixed in `0.9.33`): `LocalExecutor.exec`
  (backing `shell:`/`command:` on any local connection) hung *forever* on
  a command shaped like `sleep N && long-running-daemon &` - see the
  Phase 5 wrap-up note below for the root cause and the fix; this was a
  genuine `shell:`/`command:` gap, not a `wait_for:` one, so it's tracked
  separately rather than this entry.
- [x] `fetch` (`0.9.30`): pulls a file from the target to the control node -
  the inverse of `copy`. Parameters: `src` (required), `dest` (required),
  `flat` (default `no` - `dest/<inventory_hostname>/<src, leading slash
  and all>`; `yes` writes straight to `dest`, or `dest/<basename of src>`
  when `dest` ends with a path separator, verified field-for-field against
  real `ansible-playbook`'s actual output, not assumed), `validate_checksum`
  (default `yes`, used for pre-transfer idempotency as well as
  post-transfer validation - real Ansible's own docs only mention the
  latter, but the source checksum has to be known before deciding whether
  to transfer at all, so this codebase uses it for both), `fail_on_missing`
  (default `yes`). Implementing this surfaced a real architectural gap
  this entry's "for remote connections it uses `remote_download`" framing
  glossed over: every other plugin's compiled binary gets uploaded and
  *executed directly on the remote target* for a non-local connection
  (`PluginManager#execute_remote_plugin`, forcing `ansible_connection:
  local` into that copy's own config so its internal filesystem calls
  correctly mean "the target's filesystem") - fine for plugins that only
  ever read/write wherever they happen to run, but exactly backwards for
  `fetch`, which needs to run *on the controller* and pull via SSH. Fixed
  by adding a small `PluginManager::CONTROLLER_ONLY_PLUGINS` set
  (currently just `fetch`) that bypasses the local/remote dispatch
  entirely and always runs the plugin locally via `execute_local_plugin`,
  with the original (non-overridden) host/vars intact - from there,
  `BasePlugin#remote_download` already did exactly the right thing
  (`FileUtils.cp` for a genuinely local target, `SSHManager.download` for
  a real remote one) with no further change needed. The one similarly
  "genuine remote operation, no native equivalent" case: computing the
  *source*'s checksum before transfer needs `native_checksum` (an
  `OpenSSL::Digest` read on this process's own filesystem) for a local
  target, but a real remote target's bytes aren't reachable from the
  controller process at all until fetched - shells `sha1sum` over SSH via
  `remote_exec` for that one case only, the same category of gap this
  codebase's other plugins (`apt`/`dnf`/`service`/...) already carve out.
  Real Ansible's own `fetch` documents full check-mode support but
  actually skips outright under `--check` with
  `"check mode not (yet) supported for this module"` (verified against a
  real `ansible-playbook --check` run, not the docs) - reused verbatim
  here via the same `skipped: true` convention `uri.cr`/`wait_for.cr`
  already use for their own check-mode gaps. `checksum`/`md5sum` (sha1 and
  md5 of the fetched file) and, on an actual transfer,
  `remote_checksum`/`remote_md5sum: null` (real Ansible's own module
  always returns a literal `null` there too - a legacy protocol field it
  never actually populates, matched rather than "fixed") were verified
  field-for-field and byte-for-byte against real `ansible-playbook`'s
  actual output, including the exact `"the remote file does not exist,
  not transferring, ignored"` message text. Not implemented: symlink
  handling nuances, SELinux options, `unsafe_writes` - all lower-value
  than the core transfer+layout+idempotency path. Integration tested
  (`spec/integration/fetch_spec.cr`, 8 examples): missing `src`/`dest`,
  the default hostname/path layout with an idempotent rerun, `flat: true`
  with and without a trailing separator on `dest`, a missing source with
  `fail_on_missing` true (fails) and false (doesn't), the check-mode skip,
  and a directory `src` failing clearly. **Update (`0.9.32`):** verified
  against real `ansible-playbook` via the compat harness
  (`compat/playbooks/33-fetch.yml` - passed).
- [x] `pause` (`0.9.31`): waits, or (in real Ansible) interactively prompts.
  Parameters: `seconds`, `minutes`, `prompt` (accepted, but has nothing to
  affect - see below), `echo` (default `yes`, not `no` as this entry
  originally guessed - real Ansible only echoes to the result, it doesn't
  gate anything crystal-ansible's non-interactive version does). Two
  things this entry's own scoping got wrong, both caught only by actually
  running real `ansible-playbook`, not by trusting `ansible-doc`'s prose:
  (1) **`seconds:` and `minutes:` are mutually exclusive in real Ansible**
  ("combined" here was wrong) - passing both, even `minutes: 0`, fails
  with `"parameters are mutually exclusive: minutes|seconds"`, reproduced
  verbatim; (2) with **neither** given, real Ansible blocks on stdin for
  interactive input - since crystal-ansible has no interactive TTY/prompt
  model at all (the documented scope cut this entry called for), that
  case is treated as an instant no-op (`"Paused without an interactive
  prompt (not supported) - continuing immediately"`) rather than hanging
  the playbook run forever, which is what a literal "countdown-only"
  reading of `seconds + minutes*60` would have done for the all-absent
  case (`0` seconds of actual sleep, but this codebase's `sleep(0)` isn't
  the bug - the *interactive-prompt* path this entry didn't separately
  call out is). Unlike `uri`/`wait_for`/`fetch`'s check-mode gaps, real
  Ansible's `pause` genuinely *does* run for real under `--check`
  (verified, not assumed) - so this doesn't skip under `check_mode:`
  either, matching that behavior exactly. Result fields
  (`start`/`stop`/`delta`/`stdout`/`stderr`/`rc`/`echo`/`user_input`) and
  the exact `stdout` wording (`"Paused for #{amount} seconds"` /
  `"...minutes"`) were verified against real `ansible-playbook`'s actual
  output. Never `changed`. Integration tested
  (`spec/integration/pause_spec.cr`, 5 examples): a real 1-second sleep
  with the exact `stdout` text, a fractional-minutes sleep, the
  mutually-exclusive failure, the no-args instant-continue case (asserted
  to actually take under a second, not just to not error), and
  `changed: false`. **Update (`0.9.32`):** verified against real
  `ansible-playbook` via the compat harness (`compat/playbooks/34-pause.yml`
  - passed).

**Phase 5 is now feature-complete and fully compat-verified** - every
module scoped at the top of this phase (`set_fact`, `get_url`,
`blockinfile`, `uri`, `assert`, `wait_for`, `fetch`, `pause`) has shipped
(`0.9.24` through `0.9.31`) and, as of `0.9.32`, has its own compat-harness
playbook (`compat/playbooks/27-set-fact.yml` through `34-pause.yml`,
following the same `compat/playbooks/NN-*.yml` pattern Phases 3/4 already
established) diffed against real `ansible-playbook` - **34/34 compat
playbooks pass**. Building those eight playbooks found two more real bugs
beyond the ones each module's own entry above already documents, both now
fixed: a `get_url` result-field name (`checksum` should have been
`checksum_src`, fixed in `0.9.32` - see that entry) and a genuine
`LocalExecutor`/`shell:` hang on `sleep N && daemon &`-shaped commands
(fixed in `0.9.33`, detailed below - a real gap in `shell:`/`command:`
themselves, unrelated to any Phase 5 module, that a plain reading of the
compat playbook's own task wouldn't have suggested was there).

- [x] `mysql_db`/`postgresql_db` `state: dump`/`import` (`0.9.40`):
  implementation was written and verified end-to-end against real running
  servers in an earlier pass, left uncommitted with a handoff note, then
  picked back up, given a compat-harness playbook each
  (`compat/playbooks/35-mysql-db.yml`/`36-postgresql-db.yml`), re-verified
  against the same live-container setup plus the compat harness itself, and
  committed. What shipped:
- `mysql_db.cr`: `state: dump` shells `mysqldump #{login_flags} dbname
  --quick`, capturing stdout via `remote_exec` and writing it to `target:`
  (natively gzip-compressed via `Compress::Gzip::Writer` when `target:` ends
  in `.gz`, no `gzip` subprocess - `.bz2`/`.xz`/`.zst` are **not**
  implemented, a real scope cut, not an oversight). `state: import` shells
  `mysql #{login_flags} --one-database dbname < path` (decompressing a
  `.gz` target to a temp file first via `Compress::Gzip::Reader` when
  needed). `login_flags` builds `--user=`/`--password=`/`--host=`/`--port=`
  (or `--socket=` when `login_unix_socket:` is given) from the same
  `login_*` params `present`/`absent` already use. Both always report
  `changed: true` on success (dump/import are not idempotency-checked at
  all in real Ansible either) and return `{changed, failed, msg, db,
  db_list}`, matching real Ansible's own field shape - verified against a
  real `ansible-playbook` run with `community.mysql.mysql_db` against a
  real MariaDB 11 server (see verification notes below), not assumed.
- `postgresql_db.cr`: same shape, but the real Ansible keyword is `state:
  restore`, **not** `import` like `mysql_db`'s - verified via `ansible-doc
  community.postgresql.postgresql_db`, don't assume it matches
  `mysql_db`'s naming. Shells `pg_dump #{name} #{login_flags}` for dump,
  `psql --dbname=#{name} #{login_flags} --file=path` for restore, with the
  password passed via a `PGPASSWORD=` environment-variable prefix in the
  shell command (real `pg_dump`/`psql` take no password CLI flag at all -
  verified, not guessed). Real Ansible's `.tar`/`.pgc`/`.dir` formats
  (`pg_restore`-based) are **not** implemented, only plain `.sql` and
  `.gz` - a real scope cut. `dump:`'s `msg:` is empty on success;
  `restore:`'s `msg:` is `psql`'s actual stdout (not empty) - verified,
  this asymmetry is real Ansible's own behavior, not a bug to fix.
- Both: `target:` is required for dump/import/restore (fails clearly if
  missing); import/restore fails clearly if `target:` doesn't exist;
  `check_mode:` reports `changed: true` with a "Would dump/import/restore"
  message without touching anything for real.
- `testing/test-mysql-quick.yml`/`test-postgresql-quick.yml` were extended
  with dump/import(/restore)/gzip round-trip tasks (seed data → dump
  gzip-compressed → restore into a second database → verify the row count
  survived the round trip), and `spec/integration/cli_spec.cr`'s two
  existing "requires a real server" tests were extended to assert on the
  new `db_import`/`db_dump`/`db_import_gz`/`restored_count` (mysql) and
  `db_restore`/`db_dump`/`db_restore_gz`/`restored_count` (postgresql)
  output lines. One pre-existing, unrelated fixture bug was found and
  fixed while wiring this up: the "verify the restored data round-tripped"
  task used `ansible.builtin.command:` with a quoted `-e "SELECT ..."`
  argument, which this codebase's own `command:` module (unlike real
  Ansible's) doesn't parse correctly (documented limitation: "doesn't
  handle quoted arguments perfectly") - switched to `ansible.builtin.shell:`
  instead, which goes through `/bin/bash -c` and handles the quoting fine.
- Verification method (first pass): this sandbox has no `mysqldump`/
  `mysql`/`psql`/`pg_dump` client binaries installed and no `sudo`/apt
  access to add them, so testing happened by launching real `mariadb:11`
  and `postgres:17` Docker containers plus a separate Debian container
  (`apt-get install` works fine as root *inside* a fresh container) with
  the client tools installed, `--network host` so it could reach the DB
  containers on `127.0.0.1:13306`/`15432`, and the freshly-built `bin/`
  copied in via `docker cp`. Confirmed byte-identical dump content against
  real `ansible-playbook`'s own `mysqldump` output (diffed, modulo the dump
  timestamp comment line), successful round-trip imports/restores (row
  counts verified via direct `mysql`/`psql` queries), and ran the full,
  YAML-driven `testing/test-mysql-quick.yml`/`test-postgresql-quick.yml`
  fixtures end-to-end through the actual compiled `crystal-ansible`
  binary (not just the raw plugin binaries) - both completed with
  `failed=0` and the exact expected debug output line.
- Compat-harness playbooks (`compat/playbooks/35-mysql-db.yml`/
  `36-postgresql-db.yml`, second pass): each starts its own throwaway
  server inside the compat container via its init.d script and covers a
  seed import/restore, a plain-SQL dump, a gzip-compressed dump (native
  `Compress::Gzip`, no `gzip` subprocess), both dumps restored into a
  second database with the row count verified after each round trip, and
  a missing-`target:` failure (both engines must fail the same way).
  Required extending `compat/Dockerfile` with `mariadb-server`/
  `postgresql`/their clients and `python3-pymysql`/`python3-psycopg2` (what
  real Ansible's own `community.mysql`/`community.postgresql` modules
  import on the target's system Python) plus the `community.mysql`/
  `community.postgresql` collections. Building these two playbooks found
  two more real, previously-shipped bugs, neither related to dump/import
  itself:
  1. **The venv running real `ansible-playbook` inside the compat
     container couldn't see the apt-installed `psycopg2`** - `python3 -m
     venv` isolates site-packages by default, and
     `community.postgresql.postgresql_db` imports `psycopg2` directly
     (unlike `mysql_db`, which only ever shells out to `mysqldump`/`mysql`,
     never imports a Python DB driver) - every `postgresql_db`/
     `postgresql_user` compat task failed with "Failed to import the
     required Python library (psycopg2)" regardless of crystal-ansible's
     own correctness. Fixed by adding `--system-site-packages` to the
     venv creation in `compat/Dockerfile`.
  2. **`mysql_connection.cr`'s built connection URI crashed against a
     common, valid MariaDB config**: any server compiled with OpenSSL
     support but never given a cert/key (`have_ssl: DISABLED`, the Debian
     `mariadb-server` package's out-of-the-box state) still advertises the
     SSL capability flag in its handshake, and the vendored `mysql` shard's
     default (`ssl-mode: preferred`) unconditionally attempts a TLS
     handshake whenever that flag is set - failing with a confusing
     `SSL_connect: error:0A00010B:SSL routines::wrong version number`
     instead of falling back to plaintext (a documented limitation of the
     shard itself: "Preferred" doesn't actually retry non-SSL on failure).
     100% reproducible against a fresh Debian-package MariaDB, though it
     happened not to trigger against the official `mariadb:11` Docker
     image used in the first verification pass above (different SSL build
     configuration) - which is why it wasn't caught until the compat
     harness exercised a different server image. There's no `login_*`/
     `ssl_*` param exposed anywhere in this codebase's `mysql_db`/
     `mysql_user` plugins for TLS configuration in the first place, so
     there's no way for a caller to opt out short of a code change - fixed
     by always appending `ssl-mode=disabled` to the connection URI in
     `MysqlConnection.build_uri` (`spec/unit/mysql_connection_spec.cr`
     updated for the new URI shape plus a dedicated regression example).
  Both fixes verified directly (manually re-running the affected playbook
  against the exact reproducing server config before and after each fix,
  not just re-running the full harness and hoping) and then confirmed via
  a full harness run: **36/36 compat playbooks pass**, including both new
  ones, byte-for-byte identical `/work` snapshots against real
  `ansible-playbook` (dump files themselves excluded from the snapshot,
  like `archive`'s/`unarchive`'s own compat playbooks - `mysqldump`/
  `pg_dump` embed a timestamp comment, so even logically identical dumps
  are byte-different across the two engines' separate runs; the row-count
  round trips already prove the content matched). `postgresql_db`'s compat
  playbook also surfaced that **`become:`/`become_user:` are parsed but
  never actually applied to command execution** - see the cross-cutting
  gaps note below. `ameba` is clean on every file this touched (matching
  the pre-existing baseline exactly - confirmed by diffing against the
  pre-change baseline, not just eyeballing the count), and `crystal spec`
  passes at 637/638 (one more example than before, from the new
  `mysql_connection_spec.cr` regression case; same 2 pre-existing
  DB-client-dependent failures as always, unrelated to this - this sandbox
  has no `mysql`/`psql` client binaries on the host itself, only inside
  the throwaway containers used for verification above).

- [x] `mysql_db`/`postgresql_db` `.bz2`/`.xz` dump/restore compression
  (`0.9.43`): the `0.9.40` entry above shipped only `.gz` and explicitly
  scoped `.bz2`/`.xz`/`.zst` out; closed for `.bz2`/`.xz` here by reusing
  the same `xz.cr`/`bz2.cr` shards `archive.cr`/`unarchive.cr` already
  depend on (`Compress::XZ::Writer`/`Reader`, `Compress::BZ2::Writer`/
  `Reader`) rather than adding a new dependency - both plugins' own
  `write_target`/`read_target_as_sql_file` helpers just gained two more
  `case`/`ends_with?` branches alongside the existing `.gz` one, no new
  logic shape. `.zst` stays a documented scope cut: no Crystal zstd
  binding is vendored in this codebase, unlike gzip (stdlib), xz, and bz2
  (both already required for `archive:`/`unarchive:`) - real Ansible
  itself only gained `.zst` support for `mysql_db` in `community.mysql`
  3.12.0 and never added it to `postgresql_db` at all (verified via
  `ansible-doc`, not assumed), so this isn't a symmetric three-format gap
  to begin with.
  - Verified real-server round trips for both formats and both plugins
    (seed import/restore → dump `.bz2` and `.xz` → restore each into a
    second database → row count matches) against the same live
    `mariadb:11`/`postgres:17` containers used for the `0.9.40` work,
    before touching the compat playbooks at all.
  - `compat/playbooks/35-mysql-db.yml`/`36-postgresql-db.yml` each
    extended with the same dump/restore/verify/cleanup shape the existing
    `.gz` coverage already has, for both new formats - `results.txt`
    grew `dump_bz2`/`dump_xz`/`import_bz2`(`restore_bz2`)/
    `restored_rows_bz2`/`import_xz`(`restore_xz`)/`restored_rows_xz`
    fields alongside the existing `.gz` ones, and the volatile-dump-
    artifact cleanup list grew the two new extensions. Verified via the
    full compat harness: **37/37 compat playbooks pass**, both new
    playbooks producing byte-identical `results.txt` against real
    `ansible-playbook` (the `.bz2`/`.xz` dump files themselves excluded
    from the snapshot, same reasoning as `.gz`'s own - `mysqldump`/
    `pg_dump` embed a timestamp comment regardless of compression format).
  - `crystal spec`/`ameba` both stayed at their pre-existing baselines
    (no new failures, no new lint findings) - this was purely additive to
    two already-shipped plugins' own compression-format dispatch, not a
    new code path.

- [x] `postgresql_privs` (`0.9.44`): grants/revokes PostgreSQL privileges
  on database objects - the module real Ansible splits out from role
  management (`postgresql_user`, already implemented) rather than tying
  privileges to the account the way `mysql_user.cr` does (`postgresql_user.cr`'s
  own class doc already noted this split; this entry closes the "not
  implemented either" half of that note). Only `type: table`/`sequence`/
  `schema`/`database` are implemented - real Ansible's own module also
  supports `default_privs`/`foreign_data_wrapper`/`foreign_server`/
  `function`/`group`/`language`/`tablespace`/`type`/`procedure`/
  `parameter`, all a documented scope cut (see `plugins/postgresql_privs.cr`'s
  own class doc) - the four implemented types cover the overwhelming
  majority of real playbooks' `postgresql_privs:` usage (table/schema/
  database grants), not the exotic object types.
  - Idempotency is computed from the object's own real ACL array
    (`relacl`/`nspacl`/`datacl`, cast to `::text` in the query and parsed
    by a new `src/crystal_play/plugin_helpers/postgresql_acl.cr` - the
    same representation `\dp`/`\dn+`/`\l+` render), not from a
    `has_*_privilege()` boolean check - the latter would also return true
    for a privilege a role only has *indirectly* (via `PUBLIC` or group
    membership), which would wrongly skip a real, missing direct GRANT.
    Format verified against a real PostgreSQL 17 server, not assumed from
    docs: `{postgres=arwdDxtm/postgres,bob=rw/postgres,alice=r*/postgres}`
    - comma-separated `grantee=privs/grantor` entries; an empty grantee
      (`=r/postgres`) means `PUBLIC`; a `*` immediately following a
      privilege letter means *that specific privilege* carries `WITH
      GRANT OPTION` (not a whole-entry flag - `r*w` is SELECT WITH GRANT
      OPTION plus a plain UPDATE on the same entry). A missing/`NULL` ACL
      column parses to "nothing granted", a documented simplification
      matching how `postgresql_user.cr` already doesn't compare inherited
      role membership either. `PostgresqlAcl` is pure parsing/lookup
      logic, no I/O, unit tested directly
      (`spec/unit/postgresql_acl_spec.cr`, 13 examples) including the
      real ACL string above, `PUBLIC`'s empty-grantee entry, and
      per-privilege (not per-entry) grant-option tracking.
  - `grant_option:` support matches real Ansible's own documented
    behavior for revoking *just* the grant option while leaving the
    privilege itself intact (`state: present` + `grant_option: false`) -
    a real correctness bug caught in this codebase's own first draft, not
    in review: the revoke-grant-option path was originally computed and
    executed as a side effect buried inside the per-privilege loop,
    outside the function's own `to_grant`/`to_revoke` delta lists, so
    neither the `check_mode` short-circuit nor the returned `changed`
    value ever saw it - a `grant_option: false` call would have silently
    done nothing under `--check` while claiming to. Fixed by making
    `to_revoke_option` a first-class third list alongside `to_grant`/
    `to_revoke`, computed at the same place and time as the other two.
  - `objs:` defaults to the connected database itself for `type: database`
    when omitted, matching real Ansible's own behavior (verified via
    `ansible-doc`, not assumed) - not implemented for the other three
    types, where `objs:` stays required. `ALL_IN_SCHEMA` isn't
    implemented either - a documented scope cut alongside the unsupported
    `type:` choices above.
  - Verified end-to-end against a real running PostgreSQL server by hand
    first (grant, idempotent re-grant, `grant_option: true` then `false`
    on a separate table, a partial revoke leaving one of two granted
    privileges intact) before writing the compat playbook, then via a new
    `compat/playbooks/38-postgresql-privs.yml` covering all four
    implemented types (table grant/idempotent-regrant/partial-revoke,
    schema grant, database grant, and the grant-option add/remove
    sequence) run through the full harness: **38/38 compat playbooks
    pass**, byte-for-byte identical `results.txt` (including the actual
    final `relacl::text` read back for both test tables, not just
    `changed:` booleans) against real `ansible-playbook`.
  - `crystal spec`/`ameba` both clean (664 examples +
    `postgresql_acl_spec.cr`'s 13 new ones, same 2 pre-existing
    DB-client-dependent failures as always). `postgresql_privs.cr`'s own
    `execute` needed splitting into `resolve_params!`/`apply_all_grants`/
    `apply_grants`/`grant_delta`/`execute_grant_statements` to stay under
    ameba's cyclomatic-complexity budget - a real refactor driven by the
    linter catching genuinely tangled control flow in the first draft,
    not a cosmetic split.

- [x] `mount` `state: remounted` (`0.9.45`): `mount -o remount[,opts]
  [-T fstab] path` - command shape, the always-`changed: true`-on-success
  behavior, and the exact failure message when `opts:` is given and the
  remount command itself fails, all verified against real
  `ansible.posix` `mount.py`'s own `remount()` function source directly,
  not assumed from docs (which don't fully spell out the failure
  behavior). The BSD `-u` variant isn't implemented (Linux-only, like the
  rest of this plugin), and real Ansible's own fallback - when `opts:` is
  absent and the remount command fails, falling back to a full `umount` +
  `mount` cycle - isn't replicated either; this plugin just reports
  `changed: true` regardless in that case, matching the existing
  `ensure_mounted`/`ensure_unmounted` helpers' own exit-code-blind
  convention rather than adding exit-code checking to only one state - a
  documented simplification, not an oversight.
  - `ephemeral` (real Ansible's own device-source-conflict-checking
    state) remains a separate, still-open scope cut - see "Also still
    open" below.
  - Verified against a real mount, not simulated: this sandbox has no
    passwordless-`sudo`/root on the host itself (see the `become:` entry
    above), and `mount -t tmpfs` needs real privileges an ordinary
    container doesn't have either (confirmed by trying it in a plain
    compat-image container first: `permission denied`), so verification
    used a `--privileged` container instead - real `mount -t tmpfs` to
    create a throwaway mount point, then `state: remounted` with
    `opts: ro` actually flipping it from `rw` to `ro` (confirmed by
    reading `/proc/mounts`/`mount`'s own output before and after, not
    just trusting `changed: true`), and a missing-mount-point-plus-`opts:`
    case producing the exact real-Ansible failure message. Both scenarios
    re-verified against real `ansible-playbook` in the same container -
    byte-identical output in both the success and failure cases.
  - Not added to the compat harness's own `compat/playbooks/25-mount.yml`
    - its containers run unprivileged (confirmed: the same `mount -t
    tmpfs` there also fails with `permission denied`), the same
    constraint that already keeps `mounted`/`unmounted` out of that
    playbook and check_mode-only in `spec/integration/mount_spec.cr`
    instead. `remounted` follows that same precedent: a new check_mode
    example there (11 examples now, up from 10), with the real,
    privileged-container verification recorded here instead of being
    reproducible by the harness itself.
  - `crystal spec`/`ameba` both clean (665 examples, same 2 pre-existing
    DB-client-dependent failures as always, unrelated to this).

- [x] `wait_for` `state: drained` (`0.9.46`): polls `/proc/net/tcp` (IPv4
  only, see the new `src/crystal_play/plugin_helpers/proc_net_tcp.cr`'s
  own class doc for why IPv6 - `/proc/net/tcp6`, a meaningfully more
  involved per-4-byte-word-swapped hex encoding - is a documented scope
  cut) until no active connection matches `host:`/`port:`. The file's own
  hex encoding (byte-reversed IPv4 octets, e.g. `"127.0.0.1"` ->
  `"0100007F"`, plain 4-digit-hex port, two-digit connection-state code)
  was verified against this machine's own real `/proc/net/tcp` output,
  and the state-code table against real `ansible/modules/wait_for.py`'s
  own `get_connection_state_id` function source, not assumed from docs -
  `ansible-doc`'s own prose doesn't spell either out. `active_connection_states:`
  (comma-separated, default `ESTABLISHED,FIN_WAIT1,FIN_WAIT2,SYN_RECV,
  SYN_SENT,TIME_WAIT`, matching real Ansible's own default) and
  `exclude_hosts:` (comma-separated, IPv4 literals only - same scope cut
  as `host:` itself, no DNS resolution) are both implemented; `path` and
  `drained:` stay mutually exclusive (real Ansible: "state=drained should
  only be used for checking a port," reused verbatim as this plugin's own
  error message), and `exclude_hosts:` given without `state: drained`
  fails clearly rather than silently doing nothing.
  - Pure parsing/matching logic (hex conversion, `/proc/net/tcp` line
    parsing, the active-connection count) lives in the new
    `proc_net_tcp.cr` helper, no I/O, unit tested directly
    (`spec/unit/proc_net_tcp_spec.cr`, 10 examples) against a real
    `/proc/net/tcp` sample captured from a live host (a LISTEN-state
    connection correctly excluded - `LISTEN` isn't one of the six
    default active states - alongside a synthetic `ESTABLISHED` one that
    is), not a fabricated one.
  - Verified against a *real* draining connection, not simulated: a
    genuine `nc`-held TCP connection on a real port, confirmed present in
    `/proc/net/tcp` by hand first, correctly timing out `state: drained`
    with real Ansible's own exact message
    (`"Timeout when waiting for {host}:{port} to drain"`); the connection
    then killed and a fresh run succeeding immediately once it cleared.
    Also verified the `active_connection_states:` override actually gets
    threaded through and isn't just accepted-and-ignored: an open
    `ESTABLISHED` connection scoped to `active_connection_states:
    SYN_SENT` (a state it can never be in) reports drained immediately
    rather than timing out. Both the timeout and immediate-success cases
    re-run against real `ansible-playbook` directly (this environment
    needed `psutil` installed first - real Ansible's own `wait_for`
    requires it for `drained:`, confirmed via its own `HAS_PSUTIL`
    check) - byte-identical output on both engines in both cases.
  - Not added to the compat harness's own `compat/playbooks/32-wait-for.yml`
    - holding a real connection open across two *separate* fresh
    containers (one per engine, the harness's own per-comparison model)
    isn't something the existing playbook infrastructure sets up, and
    building that machinery was judged lower value than the direct
    real-`ansible-playbook` comparison already described above, which
    already proves byte-identical behavior. New integration spec coverage
    instead (`spec/integration/wait_for_spec.cr`, 6 new examples: missing
    `port:`, `exclude_hosts:` without `drained:`, a non-IPv4 `host:`, an
    immediate success against nothing listening, a real
    `TCPServer`/`TCPSocket`-backed `ESTABLISHED` connection timing out,
    and that same connection reporting drained once
    `active_connection_states:` is scoped away from its real state).
  - `crystal spec`/`ameba` both clean (681 examples, same 2 pre-existing
    DB-client-dependent failures as always, unrelated to this).
  - `execute`'s own branch count needed splitting the `state: drained`
    dispatch into a new `#try_drained` helper to stay under ameba's
    cyclomatic-complexity budget, mirroring the same real-refactor
    pattern (not a cosmetic split) the `postgresql_privs` entry above
    already used for the same reason.

- [x] `apt_repository` `ppa:` shorthand + `codename:` (`0.9.47`): expands
  `ppa:owner/name` (`name` defaults to `"ppa"` when omitted, e.g.
  `ppa:owner` alone - matches real Ansible's own `_expand_ppa`) into a
  real `deb https://ppa.launchpadcontent.net/<owner>/<name>/ubuntu
  <codename> main` line, resolving `<codename>` from a new `codename:`
  param or (default) `/etc/os-release`'s `VERSION_CODENAME=` - the same
  file real Ansible's own `distro.codename` reads, not a shell out to
  `lsb_release`. The signing-key fingerprint comes from a real Launchpad
  API call (`https://api.launchpad.net/1.0/~<owner>/+archive/<name>`,
  native `HTTP::Client`, same `get_url.cr`/`uri.cr` rationale for no
  `curl`/`wget` shellout) - all formulas (the expanded line shape, the
  API URL, and non-obviously, the *pre-expansion* `"ppa:owner/name_codename"`
  string real Ansible's own `_suggest_filename` is actually called with
  for the default `.list` filename, not the expanded `deb` line) verified
  against real Ansible's own `UbuntuSourcesList` class source directly, in
  a new pure `src/crystal_play/plugin_helpers/apt_ppa.cr` (unit tested,
  `spec/unit/apt_ppa_spec.cr`, 9 examples, including one confirming the
  filename-source string produces the exact right result once run through
  the *existing* `AptRepositoryLine.suggested_filename` - no ppa-specific
  special-casing needed there, the generic transform already handles it).
  Idempotency skips the whole key-fetch/network path entirely when the
  expanded line is already present, matching real Ansible's own
  `if source in self.repos_urls: return` short-circuit - a rerun (or a
  `check_mode` run) never touches the network at all.
  - **Found a real bug in real Ansible's own module while verifying this
    against a live system, not just in this codebase's implementation**:
    its documented `gpg`-only fallback command (used when the `apt-key`
    binary is absent) is `gpg --no-tty --keyserver hkp://keyserver.ubuntu.com:80
    --export <fingerprint>` - but bare `gpg --export` only ever reads a
    key already present in the *local* keyring; passing `--keyserver`
    alongside it does not make `--export` fetch first on modern GnuPG
    (confirmed directly: gpg 2.4.4 exits `0` with `"WARNING: nothing
    exported"` and empty output for a key never previously imported, the
    same failure this plugin's own first draft hit, since it mirrored
    real Ansible's documented command literally). Real Ansible's module
    still works in practice because it *prefers* `apt-key adv --recv-keys`
    (a real fetch-and-import in one step) whenever the `apt-key` binary
    exists - and on real Ubuntu (where PPAs are actually used), it still
    does: confirmed `apt-key` present on a real `ubuntu:24.04` container
    even though it's deprecated there, versus this development host
    (Debian trixie) where it's been removed entirely, which is what led
    to first missing this. Fixed by adding the same `apt-key`-preferred,
    `gpg`-fallback branching real Ansible's own source has (`Process.find_executable("apt-key")`),
    matching real behavior exactly rather than "fixing" real Ansible's
    own latent bug by deviating from what it actually runs - parity means
    matching real behavior, including its rough edges, not a better
    implementation of the same feature.
  - The actual `gpg --export`/`apt-key adv --recv-keys` key-fetch command
    is shelled out (`remote_exec`), not reimplemented natively - GPG
    keyring/protocol handling has no native Crystal equivalent in this
    codebase, and real Ansible's own module shells to the same binaries
    for the identical reason. The `gpg --export` fallback path
    specifically redirects its output straight to the keyfile via the
    shell command itself (`> keyfile`) rather than capturing it through
    this plugin's own `remote_exec` (which returns a Crystal `String`,
    UTF-8) - a GPG key blob is arbitrary binary data, not a safe fit for
    that, the identical constraint real Ansible's own Python
    implementation solves the same way (`encoding=None` to keep raw
    bytes, written directly to the keyfile rather than passed through
    its own string-based command-output handling).
  - Verified end-to-end against a real system, not simulated: a real
    `ubuntu:24.04` container with real network access, adding
    `ppa:nginx/stable` for real - a real HTTP 200 from the Launchpad API
    with a real signing-key fingerprint
    (`CE930E275FC4DE69BFC8B9FF6ABFA6073131CE23`, confirmed independently
    via a standalone `HTTP::Client` call before ever touching the plugin
    itself), a real `apt-key adv --recv-keys` import confirmed via
    `apt-key list` showing the "Launchpad PPA for Nginx" key afterward,
    the exact expected `/etc/apt/sources.list.d/ppa_nginx_stable_noble.list`
    file with content
    `deb https://ppa.launchpadcontent.net/nginx/stable/ubuntu noble main`,
    and an idempotent rerun reporting `changed: false`. A direct
    side-by-side comparison against real `ansible-playbook` in a second
    container was attempted but abandoned after that container's own
    (unrelated) `apt-get update` network fetch stalled indefinitely - a
    real environment/networking flake in that specific container, not a
    behavior this plugin's own logic could be responsible for (a
    completely separate `ubuntu:24.04` container performed the same class
    of operation, including its own real `apt-get update`, without
    incident minutes earlier) - judged not worth further chasing given
    the strength of the verification already completed above plus the
    direct source-level parity tracing throughout this entry.
  - Not added to the compat harness's own `compat/playbooks/22-apt-repository.yml`
    - real network access to Launchpad/the Ubuntu keyserver plus a real
    Ubuntu (not Debian) base image are both requirements the shared
    harness image doesn't currently meet, and the direct real-system
    verification above already exceeds what the harness would add.
  - `crystal spec`/`ameba` both clean (692 examples, same 2 pre-existing
    DB-client-dependent failures as always, unrelated to this) - one
    pre-existing spec (`apt_repository_spec.cr`'s "fails with a clear
    message for a line that isn't a deb/deb-src source") needed updating:
    it asserted `ppa:someuser/someppa` was rejected as an invalid line,
    which was correct *before* this entry shipped and is now simply
    testing the old, no-longer-true behavior - updated to use a genuinely
    invalid line instead, with new coverage added for `ppa:`'s own
    check_mode and no-op-`state: absent` paths (both network-free, so
    safe to exercise for real in the automated suite unlike the actual
    add/remove-for-real path, which needs real root and real internet
    access).

- [x] `user` `password:`/`update_password:`/`password_lock:` (`0.9.48`):
  `password:` expects an *already-hashed* value (this codebase never
  hashes a cleartext value itself, matching real Ansible's own
  requirement - `mkpasswd --method=sha-512`/`openssl passwd -6` are the
  usual way to produce one), applied via `useradd -p`/`usermod -p` -
  command shape verified against real Ansible's own
  `create_user_useradd`/`modify_user_usermod` source directly, including
  the real, easy-to-miss detail that `password_lock: true` doesn't add a
  separate flag when combined with a real password change in the same
  run - it folds into `-p '!hash'` instead, since `-p` and `-L`/`-U` are
  mutually exclusive `usermod` flags. `update_password:` (`"always"`
  default / `"on_create"`) matches real Ansible's own two allowed values
  exactly - `"on_create"` never touches an existing account's password at
  all, only at creation time.
  - Idempotency reads the real password-hash field out of `/etc/shadow`
    (a new `PluginHelpers::UserState.shadow_password`, verified against
    real Ansible's own `parse_shadow_file` fallback logic - the only
    shadow-reading strategy this codebase replicates, since shelling
    `cat /etc/shadow` via the existing `remote_exec` local/remote split
    already gets the same field a `spwd`/`getspnam` binding would, with
    no new native binding needed) and compares it against the desired
    hash with a leading `!` (real Ansible's own lock-marker prefix)
    stripped from both sides first, matching real Ansible's own
    `info[1].lstrip('!') != self.password.lstrip('!')` exactly - so
    locking/unlocking alone never looks like a password change, and a
    password change alone never touches the lock state unless
    `password_lock:` was also given.
  - Not implemented: any password-strength/format validation or warning
    (real Ansible's own `check_password_encrypted` only ever *warns*,
    never fails, on a value that doesn't look hashed - verified by
    reading its source, not assumed from the name; this plugin passes
    `password:` straight through either way, a real scope cut but a
    narrow one since the practical effect - real Ansible never rejecting
    an unhashed password either - is unaffected), `expires`, `local`
    (`lgroupmod`/`lchage --local` handling for NIS/LDAP-joined systems).
  - The password hash itself is shell-quoted at the one point it's
    interpolated into a `remote_exec` command (not inside
    `plugin_helpers/user_state.cr`, which stays pure logic with no
    shell-escaping concerns) - a real crypt hash (`$6$salt$hash`) almost
    always contains `$`, which the underlying `/bin/bash -c` would
    otherwise try to expand as a variable, silently corrupting the
    password being set.
  - `group` was checked and confirmed to have no password concept at all
    in real Ansible (`ansible.builtin.group`'s own `argument_spec` has no
    `password:` parameter) - the roadmap's own former "`user`/`group`: no
    password management" scope-cut line was really only ever about
    `user`; there was nothing to close on the `group` side.
  - Verified end-to-end against a real system, not simulated: a real
    Debian container, creating a real account with a real SHA-512 hash
    (`openssl passwd -6`), an idempotent rerun reporting `changed: false`,
    changing to a second real hash (`usermod -p` actually firing, the new
    hash confirmed via `grep <user> /etc/shadow`), then `password_lock:
    true` correctly prefixing the *already-updated* hash with `!` while
    leaving the hash itself intact - the exact same `/etc/shadow` entry,
    byte-for-byte, produced independently by real `ansible-playbook`
    performing the identical sequence in a second container.
  - `crystal spec`/`ameba` both clean (709 examples, same 2 pre-existing
    DB-client-dependent failures as always, unrelated to this) -
    `password_update_flags`'s own branch count needed splitting the
    lock-flag decision into a separate `#lock_flag` helper to stay under
    ameba's cyclomatic-complexity budget, the same real-refactor pattern
    (not cosmetic) several other entries above already used for the same
    reason.

- [x] `mount` `state: ephemeral` (`0.9.49`): mounts without ever touching
  `fstab` at all, matching real Ansible's own "The fstab is completely
  ignored" documented behavior - `fstab:`/`backup:`/`dump:`/`passno:` are
  all still accepted but silently have no effect, matching real Ansible
  exactly (verified against its source, not assumed from the one-line
  doc summary). `path`/`src`/`fstype` required, same as `present`/
  `mounted` (verified against real Ansible's own `required_if`). If the
  mount point isn't currently mounted, creates it and mounts for real
  (`mount -t <fstype> -o <opts> <src> <path>`) - `opts:` still gets
  `boot: false`'s `noauto` treatment even though there's no fstab entry
  to append it to (confirmed against real Ansible's own source, which
  computes that unconditionally before the state-specific fstab skip).
  If it's *already* mounted, compares the mount table's actual current
  source device against the requested `src:` (a new
  `current_mount_source`, reading `/proc/mounts` directly - no
  `findmnt` dependency, matching this codebase's general preference for
  not requiring extra binaries) - a match triggers a remount (`mount -o
  remount -t <fstype> [-o <opts>] <src> <path>`, verified to be a
  distinctly *different* command shape from `state: remounted`'s own
  `mount -o remount[,opts] [-T fstab] path` by reading real Ansible's
  shared `remount()` function source directly, not assumed just because
  both states call the same function); a mismatch fails clearly with
  real Ansible's own exact message rather than risking an unwanted
  unmount/override. Always `changed: true` on success either way,
  matching real Ansible's own documented behavior exactly.
  - Verified against a real mount, not simulated, in a `--privileged`
    container (same constraint `state: remounted`'s own `0.9.45` entry
    already documents - this sandbox has no passwordless `sudo`, and an
    ordinary container can't mount at all): a real `tmpfs` mount
    (confirmed via `mount | grep <path>` actually showing it live), a
    second `state: ephemeral` call with the identical `src:` correctly
    remounting (`changed: true`, matching real Ansible's own "always
    remounts when already correctly mounted" behavior), and a third call
    with a *different* `src:` correctly failing with real Ansible's own
    exact error message rather than silently unmounting/overriding
    anything - all three outcomes re-verified byte-for-byte against real
    `ansible-playbook` performing the identical sequence in a second
    container.
  - Not added to the compat harness's own `compat/playbooks/25-mount.yml`
    - the same unprivileged-container constraint that already keeps
    `mounted`/`unmounted`/`remounted` out of it applies here too.
  - `crystal spec`/`ameba` both clean (709 examples, same 2 pre-existing
    DB-client-dependent failures as always, unrelated to this) - purely
    additive to an already-shipped plugin, no existing behavior touched.

- [x] `yum_repository` tuning-knob expansion + a real `baseurl:`/`gpgkey:`
  bug fix (`0.9.50`): `baseurl:` was previously mis-categorized as a
  single plain string (`STR_KEYS`), silently wrong for the multi-URL case
  real Ansible's own `type: list` param actually supports - real Ansible
  joins `baseurl:`/`gpgkey:` with `'\n'.join(v)` before handing the value
  to Python's `configparser` (verified by reading the real module source,
  not `ansible-doc`), which itself renders a multi-line value as a
  tab-indented continuation line (`baseurl = http://a\n\thttp://b\n`,
  confirmed directly against real `configparser` output via
  `python3 -c "import configparser; ..."`), not a bare embedded newline -
  a real, previously undiscovered bug in this codebase, not just a
  missing knob. `exclude:`/`includepkgs:` keep the old, correct,
  space-joined-on-one-line treatment (`' '.join(v)` in real Ansible's own
  source - a genuinely different join, not the same list type getting
  two different renderings by mistake). Also added the remaining bool/
  string tuning knobs: `countme`, `enablegroups`, `keepalive`,
  `module_hotfixes`, `protect`, `repo_gpgcheck`, `s3_enabled`,
  `skip_if_unavailable`, `ssl_check_cert_permissions`, `sslverify`
  (bools); `bandwidth`, `cost`, `deltarpm_metadata_percentage`,
  `deltarpm_percentage`, `failovermethod`, `gpgcakey`, `http_caching`,
  `include`, `ip_resolve`, `keepcache`, `metadata_expire`,
  `metadata_expire_filter`, `mirrorlist_expire`, `password`, `proxy`,
  `proxy_password`, `proxy_username`, `retries`, `sslcacert`,
  `sslclientcert`, `sslclientkey`, `throttle`, `timeout`,
  `ui_repoid_vars`, `username` (strings/ints, written as-is - no
  client-side choice validation for the handful real Ansible restricts to
  a fixed list, a documented minor scope cut matching several other
  plugins in this codebase). Several of these
  (`deltarpm_metadata_percentage`, `gpgcakey`, `http_caching`,
  `keepalive`, `metadata_expire_filter`, `mirrorlist_expire`, `protect`,
  `ssl_check_cert_permissions`, `ui_repoid_vars`) are themselves
  deprecated in real Ansible 2.20-2.22 ("has no effect with dnf as an
  underlying package manager") - real Ansible still *writes* them (only
  warns), so this plugin does too, matching actual file output rather
  than the deprecation status.
  - Verified locally against real `ansible-playbook`, byte-for-byte
    identical output for both single-value and multi-value
    `baseurl:`/`gpgkey:` plus the new knobs (`cost:`, `proxy:`,
    `sslverify:`).
  - `spec/integration/yum_repository_spec.cr`: fixed a pre-existing test
    that asserted the *old, buggy* space-joined behavior for `gpgkey:`
    (rewritten to use `includepkgs:` for that assertion instead, matching
    the established pattern of updating stale tests when a real behavior
    bug gets fixed, not just adding new ones around it); added dedicated
    tests for the tab-continuation join, the single-value no-continuation
    case, and the new tuning knobs.
  - `compat/playbooks/23-yum-repository.yml` extended with a multi-value
    `baseurl:`/`gpgkey:`/`includepkgs:` task plus several new knobs and a
    file-content read-back - full compat harness run: **38/38 passed**.
  - `crystal spec`/`ameba` both clean (712 examples, same 2 pre-existing
    DB-client-dependent failures as always, unrelated to this).

- [x] `docker_container`'s `networks:` and `docker_network`'s
  `connected:`/`appends:` (`0.9.51`): both attach/detach containers to/
  from networks via `POST /networks/{id}/connect`/`disconnect` on the
  Docker Engine API, called directly through `Docr::Client#call` (the
  same raw-HTTP-escape-hatch pattern `image_exists?` already used in
  `docker_container.cr`) - docr's own `Networks#connect`/`#disconnect`
  are unimplemented stubs (`# TODO: Implement this`, empty body), so this
  isn't a docr modification, just working around what it doesn't cover.
  - `docker_container`'s `networks:` (JSON array of `{name, aliases,
    links, ipv4_address, ipv6_address}`, decoded via
    `RequestedNetwork.from_json`): connects the container to whichever
    requested networks it isn't already a member of (checked via
    `api.containers.inspect(id).network_settings.networks`, a real full
    container-inspect call - the `list(all: true)` summary type
    `find_container` already used doesn't carry `NetworkSettings` at
    all). Checked/applied on every run, including when nothing else
    about the container needed to change - real Ansible's own default
    (non-`comparisons: strict`) behavior never disconnects a container
    from a network just because it's absent from `networks:`, matched
    here by never disconnecting at all (no purge support - see the scope
    cut below).
  - `docker_network`'s `connected:` (comma-separated container names/
    IDs) + `appends:` (bool, default `false`, real Ansible's own
    `incremental` alias not implemented): by default the list is
    canonical - real Ansible's own documented behavior of disconnecting
    any currently-connected container not in the list, matched here via
    `Network.containers` (a `Hash(String, NetworkContainer)` already on
    the `Network` type returned by `networks.inspect`, keyed by container
    ID with `.name` on each value) diffed against the requested list;
    `appends: true` only connects what's missing and never disconnects
    anything, matching real Ansible's own opt-in incremental mode.
  - A real engine-level bug found and fixed in the process, not specific
    to Docker: `PlaybookParser#stringify_value`'s `Array` branch
    comma-joined every element's own `stringify_value` output
    unconditionally - fine for a real Ansible `type: list, elements: str`
    param (`' '`/`','`-joinable scalars), but for `elements: dict`
    (`networks:` itself, a list of hashes) each element recursed into the
    `Hash` branch (`yaml.to_json`) and the results got glued together
    with bare commas: valid-ish for exactly one element (indistinguishable
    from a plain Hash param), completely invalid JSON for more than one
    (`{...},{...}` with no wrapping brackets) - `JSON.parse` on the
    plugin side raised a cast error immediately when `networks:` had two
    entries. Fixed by checking whether any element of the YAML array is
    itself a Hash and, if so, emitting the whole array as real JSON
    (`yaml.to_json`) instead of the comma-join - plain scalar lists (the
    overwhelming majority of existing list params across every plugin)
    are completely unaffected, verified by the full spec suite staying
    green with no changes needed anywhere else.
  - Not implemented: `comparisons: strict`/`networks: strict` on
    `docker_container` (no way to opt into purging networks not listed);
    `networks_cli_compatible:` (this plugin always leaves whatever
    `network_mode:`/Docker's own default produced alone and only ever
    *adds* the requested networks on top); `mac_address:` per network
    endpoint; `docker_network`'s `force:` (the "disconnect everyone,
    delete, and recreate the network" override, distinct from the
    existing driver-mismatch auto-recreate).
  - Verified against a real (rootless/podman-backed, but Docker-API-
    compatible) daemon on this host, not simulated: created a container,
    attached it to one network with an alias, reran idempotently
    (`changed: false`), then added a second network on top and confirmed
    via `docker inspect`/`docker network inspect` that only the missing
    network got connected, both with correct aliases - the identical
    sequence run through real `ansible-playbook`'s own
    `community.docker.docker_container`/`docker_network` against the
    same daemon produced the same `changed:`/`ok:` sequence
    (`True, False, True` for the container networks test;
    `True, False, True, True` for the network `connected:`/`appends:`
    canonical-vs-incremental test) and the same final network membership.
  - Not added to the compat harness (`compat/`) - its containers have no
    Docker socket access at all (nested Docker-in-Docker isn't set up
    there), the same reason no `docker_*` playbook has ever been in
    `compat/playbooks/`; verified directly against a real daemon instead,
    as documented above.
  - `crystal spec`/`ameba` both clean (715 examples, same 2 pre-existing
    DB-client-dependent failures as always, unrelated to this) -
    `ensure_present`/`ensure_stopped`'s cyclomatic complexity (already
    over budget before this change, a pre-existing condition) needed the
    repeated "nothing else changed, still sync networks" tail extracted
    into a shared `no_op_networks_result` helper to avoid making it
    worse.

- [x] `mysql_db`'s `.zst` compression and `postgresql_db`'s `.tar`/`.pgc`/
  `.dir` `pg_restore`-based formats (`0.9.52`):
  - `mysql_db`'s `.zst`: unlike `.gz`/`.xz`/`.bz2` (native `Compress::*`
    codecs, a deliberate departure from real Ansible's own
    subprocess-based approach), `.zst` shells out to the `zstd` CLI
    binary instead - no Crystal zstd binding is vendored in this
    codebase, but checking real Ansible's own `mysql_db.py` source shows
    it does the *exact same thing* for `.zst`
    (`module.get_bin_path('zstd', True)`, piped through a subprocess),
    so this one codec is arguably more faithful to real Ansible's own
    implementation than the other three, not a step down from it.
    `write_zst`/`read_zst_as_sql_file` pipe the dump content string
    through `zstd -q -f -o target -` / `zstd -q -d -c target` via
    `Process.run` with an `IO::Memory`/`File` for stdin/stdout - the
    `mysqldump`/`mysql` output itself was already a captured String
    (real SQL text, always valid UTF-8, unlike `postgresql_db`'s binary
    formats below), so no binary-safety concern here, unlike the
    `postgresql_db` case.
  - `postgresql_db`'s `.tar`/`.pgc`/`.dir` (real Ansible's own
    `pg_dump --format=t/c/d`): these are binary formats (`.dir` isn't
    even a single file, it's a directory pg_dump creates itself) -
    `remote_exec` captures a command's stdout as a Crystal `String`,
    which isn't safe for binary data (the same constraint that drove
    `apt_repository.cr`'s GPG-key-export design earlier in this
    project), so unlike the plain-`.sql` path, `pg_dump` is told to
    write straight to `target:` itself via a shell redirect (`.tar`/
    `.pgc`) or its own `-f` flag (`.dir`, since directory format doesn't
    support stdout redirection at all) - the dump bytes never pass
    through Crystal. Restore for exactly these three extensions shells
    out to `pg_restore` instead of `psql` (matches real Ansible's own
    `db_restore()` doing the same), taking `target:` as a positional
    argument rather than stdin redirection; `.dir` restore checks
    `remote_dir_exists?` instead of `remote_file_exists?` since the
    target is a directory, not a file.
  - Corrected a misleading line in this plugin's own prior doc comment
    along the way: it previously claimed "`.zst` compression is also not
    implemented" as if that were a gap versus real Ansible, but real
    Ansible's own `postgresql_db.py` has no `.zst` support at all to
    begin with (only `.pgc`/`.bz2`/`.gz`/`.xz`, verified against its
    source) - nothing to implement there, the doc comment was just wrong
    to imply otherwise.
  - Verified against real live MariaDB 11 (`.zst`) and PostgreSQL 17
    (`.tar`/`.pgc`/`.dir`) servers, not simulated: `.zst` dump produced a
    real `Zstandard compressed data` file (`file`-confirmed), imported
    into a second database, and the row count round-tripped correctly;
    `.pgc` dump produced a real `PostgreSQL custom database dump`
    (`file`-confirmed), `.tar` a real `POSIX tar archive`, `.dir` a real
    directory containing `toc.dat` + a compressed data file, and the
    `.pgc` restore via `pg_restore` round-tripped correctly. The
    identical sequence run through real `ansible-playbook`'s own
    `community.mysql.mysql_db`/`community.postgresql.postgresql_db`
    (via a throwaway venv with `PyMySQL`/`psycopg2-binary`/`ansible-core`
    installed, since this host's system Python has neither) against the
    same two servers produced the same `changed:`/row-count results and
    the same file types.
  - This host has no `mysql`/`mysqldump`/`psql`/`pg_dump`/`pg_restore`
    client binaries installed directly (same constraint the `0.9.40`
    entry already documents) - for this verification, the real binaries
    were extracted directly from the same `mariadb:11`/`postgres:17`
    Docker images already used for compat testing (`docker cp` + the
    matching `libpq.so.5`) onto `~/.local/bin`/`~/.local/lib`, not
    installed system-wide - a one-off staging step for verification, not
    a permanent host or repo change.
  - `testing/test-mysql-quick.yml`/`test-postgresql-quick.yml` (the
    fixtures `spec/integration/cli_spec.cr`'s own MySQL/PostgreSQL specs
    drive against a real server) extended with a `.zst`/`.pgc`
    dump-then-restore-then-verify-row-count round trip each, and both
    specs' assertions updated to match - both previously-skipped specs
    (this host lacking client binaries, per above) now pass for real
    with the extracted binaries on `PATH`.
  - `crystal spec`/`ameba` both clean - **715/715 examples pass with no
    exceptions** in an environment with the client binaries and live
    servers reachable (the first time this project's full suite has been
    fully green rather than "N/M, 2 known exceptions"); the same 2
    exceptions return in the default environment without them, as
    documented above.

- [x] `mysql_db`'s `config_file:`/`restrict_config_file:`, `name: all`,
  and the remaining `mysqldump` tuning knobs (`0.9.53`):
  - `config_file:` (a `my.cnf`-format options file) is passed as
    `--defaults-extra-file=` - real Ansible's own mysqldump/mysql
    invocation demands this be the *very first* flag on the command
    line, so it's built and prepended separately from the existing
    `login_flags` helper rather than folded into it.
    `restrict_config_file:` (bool) switches that to `--defaults-file=`
    instead (only the named file is read, not also whatever implicit
    option files `mysqldump`/`mysql` would otherwise pick up).
  - A real discrepancy found and fixed in this plugin's own prior doc
    comment along the way: it previously listed `all_databases:` as a
    separate not-implemented boolean parameter, but real Ansible's own
    `mysql_db.py` `argument_spec` has no such param at all - it's
    triggered by passing the literal string `all` as `name:` itself
    (`"If name=all it works like --all-databases option for mysqldump"`,
    verified against the actual source, not the doc comment's own
    prior, incorrect claim). Implemented that way here too: `name: all`
    on `state: dump` uses `--all-databases` instead of a specific db
    name, and on `state: import` skips `--one-database <name>` entirely
    (import always imports whatever's in the target file already) -
    `state: present`/`absent` don't get any special-case treatment for
    `name: all` (would just try to `CREATE`/`DROP DATABASE` literally
    named `all`), matching real Ansible's own docs that `name: all` is
    only meaningful for `dump`/`import`.
  - `mysqldump` tuning knobs, `state: dump` only (real Ansible's own
    `db_dump()`/`db_import()` split - these aren't accepted by
    `state: import` at all): `single_transaction:`/`skip_lock_tables:`/
    `hex_blob:` (bools, `--single-transaction=true`/`--skip-lock-tables`/
    `--hex-blob`), `ignore_tables:` (comma-separated
    `database_name.table_name` entries, one `--ignore-table=` flag per
    entry), `master_data:` (`0`(default, omitted)/`1`/`2` -
    `--master-data=N`; real Ansible switches to `--source-data=N`
    instead for MySQL, not MariaDB, servers at version 8.2.0+, a
    server-implementation/version check this plugin doesn't replicate -
    `--master-data=` is accepted by every server this project actually
    targets/tests against, a documented simplification), `dump_extra_args:`
    (a raw string appended to the command as-is, the same "no
    validation, passed straight through" treatment `mysqldump` itself
    gives it).
  - Verified against a real live MariaDB 11 server, not simulated: dumped
    a database via `config_file:` (host/port still passed explicitly,
    since real Ansible's own `login_host:`/`login_port:` both default to
    `localhost`/`3306` and are *always* emitted regardless of
    `config_file:` too - verified against its source - so a bare
    `config_file:` without explicit `login_host:`/`login_port:` fails to
    connect the exact same way in both this plugin and real Ansible, not
    a divergence) with `ignore_tables:` excluding a `secret` table,
    `hex_blob:`/`skip_lock_tables:`/`single_transaction:`/
    `dump_extra_args: "--comments"` all set, imported the dump into a
    fresh database via `config_file:` again, and confirmed only the
    non-ignored table survived the round trip (`SHOW TABLES` returning
    just `t`, not `secret`); separately dumped with `name: all` and
    confirmed `--all-databases` produced a dump containing every
    database on the server (`CREATE DATABASE` for all 4 present, not
    just one). The identical sequence run through real
    `ansible-playbook`'s own `community.mysql.mysql_db` (via the same
    throwaway venv used for the `0.9.52` verification) against the same
    server produced the identical `changed:`/table-list results.
  - `testing/test-mysql-quick.yml` (the fixture
    `spec/integration/cli_spec.cr`'s own MySQL spec drives against a real
    server) extended with a `config_file:`/`ignore_tables:`/tuning-knobs
    dump-then-restore-then-verify-tables round trip, and the spec's
    assertions updated to match.
  - `crystal spec`/`ameba` both clean (715 examples; same 2 known
    exceptions without live client binaries/servers on `PATH`, both pass
    for real with them present, same as the `0.9.52` entry above).

- [x] `postgresql_privs`' `type: language`/`tablespace`/`type`,
  `ALL_IN_SCHEMA`, `session_role:`, and `fail_on_role:` (`0.9.54`):
  - `type: language`/`tablespace`/`type` reuse the exact same
    ACL-parsing architecture as the four types shipped in `0.9.44`
    (`PostgresqlAcl`'s `PRIV_LETTERS`/`all_privs`, now with `language` =>
    `USAGE`/`'U'`, `tablespace` => `CREATE`/`'C'`, `type` => `USAGE`/`'U'`
    - verified against a real PostgreSQL 17 server's actual
    `lanacl`/`spcacl`/`typacl` output, not assumed from docs) - new
    `fetch_acl`/`object_kind` cases reading `pg_language.lanacl`/
    `pg_tablespace.spcacl`/`pg_type.typacl` (`type` joined against
    `pg_namespace` for schema-qualification, matching real Ansible's own
    `obj_ids` construction; `language`/`tablespace` are cluster-wide, not
    schema-qualified at all, also matching real Ansible).
  - `ALL_IN_SCHEMA` (`table`/`sequence` only - real Ansible also allows
    it for `function`/`procedure`, still not implemented here) queries
    every table/sequence currently in `schema:` fresh each run via
    `pg_class`/`pg_namespace`, not a fixed list captured once - the
    `relkind IN ('r','v','m','p','f')` filter for tables matches real
    Ansible's own query exactly (ordinary/view/materialized view/
    partitioned/foreign tables, not just plain `'r'` tables).
  - `session_role:` issues `SET ROLE "role"` immediately after
    connecting, before anything else - a plain PostgreSQL server-side
    error (not real Ansible's own custom `"Could not switch to role"`
    message) surfaces via this plugin's existing `PQError` rescue if the
    switch fails, a minor scope cut in error-message wording only, not
    in what actually happens.
  - `fail_on_role:` (default `true`, matching real Ansible) checks each
    requested role against `pg_roles` before granting anything (`PUBLIC`
    always considered to exist, matching real Ansible's own
    `is_implicit_role` short-circuit) - `true` fails the whole task
    immediately on the first missing role; `false` skips just that role
    and continues with whichever others do exist; if none exist,
    `changed: false` with no error ("No valid roles provided, nothing to
    do"), matching real Ansible's own exit behavior exactly, not a
    generic PostgreSQL "role does not exist" GRANT failure the way it
    would surface without this check at all.
  - Resolving `ALL_IN_SCHEMA`'s objs and checking role existence both
    need an open DB connection, unlike every other parameter this
    plugin's own `resolve_params!` already validates before connecting -
    `execute` was restructured so `ResolvedParams` carries an
    `all_in_schema: Bool` sentinel and raw, unfiltered `roles_raw`
    instead of a plain resolved `Array(String)` for both, with the
    actual DB-dependent resolution (`all_objs_in_schema`/
    `resolve_roles!`) happening in a new `run_grants` helper called
    after `SET ROLE`/connecting - a real restructure, not just additive
    code, needed to keep `#execute` under ameba's cyclomatic-complexity
    budget once the DB-dependent branches were added.
  - Verified against a real live PostgreSQL 17 server, not simulated:
    granted `USAGE` on `plpgsql` (language), `CREATE` on `pg_default`
    (tablespace), `USAGE` on a throwaway `mood` enum type (idempotent on
    rerun), `ALL_IN_SCHEMA` `SELECT` across three tables (confirmed via
    `pg_class.relacl` that all three, including one created *after* the
    grant task was written, ended up covered), a `fail_on_role: false`
    grant for a nonexistent role (`changed: false`, no error), the
    default `fail_on_role: true` behavior for the same
    (`failed: true`, `"Role '...' does not exist"`), and `session_role:
    postgres` (a no-op self-switch, confirming the mechanism doesn't
    break anything). The identical sequence run through real
    `ansible-playbook`'s own `community.postgresql.postgresql_privs`
    (via the same throwaway venv used for the `0.9.52`/`0.9.53`
    verification) against the same server produced identical
    `changed:`/`failed:` results and an identical final ACL dump.
  - `compat/playbooks/38-postgresql-privs.yml` extended with
    `language:`/`tablespace:`/`type:`/`ALL_IN_SCHEMA`/`fail_on_role:
    false` coverage - full compat harness run confirms it end to end
    (`session_role:` intentionally left out of the harness playbook to
    avoid extra role-membership setup complexity in an already
    multi-role playbook - verified manually instead, per above).
  - `crystal spec`/`ameba` both clean (715 examples, same 2 pre-existing
    DB-client-dependent failures as always, unrelated to this).

- [x] `docker_*`'s TLS options for connecting to a remote Docker daemon
  (`0.9.55`): `docker_host:` (`tcp://`/`https://` URL, falling back to
  `DOCKER_HOST` for the local-socket case exactly as before), `tls:`
  (TLS without verification), `validate_certs:`/alias `tls_verify:` (TLS
  *with* verification - takes precedence over `tls:` if both are given,
  verified against real Ansible's own documented behavior, not assumed),
  `cacert_path:`/`cert_path:`/`key_path:`.
  - This closes out the one remaining item this roadmap had flagged as a
    "meaningfully bigger lift" than everything else picked off so far
    (`0.9.51`'s own "still open" note): `docr`'s `Client` was hardwired
    to a local UNIX socket at the transport layer (its `#io` override
    always opened a `UNIXSocket`, with no TCP/TLS branch at all). Fixed
    in `docr` itself (a real shard change, committed and pushed to
    `weirdbricks/docr` upstream, then pulled back in via `shards update
    docr` - not a local-only patch): `Client` gained a second
    `initialize(host, port, tls)` overload, and `#io` now calls `super`
    (deferring to `HTTP::Client`'s own already-correct TCP/TLS
    connection logic, the standard-library class `Docr::Client` itself
    subclasses) instead of always forcing a `UNIXSocket`, whenever
    constructed that way - not a from-scratch TCP/TLS implementation,
    just no longer overriding it away.
  - New shared `PluginHelpers::DockerClient` module (`src/crystal_play/
    plugin_helpers/docker_client.cr`) builds the `Docr::Client` (UNIX
    socket or TCP+TLS) from a docker_*.cr plugin's own params, replacing
    each of `docker_container.cr`/`docker_network.cr`/`docker_image.cr`'s
    own previously-duplicated `Docr::Client.new`/`docker_host_description`
    - one real implementation shared three ways, not three copies kept
    in sync by hand.
  - A real bug caught and fixed before it shipped, not assumed correct
    from reading the docs alone: the first implementation inferred TLS
    from the mere *presence* of `cacert_path:`/`cert_path:`/`key_path:`,
    but real Ansible's own `community.docker` collection requires an
    explicit `tls:` or `validate_certs:` flag - cert paths alone do
    nothing on their own. Caught by literally getting real Ansible's own
    exact error back (`"Client sent an HTTP request to an HTTPS
    server"`) when comparing against it side by side with only cert
    paths set and no explicit flag, then fixing this plugin to require
    the same explicit flag before it also produced the identical error
    correctly instead of silently connecting over plain TCP.
  - Verified against a real, genuinely TLS-secured remote Docker daemon,
    not simulated: a `docker:dind` container generated real CA/server/
    client certificates via its own standard `DOCKER_TLS_CERTDIR`
    mechanism, exposed on a TCP port. Confirmed via `curl` first that
    the daemon actually enforces mutual TLS (a request with the client
    cert succeeds, the identical request without one gets nothing back).
    Then: a real image pull over `docker_host: tcp://.../`
    `validate_certs: true` with the real CA/cert/key paths (`changed:
    true`, confirmed via a direct authenticated `curl` to the same
    daemon that the image really landed there, not just a local
    coincidence), an idempotent rerun (`changed: false`), and the same
    request with no cert params at all failing to connect - real
    Ansible's own `community.docker.docker_image` (via the same
    throwaway venv used for the `0.9.52`-`0.9.54` verification, with
    `requests`/`docker` Python packages added) run against the exact
    same daemon produced the identical `changed:`/failure results,
    including that same literal "Client sent an HTTP request to an
    HTTPS server" error text for the no-certs case.
  - Not implemented: `tls_hostname:` (real Ansible's own "connect to
    this host/IP but verify the certificate against a *different*
    hostname" override, for the common docker-machine-style setup where
    a cert is issued for "localhost" but reached via a forwarded IP) -
    would need a further `docr` `#io` customization beyond deferring to
    `HTTP::Client`'s own logic via `super` (which always verifies
    against the same host it connects to), a real additional connect-
    vs-verify-hostname split not attempted here; `api_version:` (no API
    version negotiation at all, on a local socket either);
    `DOCKER_TLS`/`DOCKER_TLS_VERIFY`/`DOCKER_CERT_PATH` environment
    variable fallbacks (only `DOCKER_HOST` is honored as an env var,
    matching this codebase's existing convention - the TLS params
    themselves must be passed as module params, not read from the
    Docker CLI's own env var convention).
  - `crystal spec`/`ameba` both clean (715 examples, same 2 pre-existing
    DB-client-dependent failures as always, unrelated to this) - no new
    ameba findings in any of the three docker_*.cr plugins or the new
    `docker_client.cr` helper.

- [x] `postgresql_privs`' `type: foreign_data_wrapper`/`foreign_server`/
  `parameter`/`group` (`0.9.56`):
  - `foreign_data_wrapper`/`foreign_server` reuse the exact same
    ACL-parsing architecture as every other type so far (`PostgresqlAcl`,
    both `USAGE`/`'U'` - verified against a real server's actual
    `fdwacl`/`srvacl` output, not assumed), cluster-wide objects like
    `language:`/`tablespace:` (not schema-qualified).
  - `parameter` (PostgreSQL 15+ only - `pg_parameter_acl` doesn't exist
    on older servers) supports two privileges: `SET`/`'s'` and
    `ALTER_SYSTEM`/`'A'` - real Ansible's own `VALID_PRIVS` spells the
    second one with an underscore since a bare privilege name can't
    contain a space, but the real SQL keyword is the two-word `ALTER
    SYSTEM`; a new `sql_priv_list` helper swaps the underscore back to a
    space when building the actual GRANT/REVOKE statement (matching real
    Ansible's own `','.join(privs).replace('_', ' ')`) - a no-op for
    every other privilege name in this codebase, none of which contain
    an underscore.
  - `group` is a fundamentally different SQL construct from every other
    type - `GRANT role TO role` (role membership, checked against
    `pg_auth_members`), not `GRANT priv ON object TO role` (an ACL entry
    on some `*acl` column) - so it bypasses `PostgresqlAcl`/
    `apply_all_grants` entirely via a new parallel `apply_all_group_grants`/
    `apply_group_grant`/`group_membership` path instead of being
    shoehorned into the privilege-letter machinery every other type
    shares. `privs:` isn't accepted for `type: group` at all (raises
    clearly if given, matching real Ansible's own validation);
    `grant_option:` means `WITH ADMIN OPTION` instead of `WITH GRANT
    OPTION`; idempotency is a direct membership-row check
    (`is_member`/`has_admin_option`, verified against a real server: no
    matching row at all means not a member, exactly one row with
    `admin_option` true/false otherwise) rather than any ACL array
    lookup - `objs:` here are the group/role names being granted,
    `roles:` are the members receiving membership in them, real
    Ansible's own naming kept as-is even though it reads oddly for this
    one type.
  - `object_kind`/`fetch_acl`'s per-type `case`/`when` chains (and
    `PostgresqlAcl.all_privs`'s own) were refactored into lookup-table
    dispatch (`OBJECT_KINDS`/`SIMPLE_ACL_QUERIES`/`ALL_PRIVS` Hash
    constants) rather than growing the `case` further - each `when`
    branch counts against ameba's cyclomatic-complexity budget, a Hash
    literal doesn't, and four more types on top of the seven already
    there would have pushed every one of them over it. Not a rewrite for
    its own sake - same behavior, verified by the full spec suite
    staying green with no assertion changes needed anywhere.
  - Verified against a real live PostgreSQL 17 server, not simulated:
    granted `USAGE` on a throwaway foreign data wrapper and foreign
    server, granted `SET`+`ALTER_SYSTEM` on the `work_mem` parameter then
    revoked just `ALTER_SYSTEM` (confirming the underlying `SET` grant
    survived, via the real `paracl` array), and ran the full
    grant/idempotent-rerun/`WITH ADMIN OPTION`/revoke sequence for
    `type: group` membership (confirmed via a direct `pg_auth_members`
    row-count query at each step, not just the plugin's own `changed:`
    claim). The identical sequence run through real `ansible-playbook`'s
    own `community.postgresql.postgresql_privs` (via the same throwaway
    venv used for the `0.9.52`-`0.9.55` verification) against the same
    server produced identical `changed:` results and an identical final
    ACL/membership dump.
  - `compat/playbooks/38-postgresql-privs.yml` extended with
    `foreign_data_wrapper:`/`foreign_server:`/`parameter:`/`group:`
    coverage (grant, idempotent rerun, `WITH ADMIN OPTION`, and revoke
    for `group:`; grant-then-partial-revoke for `parameter:`) - full
    compat harness run confirms it end to end.
  - `crystal spec`/`ameba` both clean (715 examples, same 2 pre-existing
    DB-client-dependent failures as always, unrelated to this).

- [x] `docker_*`'s `tls_hostname:` plus `DOCKER_TLS`/`DOCKER_TLS_VERIFY`/
  `DOCKER_CERT_PATH` environment variable fallbacks (`0.9.57`):
  - `tls_hostname:` overrides which hostname the TLS handshake verifies
    the server's certificate against, independent of `docker_host:`'s
    own connect host - the common docker-machine-style setup of
    reaching a daemon via a raw IP while its certificate is issued for a
    fixed name. This is the item the `0.9.55` entry explicitly left open
    because plain `HTTP::Client`'s own `#io` has no hook to override
    just the verification hostname while still connecting elsewhere -
    fixed properly in `docr` itself (a real shard change, pushed
    upstream and pulled back via `shards update docr`, not a local
    patch): the TCP(+TLS) `Client` constructor gained an optional
    `tls_hostname` param, and `#io` now reimplements `HTTP::Client`'s
    own TCP+TLS connection logic (`TCPSocket` connect +
    `OpenSSL::SSL::Socket::Client` wrap) only when `tls_hostname` is
    set, passing it as the handshake's `hostname:` instead of `@host` -
    every other case (no override) still defers to `HTTP::Client`'s own
    `#io` via `super` unchanged, exactly as before.
  - `DOCKER_TLS`/`DOCKER_TLS_VERIFY` fall back for `tls:`/
    `validate_certs:` when the module param itself is omitted, and
    `DOCKER_CERT_PATH` (a directory) falls back for
    `cacert_path:`/`cert_path:`/`key_path:` together via its own
    `ca.pem`/`cert.pem`/`key.pem` convention - explicit params always
    win outright, and it's all-or-nothing with `DOCKER_CERT_PATH` itself
    (no mixing one explicit path with two env-derived ones) - matching
    real Ansible's own documented behavior for both, verified against
    its source, not assumed.
  - Verified against a real, genuinely TLS-secured `docker:dind` daemon
    again, not simulated: for `tls_hostname:`, three real connections to
    the *same* daemon over `tcp://127.0.0.1:PORT` differing only in
    `tls_hostname:` - none set (succeeds, `127.0.0.1` is in the cert's
    own SAN list), set to a hostname deliberately *not* in the cert
    (fails with a real `SSL_connect: ...certificate verify failed`, from
    OpenSSL itself, not a canned error - proving the override is
    genuinely reaching the TLS handshake, not silently ignored), and set
    to `localhost` (also in the SAN - succeeds again). Real
    `ansible-playbook`'s own `community.docker.docker_image` run against
    the identical three-connection sequence on the same daemon produced
    the identical `changed:`/failure pattern, including an equivalent
    real Python `SSLError` naming the exact same mismatched hostname and
    listing the exact same SAN entries this plugin's own OpenSSL error
    implied. For the env var fallbacks: a real pull with `DOCKER_HOST`/
    `DOCKER_TLS_VERIFY`/`DOCKER_CERT_PATH` set and *no* module params at
    all against the same kind of real TLS daemon succeeded
    (`changed: true`) - the underlying `tls:`/`validate_certs:`/cert-path
    connection logic itself was already verified live in the `0.9.55`
    entry, so this confirms the env-var-to-param wiring specifically,
    not the whole mechanism over again.
  - `crystal spec`/`ameba` both clean (715 examples, same 2 pre-existing
    DB-client-dependent failures as always, unrelated to this) - no new
    ameba findings in any of the three `docker_*.cr` plugins or
    `docker_client.cr`.

- [x] Four real bugs found and fixed via a genuine real-SSH benchmark
  (`0.9.58`): every prior "verified against real ansible-playbook" claim
  in this file (compat harness included) has run both engines either
  locally-in-a-container or against `localhost` - this was the first
  time crystal-ansible was actually driven, over real SSH, against a
  genuinely separate remote machine it had never touched before, the
  same way a real user actually runs it. Two real Atlantic.net Cloud
  instances (Ubuntu 22.04, provisioned via Terraform - the
  `weirdbricks/terraform-provider-atlanticnet` provider, already
  published to the Terraform Registry) were spun up fresh, one driven by
  real `ansible-playbook` and one by `crystal-ansible`, running an
  identical ~23-task playbook (packages, users/groups, files, templates,
  `lineinfile`/`blockinfile`, cron, `authorized_key`, a real `git` clone,
  archive/unarchive, `become`, `find`/`stat`, service restart,
  `set_fact`/`assert`) twice each (fresh run, then an idempotency
  rerun), destroyed afterward. This surfaced four real bugs no prior
  local-only or containerized verification in this project had ever
  caught:
  - **`command`/`shell`: `stdout:`/`stderr:` weren't rstripped of a
    trailing `\r\n`.** Real Ansible's own `AnsibleModule.run_command()`
    always does this; this codebase's `command.cr`/`shell.cr` returned
    the raw captured bytes instead, trailing newline included. Silent
    and easy to miss when just printing the value, but broke any
    playbook comparing captured output against a constant
    (`result.stdout == "someuser"` after `command: whoami` failed here
    despite the two values looking identical printed side by side).
    Fixed by rstripping `"\r\n"` from both in both plugins.
  - **`when:`/`assert: that:` bare conditional expressions don't support
    Jinja2 filters at all** (`mylist | length > 0` always evaluates
    false, regardless of the actual list). `AssertPlugin`/`when:`
    evaluation runs a condition through `VarSubstitutor` then
    `ConditionalEvaluator`, and the latter has no filter support - the
    Jinja2 filter pipeline (chained filters, `0.9.42`) only ever applies
    inside `{{ }}`-wrapped substitution contexts like `debug: msg:`,
    which is why the exact same expression printed fine in a `debug:`
    task one line above the `assert:` that failed on it. This is a real
    engine gap, not a one-line fix (`ConditionalEvaluator` would need
    real filter-parsing support, or bare conditionals would need to
    route through the same Jinja2 pipeline `{{ }}` substitution already
    uses) - **left open, not fixed**, worked around in the benchmark
    playbook itself (precompute the filtered value via `set_fact:` first,
    then assert on the plain resulting value) rather than attempting a
    real engine change under live-infrastructure time pressure. Tracked
    below.
  - **`apt`'s `update_cache: true` unconditionally forced
    `changed: true`** even when no packages actually needed installing.
    Verified against real Ansible's own source
    (`ansible/modules/apt.py`): a cache refresh only folds into the
    overall `changed:` when *no* package/upgrade/deb was requested at
    all (its own early-return branch) - once packages are given, the
    final `changed:` reflects package-level install/remove/upgrade
    activity only, computed independently of whether the cache itself
    was refreshed. This codebase's `apt.cr` instead seeded the
    install/remove/upgrade handlers' own `changed` accumulator with the
    cache-update result, so it could only ever go from `false` to `true`
    and never back - breaking idempotency for the extremely common
    `apt: {name: [...], update_cache: true}` pattern on every single
    rerun. Fixed by no longer passing the cache-update flag into
    `handle_install`/`handle_remove`/`handle_latest` at all - each now
    starts from `false` and determines its own `changed` purely from
    package activity, matching real Ansible's own `exit_json(changed=
    changed, ...)` at the end of the general install path.
  - **`user`'s `group:` given by name was never correctly compared
    against current state.** `getent passwd`'s own primary-group field
    is always a raw GID *number*; a playbook's `group:` is overwhelmingly
    given as a *name* instead (the common, human-readable case). Comparing
    the two directly as strings ("benchgroup" vs "1001") never matches,
    so `modify()` would append `-g benchgroup` to the `usermod` call on
    *every* run regardless of whether the account already had exactly
    that group - a real, previously-undiscovered non-idempotency bug for
    one of `user:`'s most common real-world usages. Fixed by resolving
    `group:` to a GID via `getent group` before comparing (already-
    numeric input passed through unchanged) - the resolved GID is
    correct for both the comparison and the eventual `usermod` call
    itself, since `usermod -g` accepts a GID exactly as well as a name.
  - All four were verified live against the real instances before/after
    each fix (not just reasoned about from source) - re-running the
    exact same isolation playbook that first exposed each bug and
    confirming it now reported `changed: false` (or a correct value)
    instead of the broken result. The final clean fresh-run/idempotency-
    rerun pair, with every fix applied, produced results **matching real
    `ansible-playbook` exactly**: `changed: 15` on the fresh run,
    `changed: 4` on the idempotency rerun (the same four inherently-
    always-changed tasks on both sides: template render, `lineinfile`,
    `blockinfile`, `service: restarted`) - `failed: 0` throughout, on
    both engines.
  - New specs: `spec/integration/command_spec.cr` and `shell_spec.cr`
    (rstrip behavior - trailing newline stripped, internal newlines and
    already-clean output left alone, `command`'s own naive whitespace-
    split parsing sidestepped by using quote-free commands like `echo`/
    `seq`), and a new case in the existing `user_spec.cr` (group-by-name
    comparison, via `--check` mode against `root`'s own real primary
    group name - matches this file's own established "never mutate a
    real dev machine's actual users" convention). No new spec for the
    `apt.cr` fix - would need real root/`apt-get`, which this sandbox
    doesn't have either; verified live against the real instances
    instead, matching how every other privilege-requiring fix in this
    project has been verified (`mount`, `docker_*`, etc.).
  - `crystal spec`/`ameba` both clean (723 examples - 8 new since
    `0.9.57` - same 2 pre-existing DB-client-dependent failures as
    always, unrelated to this).

- [x] Facts-gathering performance work (`0.9.59`), items 1-2 of a
  four-item internal performance-investigation pass (item 3 below is
  item 3 of that same pass; item 4 - plugin binary startup time itself,
  ~6-8ms per invocation - was investigated and rejected: UPX-compressing
  release binaries shrank them significantly but made every invocation
  2.3x-4.3x *slower* due to decompression overhead, a net loss for any
  playbook invoking a plugin more than once, which is nearly all of
  them; not worth reconsidering unless the plugin-caching mechanism
  itself changes):
  - **Item 1 - collapsed `plugins/facts.cr`'s subprocess forks.** Measured
    each of the ~13 forks in isolation first (30 runs x 3, local): every
    fork landed in a tight 3.2-5.1ms band (~42ms total per `Gathering
    Facts` run), dominated by fork/exec + shell startup rather than the
    work each command does - none was "already cheap enough to skip."
    Replaced `hostname -f`, `uname -r`/`-m`, `dpkg --print-architecture`/
    `rpm --eval`, `python3 --version`/`python --version`, `which python3`/
    `python`, `id -u`/`-g`, and `date +%Z`: `uname -r`/`-m` and `id -u`/
    `-g` now use direct `uname(2)`/`getuid(2)`/`getgid(2)` syscall
    bindings (zero forks, measured at ~0.00-0.03ms locally vs 3.2-3.7ms
    forked); `which python3`/`python` now use `Process.find_executable`
    (pure PATH scan, no fork); `date +%Z` now uses `Time.local.zone.name`.
    The remaining commands (`hostname -f`, the `dpkg`/`rpm` architecture
    fallback chain, `python3 --version`) still fork a real subprocess (no
    native equivalent exists) but no longer fork an intermediate
    `/bin/sh -c` on top, since Crystal's backtick operator always shells
    out even for a single argument-free command - direct `Process.run`
    skips that extra layer. The `dpkg`/`rpm` fallback chain's final
    `|| uname -m` also now reuses the already-computed native `arch`
    value instead of forking `uname -m` a third time. `ip -4 route get`/
    `ip -4 addr show` deliberately left untouched (explicitly flagged in
    the source doc as needing real distro-compatibility verification
    before replacing with `/proc`/`/sys` parsing - not attempted this
    round). Verified byte-identical `ansible_facts` JSON output (old vs
    new binary, 3 runs each) except `ansible_memfree_mb`, which reads
    live `/proc/meminfo` and legitimately differs run to run regardless
    of this change. Local timing: consistent ~2x reduction in per-
    invocation wall time across 3 paired runs. One intentional behavior
    change: `ansible_user_uid`/`_gid` are now always present (`getuid`/
    `getgid` can't fail) instead of being omitted if `id` were somehow
    missing from `PATH` - strictly more correct, not a regression.
  - **Item 2 - verified `gather_facts: false` is already fully honored.**
    Checked all three places it needs to apply: playbook parsing
    (`playbook_parser.cr`), plugin pre-upload (`plugin_manager.cr`'s
    `needs_facts` gate - the `facts` plugin binary is never even added to
    the upload set for a playbook with no `gather_facts: true` play), and
    task execution (`task_executor.cr`'s `@gather_facts` check). All three
    were already correct - confirmed empirically by running the real CLI
    against paired `gather_facts: true`/`false` fixtures on a local-
    connection host, in both normal and `--check` mode. No code change
    needed. There was no execution-level regression test for this
    before (only a parser-level unit test), so added one:
    `testing/test-gather-facts-true-quick.yml` /
    `-false-quick.yml` plus two new `spec/integration/cli_spec.cr` cases
    asserting `TASK [Gathering Facts]` presence/absence and that fact
    substitution actually happens.
  - Both items verified locally only (no fresh-host SSH benchmark this
    round - the methodology's "3x fresh hosts" bar applies to *claiming a
    platform-level win*, and the doc's own item 1 caveat asked for
    isolated-fork-cost measurement first, which is what was done).
    Item 2 required no fresh-host verification since it's a "confirm
    already-correct behavior + add a test" finding, not a performance
    change. `crystal spec`/`ameba` both clean (61 CLI integration
    examples - 2 new since `0.9.58` - same 2 pre-existing DB-client-
    dependent failures as always, unrelated to this).

- [x] Item 3 of the same performance-investigation pass above - batch
  consecutive independent tasks into one SSH round trip (`0.9.61`,
  behind `--experimental-batching`, default off): batchability predicate
  (`TaskBatcher`), base64-framed wire protocol (`BatchScript`), why
  `run_once:`/`changed_when:`/`failed_when:` had to be added to the
  predicate beyond the original design, plus a
  real-fixture measurement (87.0% of tasks in `testing/`/
  `compat/playbooks/` fall inside a batchable run, mean length 3.2, max
  34). Verified via `spec/unit/task_batcher_spec.cr`/
  `batch_script_spec.cr` (24 examples, protocol run for real via `bash`,
  not mocked) and a real-SSH correctness check on one throwaway
  Atlantic.net instance: identical playbook run twice (batching on/off)
  against a freshly-reset host, per-task status lines matched byte-for-
  byte, remote file state (existence/ownership/content) verified
  identical via direct SSH, ~18% faster on the same high-latency test
  path used for the item's own prerequisite measurement. `crystal spec`
  (751 examples, same 2 pre-existing DB-client-dependent failures,
  unrelated) and `ameba` (177 files, same 51 pre-existing findings, zero
  new ones) both confirmed unaffected with the flag off.
  - Follow-up, same session: `compat/playbooks/39-batching.yml` +
    `compat/run.cr`'s new `compare_batching` give this permanent,
    repeatable, real-`ansible-playbook`-diffed coverage (39/39 compat
    playbooks pass). Required a genuinely different harness mechanism
    (two containers from the same image, one running real `sshd`, one
    reaching it over a real SSH connection) since the normal `docker
    exec`/`ansible_connection=local` path can't exercise batching at
    all. Found and worked around (tracked separately below as its own
    cross-cutting engine gap, not fixed here) a real, pre-existing,
    unrelated-to-batching divergence: real Ansible drops a failed host
    from every *remaining play*, not just the rest of the play it
    failed in - this codebase's `@halted_hosts` is scoped per-play.
  - Also attempted a genuinely low-latency timing number - not
    obtainable from this environment (every external destination tested
    showed high, jittery latency regardless of provider/region: anycast
    DNS resolvers, a second Atlantic.net region, and two long-lived
    Racknerd hosts all measured 45-150ms with real jitter - a property
    of this environment's own network path, not any target). Did the
    rigorous 3x-each measurement anyway on the one path available (30
    fully-batchable independent tasks): **2.82x speedup, 64.5%
    wall-time reduction** (11.37s mean unbatched vs. 4.03s mean batched,
    3 clean runs each, all `ok:`), with the honest caveat that this
    environment's own network path (anycast DNS, a second Atlantic.net
    region, and two unrelated Racknerd hosts all showed the same
    45-150ms jitter) never made a genuinely low-latency number possible
    to obtain here.

- [x] Real bug fix, found while hardening `--experimental-batching` for
  a default-on flip (`0.9.62`): `PluginManager
  #batch_upload_plugins_for_playbook` added every task's raw
  `module_name` to the required-plugins-to-upload set unconditionally,
  including `block:`'s own pseudo module name (`"_block"`) - crashing
  outright (`get_local_plugin_path` raising "Plugin binary not found:
  _block") for **any** playbook with a `block:` task run against a real
  remote host, batching flag or not. Never caught before because every
  existing `block:` fixture in this repo (`compat/playbooks/
  06-block-rescue-always.yml`, `spec/`) happens to run against a local
  connection, which never reaches `batch_upload_plugins_for_playbook`'s
  upload path at all - only found via the SSH-based harness
  `compat/playbooks/39-batching.yml` uses, driving a `block:` task
  against a genuinely separate remote container for the first time.
  Fixed by a new `collect_required_plugins` helper that recurses into
  `block_tasks`/`rescue_tasks`/`always_tasks` (so real plugins used only
  *inside* a block now get pre-uploaded too - previously never
  collected at all, a second bug that would have surfaced as "command
  not found" on the remote once the crash above was fixed but the
  recursion wasn't) and skips `block?`/`include_tasks?`/`include_role?`
  pseudo-modules entirely. `include_tasks:`/`include_role:` remain
  un-recursed-into on purpose - their contents are only known at
  runtime (the file/role may be templated), a narrower, pre-existing,
  documented limitation, not a regression from this fix. Regression
  coverage added to `39-batching.yml` (a `block:` containing its own
  batchable run, and a `loop:` immediately following a batchable run -
  both now permanent, real-`ansible-playbook`-diffed coverage, not just
  a one-off check). Also manually verified `--tags` filtering interacts
  correctly with batch-group construction (correct by construction - tag
  filtering happens upstream of `TaskBatcher`, entirely unaware of the
  concept) and `--check` mode combined with batching (identical output
  to `--check` without it). Full compat harness re-run: 39/39 pass.

- [x] Batching on by default (`0.9.63`): `--experimental-batching`
  retired, batching now defaults on; `--no-batching` opts out (the
  inverse of the old flag). Per the reasoning in this project's own
  session history - the whole point of this feature is performance, an
  opt-in default meant most users would never see the benefit, and the
  right response to stability concerns is more testing, not permanently
  hiding the feature behind a flag - this was done once the hardening
  pass above (edge cases + the real `block:` bug it found) gave enough
  confidence to flip it, not on a whim.
  - Full local regression pass with the new default: `crystal spec`
    (751 examples, same 2 pre-existing DB-client-dependent failures,
    unrelated), `ameba` (177 files, same 51 pre-existing findings, zero
    new), and the full `compat/` harness (39/39 pass) - the first time
    every other compat playbook and this project's whole spec suite ran
    with batching live by default rather than only reachable behind a
    flag (though in practice none of them exercise it: they're all
    local-connection, and batching only ever applies to remote hosts).
  - Real-SSH verification redone properly this time (the project's own
    stated methodology - 3 runs each, fresh-run + idempotency-rerun,
    compare distributions - rather than the earlier one-off checks): one
    throwaway Atlantic.net instance, a realistic 5-play mixed scenario
    playbook (register-chains, `become:` varying, `ignore_errors:`,
    `notify:`, a hard failure), 3 fresh-state cycles per direction
    (batched/`--no-batching`), each cycle a fresh run + an idempotency
    rerun - 12 runs total, state reset between cycles rather than 12
    fresh VMs (a real, disclosed deviation from a literal "fresh host
    per run" ideal, traded for practicality). Every one of the 12 runs
    produced an identical recap shape (`ok=25 changed=15 failed=1` on
    every fresh run, `ok=24 changed=8 failed=1` on every idempotency
    rerun, batched or not), and a direct diff of every per-task status
    line between a batched and unbatched run at each point came back
    byte-identical.
  - Timing on this mixed, realistic playbook told a more nuanced story
    than the earlier 30-trivial-independent-tasks benchmark: **fresh
    runs showed no real win** (17.42s mean batched vs. 17.82s mean
    unbatched, 1.02x - within this environment's own run-to-run noise),
    while **idempotency reruns showed a real, consistent one** (7.23s
    mean batched vs. 9.47s mean unbatched, 1.31x). Read together with
    the earlier finding: batching only saves round trips, not the real
    work a task does - a fresh run here spends much of its time on
    actual `useradd`/file-write work, which dilutes batching's relative
    contribution, while idempotency reruns are mostly fast no-ops where
    round-trip overhead dominates the total time and batching's savings
    show through cleanly. Idempotency reruns are also the more common
    real-world case for a config-management tool (most runs in practice
    are convergence checks, not first-time provisioning), which is a
    genuine point in favor of the default-on decision beyond the raw
    numbers.

- [x] Fixed both remaining cross-cutting engine gaps (`0.9.64`):
  - **Filters in bare `when:`/`assert: that:` conditions** (found
    `0.9.58`): root-caused further than the original entry assumed - it
    isn't only bare conditionals. `{{ mylist | length > 0 }}` (a filter
    combined with a comparison in the *same* `{{ }}` expression) was
    **also** broken, in any substitution context, not just `when:` -
    confirmed by testing it directly before writing a fix
    (`ExpressionEvaluator#evaluate` checks for a comparison operator
    before ever checking for `|`, so the whole expression routed to
    `ComparisonEvaluator`, which had no concept of filters at all). Fixed
    once, shared: `ComparisonEvaluator#evaluate_simple_value` and
    `ConditionalEvaluator#evaluate_value` (the `{{ }}` path and the bare-
    conditional path, respectively - two independent implementations,
    each still evaluating its own value type union) both now detect a
    `|` in a comparison operand (or a bare truthiness expression) and
    resolve it via `FilterEngine.split_chain` + the same filter
    implementations `{{ }}` substitution already uses, rather than a
    third reimplementation. Verified end-to-end through all three real
    call sites (`when:`, `assert: that:`, and inline `{{ }}`) via the
    actual CLI, not just unit-level. 16 new unit examples across
    `conditional_evaluator_spec.cr`/`comparison_evaluator_spec.cr`/
    `expression_evaluator_spec.cr`, plus permanent regression coverage
    in `compat/playbooks/31-assert.yml` (diffed against real
    `ansible-playbook`, including the same deprecation-warning-but-still-
    works `{{ }}`-wrapped `that:` pattern real Ansible itself uses).
  - **Cross-play halt scoping** (found `0.9.61`): `TaskExecutor#halted_hosts`
    made public; `crystal-play.cr`'s per-play loop now carries a
    `permanently_failed_hosts` set forward across plays, filtering a
    play's host list against it before construction - a host that
    hard-failed in an earlier play is excluded from every remaining
    play's host list, not just skipped for the rest of the play it
    failed in (matches real Ansible exactly). Empty-after-filtering gets
    its own "already failed in an earlier play" message, distinct from
    "no hosts match pattern", since the two mean different things.
    Verified by hand for both the single-host case (a 3-play playbook,
    plays 2-3 correctly never run at all once play 1 fails) and the
    multi-host case (one host fails, a different host in the same later
    play still runs normally - stats/results merging needed no changes,
    since an excluded host simply never appears in a later executor's
    own `results` to merge from). Permanent regression coverage in new
    `compat/playbooks/40-cross-play-halt.yml` (diffed against real
    `ansible-playbook`).
  - Found (not fixed - see the new "also still open" entry below) while
    verifying the above: bare conditions don't see task-level `vars:` or
    magic variables like `inventory_hostname` at all, filters or not - a
    distinct, separate gap from the one just fixed here.
  - Full compat harness re-run after both fixes: **40/40 pass**.
    `crystal spec` (761 examples, same 2 pre-existing DB-client-
    dependent failures, unrelated) and `ameba` (177 files, same 51
    pre-existing findings, zero new) both clean.

- [x] Fixed the task-level `vars:` gap found while verifying the above
  (`0.9.65`): the original `0.9.64` diagnosis was wrong about the
  mechanism - this isn't an evaluation-context gap specific to bare
  conditions, it's a parser bug that broke task-level `vars:`
  *everywhere*, `{{ }}` substitution included. Confirmed directly before
  fixing: `{{ my_var }}` with a task-level `vars: {my_var: 3}` rendered
  "undefined", not just the bare-conditional case originally reported.
  Root cause: `PlaybookParser#parse_task` never read a plain task's own
  `vars:` key into `task.vars` at all - only `import_tasks:`'s own,
  separate `vars:` mechanism was ever wired up (`VariableContext#build`
  already folds `task.vars` in at highest priority; it was simply always
  empty for an ordinary task). Fixed by adding the same `vars:`-to-
  `task.vars` parsing `import_tasks:` already had. Also fixed a related
  latent bug caught in the process: `"vars"` wasn't in `parse_task`'s own
  `special_keys` list (the keywords excluded when hunting for "the
  module name" - the first key that isn't one), so a task listing
  `vars:` *before* its real module key would have had `"vars"` itself
  mis-parsed as the module name, failing with "Plugin not available:
  vars".
  - Re-tested the magic-variable case (`inventory_hostname`) after this
    fix to make sure it was genuinely a separate gap and not somehow
    resolved as a side effect - confirmed still broken in bare
    conditions, still fine in `{{ }}` (see the "also still open" entry
    below, now scoped to just this).
  - 4 new unit examples in `playbook_parser_spec.cr` (task.vars parses
    correctly, the vars-before-module-key ordering case, no leakage to a
    later task, defaults to empty). Permanent compat coverage in new
    `compat/playbooks/41-task-vars.yml`, covering `{{ }}`, bare
    when:/assert:, the ordering edge case, a filter chain on a
    task-level var, and non-leakage - diffed against real
    `ansible-playbook`. Full compat harness: **41/41 pass**. `crystal
    spec` (765 examples, same 2 pre-existing unrelated failures) and
    `ameba` (same pre-existing findings, zero new) both clean.

- [x] Replaced `JSON.parse(result.to_json).as_h` (used purely to get a
  mutable shallow copy of a `JSON::Any` hash) with `result.as_h.dup` at
  the four sites in `task_executor/executor.cr`
  (`apply_changed_failed_when`, the per-loop-item path, `register_result`)
  and `plugin_manager.cr` (`execute_remote_plugin`, which also dropped a
  redundant re-wrap into `JSON::Any.new` right after mutating the
  existing hash in place) (`0.9.66`), from an Opus performance-review
  pass (`OPUS_PERFORMANCE_IMPROVEMENTS.md`, item 5). All four sites only
  ever add top-level keys, so a shallow `.as_h.dup` is behaviorally
  identical to the round-trip through JSON serialization - confirmed safe
  by grepping for any nested mutation at each site (none). **Measured**
  (release build, `Benchmark.ips`, same harness the doc's methodology
  documents): `JSON.parse(r.to_json).as_h` vs. `r.as_h.dup` on an 8 KB
  `stdout` result - 29.5µs vs. 42ns (**711x**); on a small result -
  563ns vs. 41ns (**13.6x**). `crystal spec` (766 examples, same 2
  pre-existing DB-client failures) and `ameba` (177 files, same 51
  pre-existing findings, zero new) both clean. Full compat harness:
  **41/41 pass**.

- [x] Deleted unconditional debug `STDERR.puts` scaffolding that shipped
  live in `bin/crystal-ansible`, not gated behind any verbose flag
  (`0.9.67`), from `OPUS_PERFORMANCE_IMPROVEMENTS.md` item 8:
  `expression_evaluator.cr` (8 sites), `crinja_renderer.cr` (20 sites,
  including `prepare_crinja_vars` dumping every variable's value twice
  per `{% %}` render - the worst offender, and a vault-decrypted-value
  leak risk beyond the speed cost), `array_slicer.cr` (27 sites), and
  `template_action_plugin.cr` (2 sites, a swallowed-error backtrace with
  no caller depending on it - `base_plugin.cr:105`'s equivalent backtrace
  print was kept as-is; that one's genuinely diagnostic, this one wasn't
  read by anything). One redundant `begin`/`rescue` block left over once
  its only other content (the debug prints) was gone was also collapsed
  (`ameba`'s `Style/RedundantBegin` caught it immediately - back to the
  177/51 baseline once fixed). **Measured** (release build,
  `Benchmark.ips`, stderr redirected to `/dev/null` per the doc's own
  methodology - a real terminal/file is slower): `substitute()` on a
  120-var context went from 8.04µs to 4.34µs, **1.85x faster**.
  `crystal spec` (766 examples, same 2 pre-existing DB-client failures)
  and `ameba` (177 files, same 51 pre-existing findings) both clean.

- [x] Collapsed plugin pre-upload from `2N+1` SSH round trips per host to
  3 (`0.9.68`), from `OPUS_PERFORMANCE_IMPROVEMENTS.md` item 2:
  `PluginManager.upload_plugins_to_host` used to run one `ssh mkdir`,
  then one `ssh cat` per plugin to read its remote `.md5`, then one
  `ssh echo >` per uploaded plugin to write the new `.md5` back - all
  serial `ssh` process spawns. Rewritten to one `exec_script` that
  `mkdir -p`s the dir and dumps every existing remote `.md5` in a single
  pass (parsed locally into a `Hash(String, String)`), one rsync/scp
  transfer for whatever needs uploading, one `exec_script` that writes
  all the new `.md5` files. Also fixed in the same pass: local MD5 was
  computed twice per uploaded plugin (`Digest::MD5.hexdigest(File.read(...))`,
  loading the whole ~2.3 MB binary into memory each time) - now computed
  once per plugin via the streaming `Digest::MD5.new.file(path).hexfinal`,
  cached in a local hash reused for both the compare and the eventual
  write. **Verified against a real remote host** (two throwaway podman
  containers on an isolated network, one running its own `sshd`, matching
  this repo's existing batching-verification pattern in
  `compat/run.cr#run_playbook_via_ssh`): a 4-distinct-plugin cold upload
  (`file`/`copy`/`shell`/`lineinfile`) dropped from **10 SSH commands to
  3** (`SSHManager.stats["commands_executed"]`, same fresh-target state
  both directions), and a warm incremental re-run correctly uploaded 0
  files while still checking freshness in a single round trip. scp
  fallback re-verified by temporarily hiding `rsync` from `PATH` inside
  the test controller container - all 4 plugins still landed with the
  correct MD5 and mode `0755`. `crystal spec` (766 examples, same 2
  pre-existing DB-client failures) and `ameba` (177 files, same 51
  pre-existing findings) both clean. Full compat harness (local-
  connection only, so this path isn't exercised there, but nothing
  regressed): **41/41 pass**.

- [x] `rsync_upload_batch` now spawns one `rsync` process for a whole
  batch instead of one per file (`0.9.69`), from
  `OPUS_PERFORMANCE_IMPROVEMENTS.md` item 3: rsync accepts multiple
  sources for a single destination directory natively, so
  `local_files + ["user@host:remote_dir/"]` replaces the per-file loop
  that used to spawn a full `rsync` (and therefore a separate SSH
  session) per file. Also cached the `which rsync` availability check
  in a `@@rsync_available : Bool?` class variable, resolved once per
  process instead of once per call to either `rsync_upload` or
  `rsync_upload_batch`. **Verified against a real remote host** (same
  throwaway-podman-container setup as item 2's verification): a 4-file
  plugin batch upload dropped from **4 rsync process spawns to 1**
  (counted directly, both directions, against the same freshly-cleared
  target); all 4 files landed with the correct MD5 and mode `0755`
  either way. Re-verified the scp fallback separately by hiding `rsync`
  from `PATH` inside the test controller - all 4 files still landed
  correctly. `crystal spec` (766 examples, same 2 pre-existing DB-client
  failures) and `ameba` (177 files, same 51 pre-existing findings) both
  clean.

- [x] `LocalExecutor.exec` now spawns two processes per local command
  instead of three (`0.9.70`), from `OPUS_PERFORMANCE_IMPROVEMENTS.md`
  item 9: it used to build `"/bin/bash -c '#{command.gsub(...)}'"` and
  pass it to `Process.new` with `shell: true`, which spawns `sh` to
  parse that string, which then spawns `bash` to run the actual command
  - `sh` never does anything but re-invoke `bash`. Switched to
  `Process.new("/bin/bash", ["-c", command])`: no `shell: true`, so no
  intermediate `sh`, and the command travels as a single argv element
  instead of a string a shell has to re-parse, which also deletes the
  hand-rolled single-quote escaping entirely rather than just making it
  faster. **Measured** directly via `strace -f -e trace=execve`: 3
  `execve` calls before (`sh` -> `bash` -> command) vs. 2 after (`bash`
  -> command) for the same trivial command. Added a regression spec
  (`spec/unit/local_executor_spec.cr`) exercising embedded single
  quotes, a literal `$`, and a backslash together in one command,
  specifically because passing argv directly changes how those
  characters need to survive - confirmed they come through byte-exact
  with no shell re-interpretation. `crystal spec` (766 examples, same 2
  pre-existing DB-client failures) and `ameba` (177 files, same 51
  pre-existing findings) both clean.

- [x] Stopped building `vars_context` twice for every batched task
  (`0.9.71`), from `OPUS_PERFORMANCE_IMPROVEMENTS.md` item 7:
  `execute_batch_group` builds a `vars_context` for every group member to
  prepare its batch step; later, as the task-major loop in `execute_task`
  reaches each member, it built an identical context again before
  calling `try_batched_result`. Widened `@batch_cache`'s value type from
  `Hash(Task, JSON::Any?)` to `Hash(Task, {JSON::Any?, Hash(String,
  JSON::Any)})` so each cached result carries its vars_context alongside
  it - `execute_task` now checks the cache first and reuses that context
  instead of rebuilding, and the group's *triggering* task (the one
  whose `execute_task` call actually invokes `execute_batch_group`) has
  its already-built context threaded straight into
  `execute_batch_group` via new `trigger_task`/`trigger_vars_context`
  params, so that one specific member's context is now built exactly
  once instead of twice too. **Measured** (release build,
  `Benchmark.ips`, 120 facts + 20 host vars + 10 play vars, matching the
  doc's own harness): `VariableContext.build` + facts merge costs 3.86µs
  per call; building it twice (the pre-fix cost for a batched task) -
  7.72µs, so this is a clean **2.00x** reduction per batched task. This
  touches the batch path directly, so verified with the full `--no-
  batching` A/B protocol from `0.9.63`: full compat harness including
  `39-batching.yml`'s real-SSH controller/target diff - **41/41 pass**,
  batched and unbatched output byte-identical. `crystal spec` (766
  examples, same 2 pre-existing DB-client failures) and `ameba` (177
  files, same 51 pre-existing findings) both clean.

- [x] Collapsed the two adjacent `VarSubstitutor` instances in
  `apply_changed_failed_when` (`0.9.72`) into one shared instance for
  `changed_when:`/`failed_when:`, from `OPUS_PERFORMANCE_IMPROVEMENTS.md`
  item 6 - the minimal fix the doc calls out explicitly ("a two-line
  change with no signature churn, worth doing even if the [full 14-site]
  threading is deferred"). Both conditions evaluate against the
  identical `eval_context`, and `VarSubstitutor` is stateless with
  respect to a given vars hash - confirmed by grepping for
  `set_variable` (its only mutator) across `src/`: it's defined but never
  called anywhere, so sharing one instance between the two `if` blocks is
  safe. The full 14-call-site threading through
  `when_passes?`/`execute_task_once`/`resolve_delegate_host`/
  `apply_changed_failed_when` that the doc describes as the complete fix
  was deliberately not attempted in this pass - it needs signature
  changes across several methods and its own dedicated review, unlike
  this one. `crystal spec` (766 examples, same 2 pre-existing DB-client
  failures, including the `changed_when:`/`failed_when:` override smoke
  test in `cli_spec.cr` that exercises this exact path) and `ameba` (177
  files, same 51 pre-existing findings) both clean.

- [x] Four smaller allocation/complexity fixes from
  `OPUS_PERFORMANCE_IMPROVEMENTS.md` items 10-12 (`0.9.73`):
  - **`TaskBatcher.references_register?`** (item 10) recompiled
    `/\b#{Regex.escape(name)}\b/` inside a nested `seen.any? { …
    haystacks.any? … }` - O(tasks x registers) regex compilations while
    planning. `seen_registers` is now a `Hash(String, Regex)` compiled
    once when a name is added, not once per later task that has to check
    against it. **Measured** (release build, a synthetic 300-task run
    that never flushes, so the accumulated register set actually grows
    to stress the quadratic): **304.71ms before, 3.94ms after - 77x
    faster**, 15.1MB/op down to 166kB/op.
  - **`InventoryParser#get_hosts`** (item 10) recompiled `/^#{regex}$/`
    inside a `select` block, once per host in the inventory - Crystal
    only caches non-interpolated regex literals. Hoisted the compile
    above the `select`.
  - **`VarSubstitutor#substitute`** (item 11): replaced the loop of
    `result.match(pattern)` + `result.sub(...)` - which rescans the
    *substituted* result from index 0 every iteration, and would loop
    forever if a variable's own value happened to contain `{{` - with a
    single `gsub` pass. Grepped specs and compat playbooks for a nested
    `{{ {{` case first (per this item's own caveat): none exists, so
    nothing relies on the old recursive re-scan. **Measured**: a string
    with 80 `{{ }}` placeholders went from 217.77µs to 33.86µs (**6.4x**),
    180kB/op down to 23.2kB/op.
  - **`ConditionalEvaluator#split_by_operator`** (item 12):
    `condition[i..-1].starts_with?(operator)` allocated a substring of
    the *entire remaining condition* on every character, and `current +=
    char` reallocated the accumulator on every character - copied
    `FilterEngine.split_chain`'s shape (bounded per-char operator
    comparison with no allocation, `String::Builder` accumulator).
    **Measured**: a 60-clause `and` chain went from 32.11µs to 18.01µs
    (**1.78x**), 195kB/op down to 40.1kB/op.

  `crystal spec` (766 examples, same 2 pre-existing DB-client failures)
  and `ameba` (177 files, same 51 pre-existing findings) both clean. Full
  compat harness (exercises `when:`/`{{ }}`/inventory patterns
  extensively): **41/41 pass**.

- [x] Batched loop iterations into one shared SSH round trip (`0.9.74`),
  from `OPUS_PERFORMANCE_IMPROVEMENTS.md` item 1 - the doc's own
  "highest remote" item and the largest single change in this pass.
  `execute_looped_task` used to call `execute_task_once` once per item
  (a `loop:` over 20 items meant 20 sequential SSH round trips); it now
  evaluates each item's `when:` up front (safe - an item's `when:`
  depends only on `item` + the base context, both known before any
  remote call - unlike mixed-task batching, which needs the whole
  `references_register?` data-dependency analysis because task B may
  consume task A's `register:`; iterations of one task can't reference
  each other's results at all, so that analysis doesn't apply here),
  then feeds every surviving item through `prepare_batch_step` and runs
  them as a single `BatchScript` via the same `run_batch_script` helper
  `execute_batch_group` uses (factored out of it in this change, per the
  doc's own suggestion, since the two callers only differ in how they
  produce their step list). Bails out to the existing one-at-a-time path
  untouched when `@batching_enabled` is false, `exec_host != host`,
  `task.delegate_to` is set, the connection is local, or
  `task.changed_when`/`failed_when` is set (the script's fail-fast can't
  see a controller-side verdict override - same reasoning as
  `TaskBatcher#retroactive_verdict?`).
  - **Preserved the one genuinely tricky behavior difference on purpose**:
    today's one-at-a-time loop always runs every item even after an
    earlier one fails (no early stop), but `BatchScript`'s own fail-fast
    (built for the mixed-task case, where a failure really should halt
    the remaining tasks) would otherwise stop the *script* on the first
    failing item without `ignore_errors:`. Rather than let that leak
    through as a silent behavior change, every loop-batch `Step` is built
    with `ignore_errors: true` regardless of the task's own value,
    purely to suppress the script's internal halt - the real per-item
    `failed:` status still flows through untouched and drives
    `any_failed`/stats/halt exactly as before.
  - Refactored `execute_looped_task` into three pieces sharing one
    aggregation path: `loop_batch_eligible?` (the bail-out checks),
    `execute_looped_task_batched` (builds the shared script and runs it),
    and `finish_looped_task` (the register:/notify:/stats/halt
    bookkeeping, now identical for both the batched and one-at-a-time
    paths since both just produce an `Array(JSON::Any?)` of per-item
    results for it to consume).
  - **Verified against a real remote host** (two throwaway podman
    containers, same setup as items 2/3/7's own verification): a 10-item
    `loop:` dropped from **12 SSH commands to 3** (both directions
    against a freshly-cleared target), with byte-identical filesystem
    state either way. Separately verified the continue-after-failure
    behavior directly: a 5-item loop with one failing item (`item=c`,
    no `ignore_errors:`) ran **all 5 items batched, identical output to
    `--no-batching`** - `failed=1` recap, items a/b/d/e all still ran.
  - `crystal spec` (766 examples, same 2 pre-existing DB-client
    failures) and `ameba` (177 files, same 51 pre-existing findings)
    both clean. Full compat harness (including `39-batching.yml`'s
    real-SSH controller/target diff): **41/41 pass**.

- [x] Parallelized fact gathering across hosts (`0.9.75`) - Stage A of
  `OPUS_PERFORMANCE_IMPROVEMENTS.md` item 4 (no `--forks` anywhere in
  the codebase, verified by grep; wall-clock time was strictly linear in
  host count). `gather_facts_for_all_hosts` is fully independent per
  host - it only ever writes to `@facts[host.name]` and
  `@results[host.name]`, both pre-seeded per host in `#initialize`, so
  no concurrent hash resizing - so it now runs through a bounded pool of
  fibers (capped at `min(@hosts.size, 10)` via a `Channel(Nil)`-backed
  gate, to avoid opening an unbounded number of simultaneous SSH
  connections against a large inventory) instead of one host after
  another. Extracted the per-host work into `gather_facts_for_host`,
  returning `{success?, error_message}` rather than printing/updating
  stats itself, so the caller can join every fiber first and then print
  in deterministic `@hosts` order - interleaved completions never
  scramble the display. **Per this doc's own explicit staging
  instruction, only Stage A landed in this pass** - parallelizing the
  per-task host loop itself (Stage B, a `-f/--forks` flag) touches
  `@results`/`@registered_vars`/`@facts`/`@batch_cache`/`@halted_hosts`/
  output-ordering/`@handler_runner`/`@task_group` and is explicitly
  scoped as its own follow-up design review below, not attempted here.
  **Verified against a real remote host** (5 throwaway podman containers
  on an isolated network, one controller + 5 targets, same setup as
  every other real-SSH verification in this pass): median wall-clock
  for `gather_facts` against all 5 hosts went from **~360ms (serial,
  5 runs: 358/362/361/361/360ms) to ~256ms (parallel, 5 runs:
  257/255/255/255/256ms) - a consistent 1.41x**, with facts confirmed
  correct per host (each host's `ansible_hostname` fact resolved to its
  own hostname, no cross-host contamination from the parallel gather).
  `crystal spec` (766 examples, same 2 pre-existing DB-client failures)
  and `ameba` (177 files, same 51 pre-existing findings) both clean.
  Full compat harness (local-connection only, so parallelism isn't
  exercised there, but nothing regressed): **41/41 pass**.

- [x] Deleted three dead code trees identified in
  `OPUS_PERFORMANCE_IMPROVEMENTS.md` as unreachable from
  `crystal-play.cr` (verified by walking `require` edges from the entry
  point, and by grepping `spec/` for any reference before deleting)
  (`0.9.76`): `src/crystal_play.cr` (289 lines, a stale pre-batching/
  pre-vault CLI duplicate with no `--forks`/exit-code handling and a
  leftover `STDERR.puts "DEBUG: ..."` in its host loop),
  `src/crystal_play/facts_gatherer/` (11 files, ~600 lines, superseded
  by `plugins/facts.cr` - worth deleting specifically because it still
  contained the 34-shell-out implementation `0.9.61` replaced with
  syscalls, which invited editing the wrong file), and
  `src/crystal_play/ssh_config.cr` (174 lines). A compile-time/
  maintenance concern, not a runtime one, and landed in its own commit
  separate from any behavioral change. `crystal spec` (766 examples,
  same 2 pre-existing DB-client failures) and `ameba` (**165 files**, 51
  pre-existing findings - the file count drop reflects the 12 deleted
  files, not a lint regression) both clean.

- [x] Added `-f/--forks N`: runs each task against up to `N` hosts
  concurrently instead of one at a time (`0.9.77`) - Stage B of
  `OPUS_PERFORMANCE_IMPROVEMENTS.md` item 4, deliberately deferred at
  `0.9.75` (Stage A, parallel fact gathering) pending its own design
  review, per the doc's own explicit instruction. That review considered
  Crystal 1.21.0's new `Fiber::ExecutionContext::Parallel` (real
  OS-thread parallelism, this environment runs 1.20.3 but 1.21.0 was
  pulled and checked directly) and **rejected it**: real threads would
  require wrapping every shared mutation this fan-out touches
  (`@results`, `@registered_vars`, `@facts`, `@batch_cache`,
  `@halted_hosts`, all stdout writes) in explicit `Sync::Mutex` sections,
  plus bumping the project's Crystal requirement everywhere - a much
  bigger, riskier change for a tool whose actual bottleneck is SSH
  round-trip network wait, not CPU work (confirmed by Stage A's own
  1.41x result using only cooperative fibers). The default execution
  context has parallelism 1 in both 1.20.3 and 1.21.0, so this feature
  needs **no Crystal version bump** at all - it's plain `spawn` +
  `Channel`, the exact same primitive Stage A already used.
  - **Safety argument** (why no mutexes are needed): under cooperative
    fibers, only one fiber ever executes Crystal code at any instant -
    the scheduler only switches at explicit yield points (I/O wait,
    `Channel#send`/`#receive`). Every structure this fan-out touches is a
    `Hash` pre-seeded with every host's key in `#initialize`, and each
    host's fiber only ever writes its *own* key - disjoint keys, no
    resize, safe. `@halted_hosts` is a `Set`, and `Set#add` has no yield
    point mid-operation, so it's cooperatively serialized rather than
    racy even though multiple hosts can add themselves within one task.
    `HandlerRunner#notify` already writes to a per-host `Set` with no
    ordering dependency on notify-call order (confirmed by reading
    `handler_runner.cr` - `run` walks handlers in *definition* order and
    hosts in `@hosts` order) - no change needed there at all.
  - **The one real hazard, stdout interleaving**, was solved without the
    huge refactor threading an `io:` param through every display method
    would have required: `puts`/`print` (44 bare calls across
    `executor.cr`/`result_display.cr`/`handler_runner.cr`, all routing
    through `Kernel#puts` → `STDOUT.puts`) are redefined at the top level
    in new `src/crystal_play/task_executor/output_routing.cr` to route
    through a `Hash(Fiber, IO)` lookup first, falling back to the real
    `STDOUT` for any fiber with no redirect registered - legal in Crystal
    (top-level method definitions simply shadow the stdlib's for the
    whole program) and safe for the same reason as above (no lock needed
    on that lookup either). Each host's fiber in
    `run_task_for_hosts_in_parallel` redirects to a private `IO::Memory`,
    and every buffer is flushed in `hosts` order only after every fiber
    has joined, so output stays stable regardless of which host's SSH
    round trip actually finished first.
  - **Explicitly excluded from forking** (falls back to today's serial,
    one-host-at-a-time path via new `task_forkable?`): `run_once:` tasks
    (needs `@hosts.first` to have *actually finished* before other hosts
    can copy its register via `copy_run_once_register` - a real ordering
    dependency, not just a data-race concern, and the trickiest case the
    original doc flagged) and `block?`/`include_tasks?`/`include_role?`
    (structural/dynamic tasks that recurse into their own nested task
    lists and `ensure_grouped` calls - kept serial to sidestep any
    question of concurrent re-entrancy into the batching planner).
  - **Verified against 4 real remote hosts** (throwaway podman
    containers, same methodology as items 1/2/3/4A): a mixed 6-task
    playbook (`file`/`copy`/`lineinfile`/`shell`+`register`/`debug`/
    `file`) went from a median **~1580ms (`--forks 1`) to ~1235ms
    (`--forks 4`) across 5 runs each - a consistent **~1.28x**, with
    full stdout **byte-identical** between the two runs (host status
    lines never interleaved) and filesystem state on every target
    diffed identical. A separate `run_once:` playbook run under
    `--forks 4` confirmed it still only executes on the first host
    while every host still sees its register.
  - New integration coverage in `spec/integration/cli_spec.cr` (against
    `spec/fixtures/inventory-multi-local.ini`'s two `ansible_connection=
    local` hosts, the same "exercise multi-host behavior without a real
    second machine" trick `run_once:`'s own existing spec already used):
    one spec confirms `--forks 1` produces byte-identical output to the
    default, another confirms `--forks N` runs every host, still excludes
    `run_once:` from the fan-out, keeps registers visible across tasks,
    and never interleaves host output.
  - `crystal spec` (**769 examples**, same 2 pre-existing DB-client
    failures) and `ameba` (**166 files** - the one new `output_routing.cr`
    - same 51 pre-existing findings) both clean. Full compat harness
    (`--forks` defaults to 1, so unaffected, but the `puts`/`print`
    redefinition is a process-wide primitive change worth re-confirming
    against): **41/41 pass**.

- [x] Flipped `--forks`'s default from `1` to `5` (`0.9.78`), matching
  real `ansible-playbook`'s own default. A deliberate policy call, not
  a technical finding: `0.9.77`'s own entry above argued for shipping
  dark first (same discipline batching followed via
  `--experimental-batching` before its `0.9.63` default flip), but this
  is a much smaller user base at this stage than the batching decision
  weighed against, so the calculus is different - flip now, keep
  testing. `--forks 1` still restores the original one-host-at-a-time
  behavior for anyone who wants it. Verified against a real 2-host
  local-connection fixture (`--forks` with no flag now genuinely fans
  out, `run_once:` still correctly excluded from it) and the full
  `crystal spec` (769 examples, same 2 pre-existing DB-client failures
  plus one now-flaky Docker-daemon-connectivity spec in this specific
  sandbox environment, confirmed via `git stash` to already fail before
  this change too - unrelated) / `ameba` (166 files, same 51
  pre-existing findings) / compat harness (41/41) suite.

- [x] Landed 12 of 14 items from a fresh performance review, plus
  `--gathering` (`0.9.79`). Measured on 3 fresh Atlantic.net instances
  (Ubuntu 22.04, G3.1GB, `USEAST2`, destroyed after), `0.9.78` vs
  `0.9.79` run **interleaved** to cancel network jitter, median of 5,
  `--forks 3`: cold run (plugins re-uploaded) **16.39s -> 10.13s
  (1.62x)**, warm run **3.09s -> 2.45s (1.26x)**.
  - Tier 1, the pre-execution phase `0.9.75`/`0.9.77` never touched:
    plugin pre-upload now runs concurrently across hosts through the
    same bounded-fiber `Channel` gate the other two use (it ran *before*
    both of them and was still serial, one SSH round trip per host even
    on a fully warm run), and each plugin binary is MD5'd once per run
    instead of once per host - digesting the 44 binaries costs ~127ms, so
    20 hosts burned ~2.5s of pure duplication before the first task.
  - Fact gathering now honors `--forks`; the hardcoded `10` predated the
    flag. **This made `--forks 1` slower** (8.29s -> 9.92s on 3 hosts) -
    it now means one host at a time end to end, which is the flag working
    correctly but is a real regression for anyone who used `--forks 1`
    for throughput rather than for debugging.
  - Tier 2: the solo remote path serialized the config, parsed it back,
    then duped and re-serialized it purely to inject one key
    (32.26us/45.7kB -> 7.90us/15.8kB per task per host); one process-wide
    Crinja environment instead of one per `{% %}` render, its config
    being two invariant literals (21.08us/61.9kB -> 9.28us/32.2kB); and
    `@batch_cache` entries are now evicted as consumed, having previously
    retained a full variable-context copy per task per host for the whole
    play.
  - Batch-cache eviction needed a separate `@batch_groups_run` marker:
    the old trigger check read the cache's own contents, so evicting
    `group.first` would have made a later group member re-run the entire
    remote script and re-execute real side effects.
  - `--gathering implicit|explicit|smart` + `meta: clear_facts`, matching
    `ansible-playbook` rather than inventing semantics - verified against
    `ansible-core` 2.19.4 running the same playbooks side by side, with
    gather counts and recap `ok=` totals matching in all seven scenarios
    tested (including that `smart` deliberately skips a play's *explicit*
    `gather_facts: true`, which this codebase already did). Default stays
    `implicit`. `smart` alone: **2.10s -> 1.54s (1.36x)** on a 4-play
    playbook, 2.75s -> 1.56s (1.76x) on eight, since it removes
    `(N_plays - 1) x N_hosts` round trips. `meta: clear_facts` is the
    escape hatch that makes `smart` safe; without it a reboot or package
    install in an early play would silently feed stale facts to every
    later play with no way to refresh. Unsupported `meta:` actions fail
    at parse time rather than silently doing nothing.
  - Also fixed `version.cr`, which had drifted 13 releases behind
    `shard.yml` (`0.9.65` vs `0.9.78`) and was printing the wrong version
    in `--version` and the startup banner.

- [x] Shared one `VarSubstitutor` per `(task, host)` and removed the last
  `JSON.parse(x.to_json)` round trip (`0.9.80`). Measured by counting
  constructions at runtime rather than guessing: a `when:`-heavy playbook
  against 3 real hosts went **93 -> 48 (-48.3%)**, batched and
  `--no-batching` alike. **Wall clock did not move** (1.79s -> 1.78s,
  inside noise) and was not expected to - at ~1.1us per construction this
  is allocation pressure, not latency.
  - Two findings worth keeping: the win only exists where two
    substitutors were built over the *same* context (a task with `when:`,
    a `delegate_to:`, or the batch path) - a plain task without `when:`
    always built exactly one, because `when_passes?` returns before
    constructing when there is no condition. And building the shared
    instance *eagerly* at the top of `execute_task` is a **regression**,
    not an optimization: the loop and `until:` paths return before
    reaching `execute_task_once` and build their own per item, so an
    eager instance is pure waste - measured at -34.8% (23 -> 31
    constructions) before being corrected to build it only where used.
  - `apply_changed_failed_when` still builds its own and must: it
    evaluates against a different context, with the task's own result
    injected under its `register:` name.

- [x] Shared the `JSON::Any -> Crinja::Value` converter (`0.9.81`).
  `TemplateActionPlugin` carried a byte-identical copy of
  `CrinjaRenderer`'s. Deliberately *not* shared: the Crinja environment
  itself - that plugin's `trim_blocks`/`lstrip_blocks` come from the
  task's own `template:` params, so its config genuinely varies per task,
  precisely the invariance the process-wide environment relies on. A
  duplication fix, not a performance one; no measurement is quoted.
  Verified with coverage the repo did not previously have: **no
  `compat/` or `testing/` playbook exercises `trim_blocks`/
  `lstrip_blocks` at all**, so a fixture was written rendering the same
  template under all four combinations of the two flags plus every branch
  of the converter - byte-identical before and after, with 3 of the 4
  combinations producing genuinely distinct output, confirming the params
  really do reach the environment.

- [x] **Fixed the last cross-cutting engine gap this roadmap tracked**
  (`0.9.82`): magic variables were invisible to *bare* conditions. This
  turned out to be three bugs, not one - checked against `ansible-core`
  2.19.4 with an inventory where all three values differ
  (`web1 ansible_host=192.0.2.55`, real hostname `floridian-goat`):

  | | ansible | crystal (before) |
  |---|---|---|
  | `inventory_hostname` | `web1` | `web1` |
  | `ansible_host` | `192.0.2.55` | `web1` (clobbered) |
  | `ansible_hostname` | `floridian-goat` | `web1` (clobbered) |
  | bare `when: inventory_hostname == "web1"` | runs | **skipped** |

  - The reported gap: bare `when:`/`assert: that:`/`until:`/
    `changed_when:`/`failed_when:` are evaluated directly against the
    `vars_context` `TaskExecutor` builds, which never had the magic
    variables added - only the `{{ }}` path, via `VarSubstitutor`'s own
    copy, did. `when:` therefore *skipped silently*, the worst shape for
    this bug. Fixed by adding them in `build_vars_context`, which also
    fixes `assert:`'s `that:` (evaluated inside the plugin, against the
    `vars` this context is serialized into).
  - Fixing it exposed the other two: `VarSubstitutor` overwrote
    `ansible_host` and `ansible_hostname` with the inventory name. Both
    are now fallbacks applied only when absent, so an inventory's
    `ansible_host` and a gathered `ansible_hostname` fact win - matching
    ansible-core. Only `inventory_hostname` stays unconditional. Had the
    clobbering been left in place, bare conditions would simply have
    inherited the wrong values.
  - `ansible_host` also feeds `PluginManager#get_connection_host`, so
    this was verified against 3 real hosts with an inventory whose names
    differ from their addresses (`alpha ansible_host=69.87.217.114`):
    routing is **unchanged** before vs after (each name still reached its
    own machine, confirmed via `hostname -I` on the target), and the
    reported values now match `ansible-playbook` byte for byte on the
    same inventory.
  - Note for anyone re-testing: `when: inventory_hostname != "x"` does
    *not* reproduce the original bug - with the magic variable missing
    the comparison was against an empty value, so `!=` passed by
    accident. The `== "web1"` form is the discriminating one.

- [x] `postgresql_privs`: `type: function` / `type: procedure`, including
  `ALL_IN_SCHEMA` for both (`0.9.83`). Verified against a live PostgreSQL
  16 server and, for the same playbook, against real `ansible-playbook`
  with `community.postgresql` 4.2.0 - identical `changed` flags *and*
  identical resulting `pg_proc` ACLs.
  - Routines are identified by *signature*, not name, because PostgreSQL
    allows overloading. Rather than hand-parsing `name(arg_types)` in
    Crystal - which would have to cope with `character varying`, `int[]`
    and `public.mytype` - the reference is **bound as a parameter and
    cast to `regprocedure`**, so PostgreSQL's own parser resolves it and
    `format_type(proargtypes)` renders the canonical form back. That
    removes the injection surface entirely (nothing user-supplied is
    interpolated) and makes overload resolution and type aliasing exactly
    PostgreSQL's: `f(int)` and `f(integer)` name the same function, as in
    psql.
  - Two details found by reading real Ansible's module rather than
    assuming, both of which would have shipped wrong otherwise:
    **argument types are separated with colons, not commas**
    (`objs: "f(int:text)"`), because `objs:` is itself comma-separated -
    without that convention `f(int, text)` splits into the two nonsense
    objects `f(int` and `text)`; and a **bare name is an error**, not
    something to resolve heuristically ("Illegal function / procedure
    signature", the same message real Ansible raises).
  - `pg_get_function_identity_arguments` is deliberately *not* used to
    build the signature even though it looks like the obvious choice: it
    includes argument names and modes (`f1(a integer)`, `p1(IN a
    integer)`), which `GRANT` accepts but `regprocedure` input rejects
    with "syntax error at or near \"integer\"" when the same string is
    later used to look the ACL back up. `proargtypes` + `format_type`
    yields `f1(integer)`, valid for both.
  - A procedure addressed as a function (or vice versa) is rejected with
    a clear message rather than PostgreSQL's confusing syntax error -
    `prokind` is checked after resolution.
  - `compat/playbooks/38-postgresql-privs.yml` gained routine coverage:
    one overload of an overloaded function granted while the other is
    left untouched (the case a bare name could never express), a
    multi-argument colon-separated signature, a procedure, a revoke, and
    `ALL_IN_SCHEMA` over routines - with the resulting `pg_proc` ACLs
    read back and diffed, so the harness compares real privilege state
    rather than just `changed` flags.
  - Also of note for anyone running the suite: **the MySQL and PostgreSQL
    integration specs are not actually broken** - they need a live server
    and client binaries, neither of which is installed by default. Both
    are obtainable in a couple of minutes from the official container
    images, after which `crystal spec` is **793 examples, 0 failures**.

- [x] `postgresql_privs`: `type: default_privs` and `target_roles:`
  (`0.9.84`) - **the last `postgresql_privs` gap; every `type:` real
  Ansible supports is now implemented.** Verified against a live
  PostgreSQL 16 server and side by side with real `ansible-playbook`
  (`community.postgresql` 4.2.0): identical `changed` flags across seven
  cases (grant, idempotent repeat, widening privileges over two classes,
  `target_roles:`, `ALL_DEFAULT`, revoke, revoke again) *and* identical
  resulting `pg_default_acl`.
  - `default_privs` is a genuinely different mechanism, not another
    object type: it controls what privileges objects will receive *when
    created in future*, stored in `pg_default_acl` rather than on any
    existing object, so none of the `fetch_acl`/`qualified_object`/
    `apply_grants` machinery applies. `objs:` also changes meaning - an
    object *class* (`TABLES`/`SEQUENCES`/`FUNCTIONS`/`TYPES`/`SCHEMAS`),
    not object names.
  - **Idempotency deliberately differs in mechanism while matching in
    result.** Real Ansible executes its statements unconditionally and
    reports `changed` by diffing `pg_default_acl` before and after -
    which cannot support check mode, since it would have to make the
    change to find out. Here the current `defaclacl` is read and compared
    against the desired state first, so `--check` works and nothing runs
    when nothing needs changing. `state: present` stays declarative
    either way: it emits the same REVOKE ALL + GRANT pair, so afterwards
    the grantee holds exactly `privs:`, not the union with what was there
    before.
  - Quirks matched rather than "fixed", because parity is the point:
    `ALL_DEFAULT` expands to TABLES/SEQUENCES/FUNCTIONS/TYPES but
    deliberately *not* SCHEMAS (real Ansible pops it from that set), and
    `state: absent` revokes across TABLES/FUNCTIONS/SEQUENCES/TYPES
    regardless of what `objs:` said (its `build_absent` ignores `objs`
    entirely for this type).
  - `objs: SCHEMAS` is effectively unusable, on both engines: PostgreSQL
    rejects `IN SCHEMA ... ON SCHEMAS` ("cannot use IN SCHEMA clause when
    using GRANT/REVOKE ON SCHEMAS") and `schema:` defaults to `public`.
    Confirmed real Ansible fails with the identical server error, so this
    is upstream behavior being matched, not a gap - and it is why the
    compat playbook does not cover that class.
  - With no `target_roles:`, ALTER DEFAULT PRIVILEGES applies to the role
    executing it, which is what `pg_default_acl.defaclrole` records - so
    that is what the idempotency check resolves and compares against,
    rather than assuming the login user.
  - `compat/playbooks/38-postgresql-privs.yml` covers all of the above,
    and creates a table *after* the grant so the ACL it inherits proves
    the default privileges actually took effect rather than merely being
    recorded in the catalog.

**Real-host benchmark round: linux-system-roles (`0.9.158`-`0.9.171`).**
Same real-host-benchmark methodology as the dev-sec/konstruktoid rounds
this section was originally built around - two fresh Atlantic.net Ubuntu
22.04 hosts (one per engine), running actual roles from the officially
Red Hat/Fedora-maintained `linux-system-roles` collection
(`journald`/`logging`/`timesync`/`kernel_settings`, each much smaller and
more focused than dev-sec's `os_hardening`), diffing crystal-ansible's
run against real `ansible-playbook`'s. Found and fixed **19 real bugs**,
almost all in the plain `{{ }}` expression evaluator - this role family
leans much harder on `d()`/ternary/dict-literal Jinja idioms and
`lookup('first_found', ...)` for OS-version vars files than the earlier
rounds did:

- [x] `include_tasks:`/`import_tasks:` doubled `tasks/tasks/x.yml` when a
  file already inside `<role>/tasks/` includes a sibling by its full
  `tasks/foo.yml`-relative spelling (`0.9.158`) - real Ansible searches
  multiple roots including the role root itself; added a strip-leading-
  `tasks/` fallback in `PlaybookParser.resolve_include_path`, used by
  both `try_parse_import_tasks` and `run_include_tasks_once`.
- [x] `package:`'s `name:` parameter mishandled multi-package lists two
  separate ways, found in two different rounds of this same benchmark
  (`0.9.158`, `0.9.168`): a templated list var renders as JSON-bracket
  text (`["a","b"]`) that was sent to `apt-get`/`dpkg`/`rpm` unparsed
  until space-joined; a *literal* YAML list value is stringified comma-
  joined by `playbook_parser.cr` ("the format every other plugin's list
  params expect") but needed space-joining too. Separately, the
  installed-check used *one* combined `dpkg -l`/`rpm -q` call across all
  named packages, true the moment *any one* matched - masked a
  genuinely-missing package (`tuned`) behind an already-installed one
  (`python3-configobj`); fixed with a per-package `all_packages_
  installed?` helper shared between `handle_apt`/`handle_dnf`.
- [x] `ternary()` and `difference()` Jinja filters were entirely
  unimplemented in the plain evaluator (`0.9.158`, `0.9.160`) - only
  Crinja's separate template-file pipeline had them, the same "two
  independent evaluator implementations disagree" root cause behind
  several bugs in earlier rounds too.
- [x] **Handlers had zero `loop:`/`with_*:` support at all** (`0.9.159`)
  - a notified handler ran its module exactly once regardless of a
  `loop:` keyword, leaving `item` undefined. Extracted the single-
  execution body into `execute_handler_plugin_once`, added
  `execute_handler_loop` mirroring how a looped regular task already
  resolves its loop source and binds `item`/`loop_var` per iteration,
  with a new `already_displayed` result marker so `HandlerRunner#run`
  records stats without printing a second, redundant summary line.
- [x] `ansible_machine_id` fact was never gathered at all (`0.9.161`) -
  found via a `difference()`-based required-facts guard (`when:
  required_facts | difference(ansible_facts.keys() | list) | length >
  0`) that could never see all required facts as gathered, so a should-
  be-skipped re-gather `setup:` task ran on every play. Reads
  `/etc/machine-id`, falling back to `/var/lib/dbus/machine-id`, matching
  real Ansible's own fallback order.
- [x] Block-level `vars:` was never parsed at all (`0.9.162`) -
  `parse_block_task` set `when_condition`/`ignore_errors`/`become`/`tags`
  but never read `task_hash["vars"]`, so a block-scoped helper var
  computed for a nested task's `when:` was silently invisible even
  though `TaskExecutor#propagate_role_context` already had the merge
  logic to push it down - it just always saw an empty hash. The
  identical gap existed separately in `parse_include_vars_task`, found
  later via the `lookup()` work below (`0.9.166`) - same missing-vars-
  parsing bug pattern in two different parse functions.
- [x] `role_path` magic variable (the currently-executing role's own
  root directory) was never set anywhere (`0.9.163`) - `include_role:
  name: "{{ role_path }}/roles/rsyslog"` (a role referencing its own
  private subrole, a real pattern this collection uses repeatedly)
  rendered `"undefined/roles/rsyslog"` and failed to load. `RoleLoader.
  load_role` already computes the exact absolute path needed
  (`role_dir`); stored on `Task#role_path`, propagated through blocks/
  includes the same way `role_files_dir`/`role_vars_dir` already are,
  and exposed as the `role_path` vars_context entry.
- [x] **A genuine stack overflow**, not just a wrong answer (`0.9.163`):
  `has_comparison?` did a naive substring search for `<`/`>`/`==`
  instead of depth-aware scanning, so a `>` nested inside a ternary's
  own condition (`a + (b if (x > 0) else []) + (c | flatten)`) routed
  the *entire* plus-expression into `ComparisonEvaluator`, which split
  on the nested operator with its own naive text split, producing an
  operand with an unbalanced trailing `)`. Fed back into the evaluator,
  every depth-tracking scanner downstream (`split_top_level_plus`,
  `FilterEngine.split_chain`) could never find its target at depth 0
  again and fell back to "re-evaluate the same unchanged string" -
  forever. Fixed by making `has_comparison?` (and a new `top_level_
  pipe?`) properly depth/quote-aware, matching the existing style of
  `top_level_keyword_index` and the `+`/`-` splitters. Same commit also
  fixed a related, standalone bug: a literal array (`[]`, `['x']`) used
  outside a `+` operand (e.g. a ternary branch) fell through to indexed-
  access and always resolved `"undefined"`.
- [x] `return X rescue Y` is **not** `return (X rescue Y)` in Crystal - a
  real language-parsing gotcha, not a logic bug (`0.9.163`). The rescue
  modifier attaches to the whole `return X` *statement*; if `X` raises,
  the exception is caught but `return` never completed and `Y`'s value
  is simply discarded, falling through to whatever comes after the
  enclosing `if`. `resolve_plus_operand`'s `return JSON.parse(rendered)
  rescue JSON::Any.new(rendered)` silently dropped every `+` operand
  whose rendered text wasn't valid JSON (a bare word like
  `"local-modules"`) instead of falling back to it as a string,
  collapsing an entire `+` chain to just its other operands. Fixed by
  parenthesizing: `return (JSON.parse(rendered) rescue
  JSON::Any.new(rendered))`. Worth grepping for `return .* rescue ` again
  in any future audit - only this one instance existed this time, but
  it's a general enough Crystal footgun to re-check.
- [x] **`d(...)`, Jinja2/Ansible's extremely common shorthand for
  `default(...)`, was never recognized as a filter name at all**
  (`0.9.163`) - 268 combined occurrences in just two of these roles.
  Every `d(...)` call silently passed its input through unchanged
  instead of substituting the default, masked whenever the input
  happened to already be defined (the common case). Also fixed in the
  same commit: `resolve_default_arg` (the `default`/`d` filter's own
  argument resolver) had no concept of a top-level `+`/`-` chain of
  parenthesized sub-expressions in its argument at all (only a bare
  ternary or filter chain) - added a fallback to the full
  `ExpressionEvaluator` when a top-level `+`/`-` is detected in the
  argument text.
- [x] `include_role:`/`include_vars:` `vars:` were never rendered/parsed
  before reaching the sub-scope (`0.9.165`, `0.9.166`) - `include_role:`
  passed its `vars:` dict through to `RoleLoader.load_single_role`
  completely unrendered (a templated value like `rsyslog_custom_config_
  files: "{{ a + b }}"` landed as the literal `"{{ ... }}"` text, a
  non-empty "defined" string instead of the empty list it should have
  rendered to - fed a `loop:` that should have been skipped, producing
  one bogus iteration); `include_vars:`'s own `vars:` keyword (used to
  pass parameters like `ffparams` into a `lookup('first_found',
  ffparams)` expression) was never parsed into `task.vars` at all, the
  same class of gap as the block-vars fix above.
- [x] `lookup('first_found', params)` - real Ansible's lookup-plugin
  function-call syntax, distinct from a `|` filter chain - had zero
  support (`0.9.166`). Added the specific `first_found` case (searches
  `files:` under `paths:` on the *controller's* filesystem, in order,
  re-rendering each entry since they arrive at this evaluator still
  carrying their own unrendered `{{ }}` markers - they came from a task's
  `vars:` dict, past the point where `VarSubstitutor#substitute`'s own
  mustache-span extraction would have rendered them).
  - Fixing this and the `d()`/dict-literal work together surfaced a
    require-graph gap: `variable_lookup.cr`/`filter_engine.cr` started
    referencing `ExpressionEvaluator`/`OMIT_SENTINEL` directly but never
    required the files defining them - invisible for the main
    `crystal-play.cr` binary (which happens to pull in every
    `variable_substitutor/*` file via the `variable_substitutor.cr`
    aggregator regardless of require order) but broke standalone plugin
    builds (`debug.cr`, `assert.cr`) with "undefined constant". **Worth
    remembering for future evaluator changes**: `crystal build
    crystal-play.cr` succeeding is not sufficient proof a
    `variable_substitutor/*` change is safe - spot-check `crystal build
    plugins/<touched-family>.cr` too, since each plugin is its own
    independent compilation unit with its own require graph.
- [x] `selectattr(..., 'sameas', true/false)` fell to the unknown-test
  default (`!attr_value.nil?`, i.e. "is defined") - (`0.9.167`) every
  defined value matched both `sameas(true)` and `sameas(false)`
  regardless of actual type, so an ordinary integer sysctl value tripped
  a boolean-value guard's `fail:` unconditionally. Also fixed in the
  same commit: bare `true`/`false` literals in filter-test arguments
  resolved to the *string* `"true"`/`"false"` via the variable-lookup
  fallback, not a real JSON boolean - needed for `sameas` to ever compare
  unequal to a same-valued non-boolean.
- [x] **Crinja (the real-Jinja2-template-file engine) has no Python dict
  `.keys()`/`.values()`/`.items()` method support at all** (`0.9.169`) -
  a plain `Hash` doesn't implement the `crinja_attribute`/`crinja_call`
  interface Crinja's own method dispatch requires (only the vendored
  library's own custom types, like its `Cycler`, do). Fixed by reopening
  `Hash(K, V)` (from crystal-play's own code, not by patching the
  vendored shard) to implement `crinja_call` for these three method
  names - covers every Hash-valued template variable this engine ever
  hands to Crinja, not just the one role's template that surfaced it. A
  reasonable, low-risk pattern worth reaching for again before assuming
  a Crinja gap needs a vendored-library patch.
- [x] A bare `{{ {key: value} }}` dict literal - especially with a
  *dynamic* (expression) key, `{item.name: new_value}` - had no handling
  anywhere in the plain evaluator's main dispatch (`0.9.170`). Only
  `FilterEngine`'s own `parse_dict_literal` covered `{...}`, and only as
  a filter *argument* (`combine({...})`), where it also treats the key
  as literal already-final text rather than an expression - wrong for a
  dynamic key. A bare dict literal fell through to the `.`-nested-access
  check (dict literals routinely contain a `.` in a dynamic key
  expression) and got treated as a dotted variable path off the literal
  brace text, always undefined. Added `evaluate_dict_literal`, resolving
  both key and value as full expressions via `resolve_plus_operand`.
- [x] **Task-level `vars:` referencing `item` inside a `loop:` were
  rendered exactly once**, by `build_vars_context`, *before* the loop
  even started (`0.9.171`) - at that point `item` was unbound, and every
  iteration then reused that same first (wrong) rendered value instead
  of recomputing it per item. A dict-accumulation pattern (`vars:
  {new_item: "{{ {item.name: new_value} }}"}` feeding a looped
  `set_fact: acc: "{{ acc | combine(new_item) }}"`) lost every entry
  this way. Fixed in `execute_looped_task`'s one-at-a-time branch:
  restore `task.vars`' original unrendered text into that iteration's
  `vars_context` (it had been overwritten with the stale rendered value
  from the eager pass) and call `render_task_vars` again, now with
  `item` correctly bound. Not yet checked against the *batched* loop
  path (`execute_looped_task_batched`) - `set_fact:` is already excluded
  from batching entirely by a pre-existing, unrelated guard, so every
  case this round actually hit used the one-at-a-time path; a future
  round hitting this same pattern on a batchable module+loop+item-
  referencing-vars: combination should check that path too.

Timesync and kernel_settings both stopped short of a fully clean recap
match against real Ansible, but for a reason outside this engine's
scope, not a bug: both roles depend on **role-private custom Python
modules** (`timesync_provider.sh`, `kernel_settings_get_config.py`) that
this engine correctly and gracefully skips ("Plugin not available")
rather than crashing, since there is no generic arbitrary-third-party-
module runner - anything downstream that depends on the skipped task's
result then diverges from real Ansible too. `network` and `storage` (two
more roles cloned for this round) were tried and abandoned for similar
reasons before any real bug-hunting could start: `network`'s own python
baseline fails on this Ubuntu test host trying to install `network-
scripts` (a RHEL-only package name); `storage` defaults to
`storage_provider: "blivet"`, a heavy custom-Python-module dependency for
real LVM/filesystem management. Neither is a crystal-ansible defect to
chase - see the new "Role-private custom modules" bullet in the README's
Limitations section.

825 specs, 0 failures throughout every one of the 19 fixes above.

**Per-plugin scope cuts - the incremental parity list this section has
been working through is now empty:**

- `postgresql_privs`: **nothing open** as of `0.9.84` - every `type:`
  real Ansible's module supports is implemented, including
  `default_privs` and `target_roles:`.
- `docker_*`: `api_version:` - **deliberately not planned.** This
  codebase's `docr`-based API calls carry no version prefix on any
  endpoint URL at all, on a local socket either, so supporting it means
  touching every endpoint across the separate `docr` shard rather than
  just connection setup. That is a meaningfully bigger change than
  anything else closed in this section, for a parameter that only
  matters when pinning against an old daemon - the unversioned URLs
  already negotiate fine against current Docker and Podman. Revisit only
  if a real playbook actually needs the pin.
- `meta:`: only `clear_facts` is implemented (`0.9.79`).
  `end_play`/`flush_handlers`/`refresh_inventory`/`clear_host_errors`
  act on execution-flow machinery this engine models differently, and
  are rejected at parse time rather than silently ignored.
Cross-cutting engine gaps this section used to track here - Jinja2
filter-chaining (inside `{{ }}` substitution), `become:`/
`become_user:` privilege escalation, filter chains inside bare
when:/assert: that: conditions (or combined with a comparison in the
same `{{ }}` expression), a failed host not being excluded from
every remaining play in the run, and magic variables not reaching bare
conditions - are **all now fixed**; see the `0.9.42`, `0.9.41`, `0.9.64`
and `0.9.82` entries. **No *known* cross-cutting engine gap is currently
open** - but that status is continuously re-earned, not permanent: the
`linux-system-roles` benchmark round above (`0.9.158`-`0.9.171`) found
and fixed 15 more cross-cutting plain-`{{ }}`-evaluator bugs well after
this paragraph was first written at `0.9.84` (depth-unaware operator
parsing that could stack-overflow, block-level `vars:` never parsed, a
missing `d()` filter alias, dict/array literals unsupported outside a
`+` operand, among others - see that section for the full list). Treat
"no gap remains open" as "none is known right now", re-verified by each
new real-host benchmark round, not as a claim the search is finished.
Cloud plugins (`ec2`, `s3_bucket`, `azure_rm_*`) and inventory *plugins*
(`aws_ec2.yml` et al.) remain explicitly lowest-ROI and are not planned -
everything else in this list is being picked off incrementally, each
verified against real `ansible-playbook` directly and via the compat
harness the same way every other entry in this file has been, not
assumed from documentation.

**Fixed in `0.9.42`:** the `{{ }}`-wrapped filter pipeline only ever split
on the *first* `|`, so a single filter chained after another (e.g. `x |
sort | join(',')`) silently did nothing beyond the first filter - the
whole pipeline collapsed to a plain `String` after every single filter
application, so even when a second filter's *name* parsed correctly, it
had no real array/hash structure left to operate on (`sort`'s own
string-only output couldn't feed `join` a real array). This was the
`find`/`stat` compat playbooks' own documented blocker for comparing a
real path list rather than just a match count (see `19-find.yml`'s
`ROADMAP.md`/`compat/README.md` notes) - a real, separate limitation from
the dotted-variable-access fix above, not the same gap.

Fixed by rewriting `FilterEngine` to operate on `JSON::Any` instead of
`String` end to end, and by having `ExpressionEvaluator` split a `{{ }}`
expression on *every* top-level `|` (via a new `FilterEngine.split_chain`,
which correctly ignores a `|` inside a quoted argument or a parenthesized
filter's own arg list - e.g. `replace('a|b', 'c') | upper` is two filters,
not three) rather than just the first one, then fold each filter over the
running `JSON::Any` value in order. Only the *final* value in the chain is
stringified for template interpolation (via
`VariableLookup#format_value`, now public so both the plain-lookup path
and the filter-chain path render booleans/arrays/hashes identically).
`VariableLookup` also gained a new `#resolve` method returning the raw
`JSON::Any` for a variable (simple/nested/indexed access) rather than a
pre-formatted `String`, so the filter chain has real structure to start
from - `simple`/`nested`/`indexed` themselves keep their existing
`String`-returning signatures and behavior (now implemented as thin
wrappers around `#resolve` + `#format_value`), so no other caller needed
to change.

- New filters, several of them needed to make chaining *useful* rather
  than just mechanically correct, verified against real `ansible-playbook`
  output rather than assumed from Jinja2 docs: `sort` (now a real
  array-returning filter; a string-encoded array was never sortable in
  any useful sense before), `unique`, `reverse`, `join(sep)`, `list`,
  `first`, `last`, `min`, `max`, `int`, `float`, `string`, `bool`, `abs`,
  and `map(attribute='x')` (only the `attribute=` form - real Jinja2's
  `map()` also has a bare filter-name form, e.g. `list | map('upper')`,
  not implemented here since `attribute=` is the one real playbooks
  combine with `stat:`/`find:`'s own dict-list output). `length`/`count`
  now correctly report an array/hash's element count rather than always
  treating the value as a string to measure characters of. `split` now
  returns the *whole* split array rather than only ever the first element
  (a documented "for simplicity" cut before this) - a real behavior
  change, but one that makes it actually useful for chaining
  (`x | split(',') | length`), and nothing in this codebase depended on
  the old first-element-only behavior (grepped for other callers before
  changing it).
- `default('fallback')` now parses an unquoted, purely-numeric argument as
  a real number (`default(0)`) rather than always producing a string -
  otherwise a filter chained after `default(0)` would see the string
  `"0"` instead of a real `0`, breaking any numeric filter/comparison
  downstream. A quoted argument (`default('0')`) still stays a string,
  matching real Jinja2.
- Verified against real `ansible-playbook` directly (not just the compat
  harness): a three-task smoke playbook covering `sort | join(',')`,
  `map(attribute='path') | sort | join(',')` (the exact shape `find:`'s
  own docs point at - "see stat module for full output of each
  dictionary" - and the harness's own previously-blocked comparison), and
  `unique | length`, all producing byte-identical output on both engines.
  `compat/playbooks/19-find.yml` was then extended with a
  `recursive.files | map(attribute='path') | sort | join(',')` line of
  its own (verified the same way, standalone, before running the full
  harness) - closing the gap `compat/README.md`'s `find` entry has
  documented since that playbook was first written.
- New unit coverage in `spec/unit/filter_engine_spec.cr` (rewritten for
  the `JSON::Any` API - the whole point of this change, so the old
  `String`-only assertions couldn't just be left in place), including a
  dedicated `map(attribute=...) | sort | join(',')` chain example and a
  `split_chain` example asserting a `|` inside a quoted filter argument
  isn't treated as a chain separator.

**Fixed in `0.9.41`:** `become:`/`become_user:` were parsed and threaded
through `Task`/`TaskExecutor` (including block/role inheritance) but never
actually applied anywhere command/plugin execution happens - no `sudo`/`su`
wrapping in `LocalExecutor`, `SSHManager`, or `PluginManager`, so a
playbook that relied on `become: true` to run as a different user silently
ran as whatever user crystal-ansible itself was invoked as instead. Found
while writing `compat/playbooks/36-postgresql-db.yml` (worked around there
with a plain `su postgres -c '...'` shell command instead of `become:`,
since using it as written would have silently diverged between engines -
see `compat/README.md`'s coverage section).

Fixed by wrapping the *whole plugin process* - not individual shell
commands - in `sudo -n -u <user> --`, at the one place both the local
spawn (`PluginManager#execute_local_plugin`) and the remote path
(`PluginManager#execute_remote_plugin`, which uploads a plugin binary and
runs it directly on the target over SSH) already funnel through. This
covers every plugin uniformly with no plugin-specific code: `command:`/
`shell:`'s own subprocess simply inherits the already-escalated identity
of its parent (the plugin binary), and plugins that do file I/O directly
in-process (`copy:`, `file:`, etc.) run *as* the become user rather than
merely shelling a command as one. `become:`/`become_user:` are carried as
plain top-level fields on the same JSON config every plugin already
receives over stdin (embedded by `TaskExecutor#build_plugin_config`) rather
than as new parameters threaded through every call site - which also means
they round-trip through `async:`'s job file for free, since that's the
same config re-read verbatim by `__async_run`. Verified locally, over SSH
(a self-SSH loopback), and under `async:`, in all three cases confirming
via a `printenv SUDO_USER` check that the child process genuinely ran
through sudo rather than the task merely not erroring.

- `become_user:` is validated against a strict username allow-list
  (`/\A[a-zA-Z_][a-zA-Z0-9_.-]{0,31}\z/`) before either path uses it -
  required on the remote/SSH path regardless, since that command is
  interpolated into a shell string (`SSHManager` always runs the whole
  command through `bash -c`, so there's no args-array primitive to
  sidestep quoting with there), and enforced on the local path too for
  consistency even though `Process.new`'s own args array doesn't need it.
  An invalid `become_user:` fails the task cleanly with `become_user "..."
  is not a valid username` instead of ever reaching a shell.
- No become-password support (`ansible_become_pass`/`--ask-become-pass`) -
  `sudo` always runs with `-n` (non-interactive), so a `become_user:` that
  needs a password to sudo to fails clearly rather than hanging on a
  prompt nothing could ever answer. A documented scope cut, not an
  oversight - the same "no real interactive-prompt model" limitation
  `pause:` already has.
- `become_user:` defaults to `"root"` when `become: true` is set with no
  explicit user, matching real Ansible's own default.
- Fixing this surfaced a second, previously-invisible bug (invisible
  because `become:`/`become_user:` never did anything before now, so
  nothing ever exercised this path): `become_user:` was never run through
  `{{ }}` variable substitution at all, unlike every `params:` value - a
  playbook using the common `become_user: "{{ service_user }}"` pattern
  would have silently sudo'd to the literal, unsubstituted string
  `"{{ service_user }}"` (itself invalid as a username, so it would now
  fail loudly rather than misbehave silently - but still wrong). Fixed by
  substituting `task.become_user`/`handler.become_user` through the same
  `VarSubstitutor` already used for `params:`, once per task-execution
  site (`execute_task_once`, `execute_handler_internal`) - `task`/
  `handler` themselves are never mutated, since both are shared/reused
  across hosts and loop iterations.
- Verified with a new integration spec
  (`testing/test-become-quick.yml`/`spec/integration/cli_spec.cr`) -
  targets `hosts: testservers` (same convention as
  `test-mysql-quick.yml`/`test-docker-quick.yml`) so the generic
  auto-discovered "runs every `testing/*.yml` fixture in `--check` mode"
  test skips the whole play rather than failing: `command:`/`shell:`
  refuse to act under `--check` at all (matching real Ansible), which
  would otherwise leave a register value undefined and
  `become_user: "{{ current_user.stdout }}"` rendering the literal text
  `"undefined"` - a string that looks like a plausible username to the
  validation above, but that `sudo` itself would then reject for real
  ("unknown user undefined"), failing the task for real even under
  `--check`. The dedicated spec exercises it for real against
  `inventory-testservers-local.ini` instead: `become:` to the same user
  already running the spec (safe on any dev machine without real root,
  the same convention `user_spec.cr`/`group_spec.cr` use - sudo/PAM
  defaults allow becoming yourself without a password since it's not a
  real privilege change) and asserts `SUDO_USER` was actually set in the
  child's environment, plus the invalid-`become_user` rejection path.
- Also verified via a new compat-harness playbook
  (`compat/playbooks/37-become.yml`) - unlike the spec above, this one
  runs as root inside its own throwaway container (the compat image's
  default user), so it exercises a *real* privilege drop to a newly
  created non-root user: `whoami` with and without `become:`, file
  ownership after a `copy:` task run under `become:`, and the invalid-user
  rejection path - `compat/Dockerfile` needed `sudo` added to its package
  list, which wasn't there before since nothing in this codebase ever
  used it.

**Fixed in `0.9.35`:** the recap `ok`/`changed` counters being mutually
exclusive rather than real Ansible's overlapping ones. Verified against a
real `ansible-playbook` run rather than assumed: 2 changed + 1 unchanged
successful task produces `ok=3 changed=2` in real Ansible - every
successful task (changed or not) counts toward `ok`, and `changed` is a
separate tally on top of that, not an alternative bucket. This codebase's
`ResultDisplay.update_stats` previously used `if failed ... elsif changed
... else ok`, so a changed task was counted *only* as changed, never also
as ok - fixed to increment `ok` unconditionally on success and `changed`
additionally when the result says so, matching the verified real-Ansible
shape exactly (the same fixture now produces `ok=3 changed=2` on both
engines). Regression-tested directly against `update_stats` in a new
`spec/unit/result_display_spec.cr` (5 examples: changed counts toward
both, unchanged counts toward ok only, a real failure counts toward
failed only, an ignored failure still counts toward ok/changed rather
than failed, and counts accumulate correctly across several tasks).

**Fixed in `0.9.34`:** dotted-variable access in **bare** (non-`{{ }}`)
conditionals used by `when:`/`until:`/`changed_when:`/`failed_when:` - this
was the *other* half of the cross-cutting gap above, and turned out to be
much more tractable than the filter-chaining one, so it was picked up
first. `ConditionalEvaluator#evaluate_value` previously did a plain
`vars.has_key?(expr)` lookup with no path-splitting at all, so a condition
like `when: result.rc == 0` (the ordinary, unwrapped way real Ansible
expects `when:` to be written - not a niche case) silently evaluated
`result.rc` to undefined instead of the real value; only the `{{ }}`-wrapped
`ComparisonEvaluator` path (reached by writing `when: "{{ result.rc == 0
}}"` instead) supported dotted access before this. Fixed by adding a
`resolve_dotted` helper that splits on `.` and navigates a `JSON::Any` Hash
structure to arbitrary depth (`stat_result.stat.exists` works, not just one
level), falling back to the existing bare-lookup path unchanged when there's
no `.` or the first segment isn't a real variable. Guarded against float
literals (`1.5`) also containing a `.` - the guard is that a real dotted
path's first segment (e.g. `result`) never itself parses as a float, so
`expr.to_f64?` cheaply distinguishes the two without needing a full
expression grammar. Verified against real `ansible-playbook` side by side
(not assumed): a bare single-level `result.rc == 0`/`!= 0` pair and a bare
two-level `stat_result.stat.exists` all produced identical
run/skip/run task outcomes on both engines for the same playbook.
Regression-tested in `spec/unit/conditional_evaluator_spec.cr` (6 new
examples: single-level equality, two-level nested truthiness, a
dotted-field-resolving-to-false case, a missing dotted field treated as
undefined rather than erroring, the float-literal guard, and confirming
plain non-dotted variables still work unchanged).

**Cross-cutting bug found while building `compat/playbooks/32-wait-for.yml`
(fixed in `0.9.33`):** `LocalExecutor.exec` (used by `shell:`/`command:` on
any local connection) used to hang **forever** - not a slow path, an actual
indefinite hang - on a command of the shape `sleep N && long-running-daemon
&`. Root cause: Crystal's `Process.run(..., output: IO::Memory, error:
IO::Memory)` blocks until both the child exits *and* its stdout/stderr
pipes reach EOF, which requires every process holding a duplicate of those
pipe fds to close them. `sleep N && daemon &` backgrounds a *shell* that
blocks in `wait()` on `daemon` (a plain trailing `&` backgrounds the whole
`&&`-list, and `nohup` only suppresses `SIGHUP` - it doesn't exempt a child
from its parent's own `wait()`) - since `daemon` here never exits, neither
did the shell holding the pipe open, so `Process.run` never saw EOF and the
task hung indefinitely. Confirmed as a real crystal-ansible-specific gap,
not a documentation quirk: the identical `sleep N && daemon &` command runs
fine under real `ansible-playbook` (verified side by side in the same
container) - `compat/playbooks/32-wait-for.yml` still uses the
`nohup sh -c 'sleep N; daemon' &` workaround it was written with (a single
process backgrounded directly is the better idiom regardless of the
underlying fix), but the fix itself is general and not specific to that
one command shape.
- **Fix:** `LocalExecutor.exec` now spawns with `Process::Redirect::Pipe`
  instead of handing `Process.new` a plain `IO::Memory` to write into
  directly (which is what made `Process#wait` itself block on pipe EOF, an
  implementation detail one layer down that the original bug report didn't
  narrow down to). Two fibers drain `process.output`/`process.error` into
  memory buffers independently of `process.wait`, so the process's own OS
  exit is detected without depending on when (or whether) the pipes reach
  EOF. Once `process.wait` returns, each drain fiber gets a bounded
  `DRAIN_GRACE_PERIOD` (200ms) to finish reading whatever the process had
  already flushed into the pipe's kernel buffer before exiting - real
  output is never truncated by this window in practice, since it's already
  sitting in the buffer by the time the process exits and a fiber has been
  draining it concurrently since the process started, not just after exit.
  If a fiber hasn't finished after the grace period (a lingering
  backgrounded grandchild still holding the pipe open), the pipe is
  force-closed to unblock the fiber's pending read rather than leaking it
  forever, and the call returns with whatever was captured up to that
  point. Verified: the exact `sleep N && daemon &` shape that used to hang
  now returns near-instantly (confirmed both via a direct plugin-binary
  reproduction and inside the actual compat-harness container); normal
  commands still capture full stdout/stderr/exit code correctly, including
  large output (500KB, unmodified byte count) that would previously have
  relied on the same blocking-pipe-drain path. Regression-tested in
  `spec/unit/local_executor_spec.cr` (4 examples: normal stdout capture,
  stderr + nonzero exit, large-output non-truncation, and the
  `sleep && daemon &` hang itself - asserted to complete in well under the
  worst-case bound and to have genuinely started the backgrounded daemon,
  not just to avoid erroring).
- **Also fixed in the same pass:** `build.sh`'s per-plugin staleness check
  only compared each `plugins/<name>.cr`'s own mtime against its binary,
  unlike the main executable's own check just above it in the same file
  (which already walks `src/*.cr` too) - so a `src/` dependency change
  like this one silently left every plugin binary stale, `./build.sh`
  reporting "up to date" the whole time. Caught only because a fresh test
  run showed the fix hadn't taken effect at all, not from any error output.
  Fixed by giving the plugin loop the same `find src -name '*.cr' -newer
  "$BINARY"` check the main executable already had - the same class of gap
  the main executable's own mtime check was fixed for previously (see
  Phase 3's `file` plugin entry), now closed for plugins too.

**Result (with Phase 5 complete):** genuine parity for routine Linux server
automation - the full set of commonly-used `ansible.builtin` modules plus the
already-shipped core engine, plugins, and compatibility harness.

---

## Total estimate

Roughly 12-18 weeks of focused work across Phases 1-4, plus Phase 0 up front.
**Phases 0-5 are all now complete** (Phase 5 as of `0.9.31`, with full
compat-harness coverage for all eight of its modules added at `0.9.32`).
All four cross-cutting engine gaps this roadmap ever tracked are now fixed
(dotted-variable access `0.9.34`, recap counter overlap `0.9.35`, `become:`
`0.9.41`, Jinja2 filter-chaining `0.9.42` - see each entry above). What
remains is only the lower-priority per-plugin scope-cut list documented in
each shipping plugin's own entry.
