# Crystal Play - Roadmap to Ansible Parity

**Status as of 2026-08-01:** builds again on Crystal 1.20.3 (fixed `as_i` -> `as_i64`
type mismatch in `comparison_evaluator.cr`). Phase 0 is done (test scaffolding +
CI). Phase 1 is in progress: loop constructs (`0.2.1`) and the five new plugins
(`0.3.0`) are done; `block`/`rescue`/`always` error handling is next. 202 specs
passing, `ameba` clean on all new/touched code. This roadmap sequences the
remaining work from the two prior analysis docs
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
- `block` / `rescue` / `always` error handling

**Result:** ~99.95% playbook coverage per prior analysis.

---

## Phase 2 - Organizational (~2-3 weeks)

- Roles: `roles/<name>/{tasks,handlers,vars,files,templates,defaults,meta}`
  directory resolution, variable precedence, `meta/main.yml` dependencies
- `include_tasks` / `import_tasks` / `import_playbook` / `include_role`
- Vault: AES256 encrypt/decrypt, `--ask-vault-pass`, `--vault-password-file`,
  inline `!vault` encrypted values

**Result:** enterprise-ready.

---

## Phase 3 - Extended plugins (~4-6 weeks)

- `apt_repository` / `yum_repository`
- `sysctl`, `mount`
- `ufw` / `firewalld`
- `stat`, `find`, `archive` / `unarchive`
- `docker_container` / `docker_image` / `docker_network`
- `mysql_db` / `mysql_user`, `postgresql_db` / `postgresql_user`

**Result:** ~99.99% playbook coverage per prior analysis.

---

## Phase 4 - Advanced execution features (~4-6 weeks)

- `delegate_to`, `run_once`
- `changed_when` / `failed_when`
- Async execution (`async:` / `poll:`, `async_status`)
- Dynamic inventory support + `group_vars` / `host_vars` directory loading
- Cloud plugins (`ec2`, `s3_bucket`, `azure_rm_*`) - optional, lowest ROI
  per usage stats (~5% of playbooks)

**Result:** full Ansible parity for Linux server automation.

---

## Total estimate

Roughly 12-18 weeks of focused work across Phases 1-4, plus Phase 0 up front.
