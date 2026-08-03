# Crystal Play - Roadmap to Ansible Parity

**Status as of 2026-08-03:** builds again on Crystal 1.20.3 (fixed `as_i` -> `as_i64`
type mismatch in `comparison_evaluator.cr`). **Phase 0, Phase 1, and Phase 2 are
all done** (roles, import/include, and vault); **Phase 3 is in progress**
(`0.9.5`) - `stat`, `find`, `archive`, `unarchive`, `apt_repository`,
`yum_repository`, `sysctl`, `mount`, `ufw`, and `firewalld` are done.
405+ specs passing, `ameba` clean on all new/touched code. Added a Docker-based
compatibility harness (`compat/`, see `compat/README.md`) that runs the same
playbooks through real `ansible-playbook` and `crystal-ansible` side by side and
diffs the results - ground truth instead of assumptions about Ansible's
documented behavior; 26/26 compat playbooks pass, including all of roles,
`import_playbook:`, `import_tasks:`, `include_tasks:`, `include_role:`,
vault (both a whole vault-encrypted playbook file and an inline `!vault`
variable), `stat`, `find`, `archive`, `unarchive`, `apt_repository`,
`yum_repository`, `sysctl`, `mount`, and `firewalld` (`ufw` is the one
exception - see its own entry below for why it couldn't be verified there).
Along the way it (and, for some bugs the file-state-diffing approach can't
catch, plain manual testing, self-review, and unit-test writing) found and
fixed 15 real bugs: `authorized_key` registered under the wrong FQCN (it's
`ansible.posix.authorized_key`, not `ansible.builtin.*` - confirmed via
`ansible-doc`, not memory), plugin resolution breaking outside the repo
checkout, `Host.from_json` crashing on a host with no explicit user,
`lineinfile` inserting a spurious blank line on every append/removal to a file
already ending in a newline, `include_role:` + `loop:` producing duplicate
handler *Task objects* sharing a name (which `HandlerRunner` ran once each
instead of deduping by name), task-level `vars:` never being parsed for
`import_tasks:`/`include_tasks:` at all, boolean variables rendering as
Crystal's lowercase `true`/`false` in templates instead of Python/Jinja2's
capitalized `True`/`False`, an unset `excludes:` on `find:` excluding every
result (an empty pattern list means "match everything" for `patterns:` but was
wrongly reused with the same meaning for `excludes:`, where it should mean
"exclude nothing"), `archive`'s directory arguments being double-included when
passed to `tar`/`zip` alongside their own already-walked children, `arcroot`
being computed wrong due to a real Crystal/Python `dirname` divergence on
trailing-slash paths, `exclusion_patterns` silently failing to match any
path with a subdirectory component because `*` doesn't cross `/` in Crystal's
`File.match?`, `apt_repository`'s removal logic silently no-oping because
`grep -v ... && mv ...` skips the `mv` whenever `grep -v` filters out every
line (its normal exit-1-for-zero-output-lines behavior, not an error) - the
common case when removing the only line from a single-repo file, `mount`'s
`check_mode` originally only guarding the real mount/umount step, not the
fstab file write itself (caught in self-review, before it ever shipped),
`ufw`'s `from_ip`/`from_port`/`to_ip`/`to_port` handling wrongly pairing ip
with port instead of treating all four as independent appends (caught writing
unit tests, since real end-to-end verification wasn't possible for this one -
see below), and `firewalld`'s rule values being interpolated into shell
commands unquoted, breaking on a `rich_rule` containing spaces and embedded
double quotes. Next up is the rest of Phase 3. This
roadmap sequences the remaining work from the two prior analysis docs
([WHATS_MISSING.md](WHATS_MISSING.md), [MISSING_FEATURES_COMPREHENSIVE.md](MISSING_FEATURES_COMPREHENSIVE.md))
into phases, with the test-foundation phase (Phase 0) landing first so every
phase after it ships with a regression net instead of drifting untested.

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
- `docker_container` / `docker_image` / `docker_network`
- `mysql_db` / `mysql_user`, `postgresql_db` / `postgresql_user`

**Result:** ~99.99% playbook coverage per prior analysis.

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
- Dynamic inventory support (executable/plugin-based inventory scripts) -
  not implemented; only the group_vars:/host_vars: half of this combined
  roadmap item shipped.
- Async execution (`async:` / `poll:`, `async_status`)
- Cloud plugins (`ec2`, `s3_bucket`, `azure_rm_*`) - optional, lowest ROI
  per usage stats (~5% of playbooks)

**Result:** full Ansible parity for Linux server automation.

---

## Total estimate

Roughly 12-18 weeks of focused work across Phases 1-4, plus Phase 0 up front.
