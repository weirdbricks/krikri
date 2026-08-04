# Crystal Play - Roadmap to Ansible Parity

**Status as of 2026-08-04 (currently at `0.9.35`):** **all of Phase 0 through
Phase 5 are done** - see the checkboxes in each phase section below (roles,
import/include, vault, every Phase 3 plugin, every Phase 4
advanced-execution feature, and all eight Phase 5 modules: `set_fact`
`0.9.24`, `get_url` `0.9.25`/`0.9.32`, `blockinfile` `0.9.26`, `uri` `0.9.27`,
`assert` `0.9.28`, `wait_for` `0.9.29`, `fetch` `0.9.30`, `pause` `0.9.31`).
Two of the three remaining cross-cutting engine gaps are also now fixed:
dotted-variable access in bare conditionals (`0.9.34`) and the recap
`ok`/`changed` counter overlap (`0.9.35`) - only the Jinja2
filter-chaining gap remains open (see the note near the end of Phase 5;
it needs a real architectural change, not a quick add). 606/608 specs
pass (the 2 exceptions need a live MySQL/PostgreSQL server at
`127.0.0.1:13306`/`15432`), `ameba` clean on all
new/touched code. A
Docker-based compatibility harness (`compat/`, see `compat/README.md`) runs
the same playbooks through real `ansible-playbook` and `crystal-ansible` side
by side and diffs the resulting filesystem state + exit codes - ground truth
instead of assumptions; **34/34 compat playbooks pass**, including a fresh
compat playbook per Phase 5 module (`compat/playbooks/27-set-fact.yml`
through `34-pause.yml`) added and verified in this pass - see each Phase 5
entry below and `compat/README.md`'s Coverage section for what each one
caught, including a real `get_url` field-naming bug (fixed in `0.9.32`) and
a real `LocalExecutor`/`shell:` hang bug (fixed in `0.9.33` - see the Phase
5 wrap-up note below, which also caught and fixed a related `build.sh`
staleness-check gap that let the fix silently not take effect on the first
attempt).

Two cross-cutting efforts also landed since Phases 3/4 were marked done:

- **Native syscall conversion (0.9.15-0.9.23):** a survey found most plugins
  shelled out to `/bin/bash` subprocesses for operations Crystal can do with
  stdlib syscalls. Nearly all are now native (5x-250x faster, and more robust -
  no reliance on command exit codes): `stat`/`find` (0.9.15), `archive`
  tar/gz/zip/xz/bz2 (0.9.16-0.9.18), `file` (0.9.19), `apt_repository`/
  `yum_repository` (0.9.20), `authorized_key` (0.9.21), `mount` (0.9.22),
  `sysctl` (0.9.23). Timings per plugin are in `BENCHMARK_RESULTS.md`. The
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
  `userdel`/`groupadd`/`groupmod`/`groupdel` - password management is
  explicitly out of scope, deserves its own careful design rather than a
  quick addition); `git` (clone/checkout/update via the `git` CLI); `cron`
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

- [x] `stat` (`0.9.0`): read-only file/filesystem status, feeding
  `register:` + `when:`/templating - never reports `changed`. Parameters:
  `path` (required), `follow` (default `false`), `get_checksum` (default
  `true`), `checksum_algorithm` (`md5`/`sha1`/`sha256`). Not implemented:
  `get_attributes` (lsattr flags), `get_mime` (mimetype/charset via
  `file`) - both default `true` in real Ansible but are lower-value,
  tool-dependent extras, omitted from the returned `stat` dict entirely
  rather than faked. Field shape (`exists`/`isreg`/`isdir`/`islnk`/`mode`/
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
- [x] `find` (`0.9.0`): recursive file/directory search feeding
  `register:`, reusing `stat_fields.cr` for each match's stat dict.
  Parameters: `paths` (required, comma-separated), `patterns`/`excludes`
  (comma-separated shell globs, or regexes with `use_regex: true`,
  matched against the basename), `file_type` (`file` default/`directory`/
  `link`/`any`), `recurse`, `depth`, `hidden` (a hidden directory is
  skipped entirely when descending, not just direct dotfiles - matches
  real Ansible's `os.walk`-based behavior), `size` (with `b`/`k`/`m`/`g`/
  `t` suffix and negative-for-"at most" support), `get_checksum`/
  `checksum_algorithm`. Not implemented: `age`/`age_stamp` (time-based
  filtering), `contains` (content regex search), `read_whole_file`,
  `encoding`, `mode`, `limit` - all lower-value/rarer options than the
  core path+pattern+type search that covers the overwhelming majority of
  real playbooks' `find:` usage. Read-only, never `changed`, like `stat`.
  Unit tested (`spec/unit/stat_fields_spec.cr` covers the shared parsing;
  `find`'s own glob/exclude/depth/hidden logic is integration-tested
  directly, `spec/integration/find_spec.cr`) and verified against real
  `ansible-playbook` via the compat harness (`compat/playbooks/19-find.yml`
  - passed, comparing `matched` counts rather than the `files` path list
  since crystal-ansible's filter engine doesn't yet support the Jinja2
  `map(attribute=...)`/`sort` filters needed to format that list for a
  stable comparison - a real, separate, pre-existing gap).
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
    bits, symlink resolution, `find`'s `matched` count). Full details
    and methodology in `BENCHMARK_RESULTS.md`. Existing test suites
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
  header checksum exactly. Not implemented: `exclude_path` - verified
  against a real community.general 11.2.1 install that this documented
  option is actually a no-op there (named files still end up in the
  archive), so implementing it "correctly" per the docs would make
  crystal-ansible diverge from real Ansible's actual behavior, not match
  it; `exclusion_patterns` (which does work) is supported instead. Also
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
    475.4ms). Full methodology and both comparisons in
    `BENCHMARK_RESULTS.md`. Existing `archive`/`unarchive` test suites
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
    `dest`) plus idempotent-rerun behavior. Full details in
    `BENCHMARK_RESULTS.md`. Full project suite (495 examples) passes.
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
    8-example spec suite. Full details in `BENCHMARK_RESULTS.md`. Full
    project suite (495 examples) passes.
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
    win at **4.85x**). Full details in `BENCHMARK_RESULTS.md`. Full
    project suite (516 examples) passes.
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
  - Not implemented: `ppa:` shorthand (resolves a PPA's GPG key and
    codename via the Launchpad API - a real network dependency, out of
    scope the same way other network-resolving features are throughout
    this codebase), `codename`, `install_python_apt` (crystal-ansible
    never shells out to python-apt in the first place),
    `validate_certs`, `update_cache_retries`/`update_cache_retry_max_delay`.
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
  `absent_from_fstab`/`mounted`/`unmounted`), `check_mode`. Fstab line
  format and idempotency (matched by `path`, comparing
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
  Not implemented: `remounted`/`ephemeral` states (rarer, and
  `ephemeral` has its own device-source-conflict-checking logic that's
  out of scope), Solaris/BSD vfstab handling (Linux fstab format only).
  - Caught and fixed one bug in self-review before it ever reached
    testing: `check_mode` originally only guarded the actual
    mount/umount step, not the fstab file write itself - so `--check`
    would still really rewrite `/etc/fstab`. Fixed by threading
    `check_mode` through the fstab-writing path too, with a regression
    test (`spec/integration/mount_spec.cr`) asserting the file is
    byte-for-byte untouched in check mode.
- [x] `ufw` (`0.9.5`): manages the Uncomplicated Firewall. Registered as
  `community.general.ufw`, not `ansible.builtin.ufw` - verified via
  `ansible-doc ufw`. Parameters: `state` (`enabled`/`disabled`/
  `reloaded`/`reset`), `logging`, `default` (+ `direction`), `rule`
  (`allow`/`deny`/`reject`/`limit`) plus `direction`/`interface`/
  `interface_in`/`interface_out`/`log`/`from_ip`/`from_port`/`to_ip`/
  `to_port`/`proto`/`name` (app profile)/`comment`/`delete`/`insert`/
  `route`, `check_mode`. Command shape (the "long format":
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
    over `login_host:`/`login_port:` when given). Not implemented:
    `state: dump`/`import` (mysqldump-based backup/restore),
    `config_file:` (`~/.my.cnf` credential lookup).
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
    param, not the URI's own host component). Not implemented: `state:
    dump`/`import`, `collation:`/`lc_collate:`/`lc_ctype:`/`template:`/
    `tablespace:`, `force:`, `session_role:`.
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
  `changed`. Not implemented: `state: drained` (needs `/proc/net`-style
  TCP connection-state inspection with no faithful native Crystal
  equivalent - fails clearly with a dedicated message rather than
  silently misbehaving), `exclude_hosts`/`active_connection_states`
  (drained-only options). Integration tested
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

**Also still open (lower priority - see each shipping plugin's class doc for the
exact "not implemented" list):** the documented per-plugin scope cuts (e.g.
`stat` `get_mime`/`get_attributes`, `find` `age`/`contains`, `archive`
`exclude_path`, `ufw` `insert_relative_to`, `mysql_db`/`postgresql_db`
`state: dump/import`, `postgresql_user` grants / `postgresql_privs`,
`docker_*` `networks`/`connected:`/tls), and the remaining cross-cutting
engine gap: missing Jinja2 filters such as `map(attribute=...)` and `sort`
(a real, separate limitation from dotted-variable access below - the
`{{ }}`-wrapped filter pipeline only ever splits on the *first* `|`, so even
a single supported filter chained after another, e.g. `x | sort | join(',')`,
doesn't work today; fixing this properly needs the filter engine to carry
structured `JSON::Any` values through the whole chain instead of collapsing
to a string after each step - a real architectural change, not a quick
filter-by-filter add, and bigger in scope than it looks from this one-line
mention). Cloud plugins (`ec2`, `s3_bucket`, `azure_rm_*`) and inventory
*plugins* (`aws_ec2.yml` et al.) remain explicitly lowest-ROI and are not
planned.

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
**Phases 0-5 are all now complete** (Phase 5 as of `0.9.31`). What remains is
the lower-priority scope-cut list and cross-cutting engine gaps at the end of
the Phase 5 section, plus adding compat-harness coverage for the eight Phase 5
modules (none have one yet - see each entry above).
