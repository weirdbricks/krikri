# spec/integration → test/integration migration progress

1:1 conversion of `spec/integration/*_spec.cr` to `test/integration/*_test.cr`
(minitest.cr). The classic suite under `spec/` stays untouched. Batches are
converted alphabetically; each batch is verified (test-count parity, serial
run, `-p 4` run, `crystal tool format`, ameba) and committed separately.

## Batches

### Batch 1 (16 files): adhoc_cli .. apt_repository
- adhoc_cli_spec.cr, alternatives_spec.cr, ansible_check_mode_var_spec.cr,
  ansible_mariadb_alias_spec.cr, ansible_play_hosts_spec.cr,
  ansible_ssh_user_alias_spec.cr, ansible_version_spec.cr,
  any_errors_fatal_spec.cr, apache2_module_spec.cr, apt_cache_updated_spec.cr,
  apt_deb_spec.cr, apt_key_spec.cr, apt_param_coverage_spec.cr,
  apt_pinned_version_spec.cr, apt_repository_param_coverage_spec.cr,
  apt_repository_spec.cr

### Batch 2 (16 files): assemble_role_relative_src .. check_mode_scope_inheritance
- assemble_role_relative_src_spec.cr, assemble_spec.cr, assert_spec.cr,
  assert_strict_boolean_spec.cr, assert_strict_undefined_spec.cr,
  assert_undefined_register_shape_spec.cr, authorized_key_spec.cr,
  blockinfile_param_coverage_spec.cr, blockinfile_spec.cr,
  block_name_strict_undefined_spec.cr, block_rescue_accounting_spec.cr,
  block_when_skip_register_spec.cr, broken_pipe_spec.cr,
  capabilities_spec.cr, changed_when_stderr_lines_spec.cr,
  check_mode_scope_inheritance_spec.cr

### Batch 3 (4 files): cli, command_shell_check_mode, command, community_crypto_short_name
- cli_spec.cr, command_shell_check_mode_spec.cr, command_spec.cr,
  community_crypto_short_name_spec.cr

### Batch 4 (15 files): connection_cli_flags .. copy_vault_decrypt
- connection_cli_flags_spec.cr, connection_failure_unignorable_by_failed_when_spec.cr,
  connection_plugin_resolution_spec.cr, copy_attribute_reconcile_spec.cr,
  copy_backup_file_spec.cr, copy_binary_source_staging_spec.cr,
  copy_directory_spec.cr, copy_missing_src_spec.cr, copy_owner_spec.cr,
  copy_param_coverage_spec.cr, copy_precomputed_match_spec.cr,
  copy_staging_mode_spec.cr, copy_trailing_slash_dest_spec.cr,
  copy_validate_spec.cr, copy_vault_decrypt_spec.cr

### Batch 5 (15 files): creates_skip_result_shape .. delegate_to_localhost
- creates_skip_result_shape_spec.cr, crinja_in_string_undefined_spec.cr,
  cron_spec.cr, cronvar_spec.cr, deb822_repository_param_coverage_spec.cr,
  deb822_repository_spec.cr, debconf_param_coverage_spec.cr,
  debugger_spec.cr, debug_msg_var_exclusive_spec.cr,
  debug_var_lazy_extract_raise_spec.cr, debug_var_result_key_spec.cr,
  debug_verbosity_skip_spec.cr, deep_render_item_audit_spec.cr,
  default_file_mode_umask_spec.cr, delegate_to_localhost_spec.cr

### Next file to convert
- dir_listing_spec.cr and on (alphabetical)

## Count table

| Batch | Files | `it` blocks | Notes |
|-------|-------|-------------|-------|
| 1 | 16 | 124 | see renames/deviations below |
| 2 | 16 | 105 | see renames/deviations below |
| 3 | 4 | 180 | cli_spec's `it`-per-fixture Dir.glob loop unrolled; counts below are RUNTIME tests (spec file shows 101 `it` blocks because the loop counts once) |
| 4 | 15 | 71 | connection_plugin_resolution's conn_type loop unrolled (spec file shows 4 `it` blocks, one is the loop) |
| 5 | 15 | 107 | cron backup specs serialize on STATE_MUTEX and count glob SET differences (see below) |

## Renames / deviations

- `ansible_mariadb_alias_test.cr`: the classic spec looped module names
  around `describe` (`%w[...].each do |m| describe ... end`); minitest's
  describe/it macros cannot expand inside a runtime block, so the loop is
  unrolled into one `it` per module name (4 tests, same runtime count).
- `apache2_module_test.cr`: `Spec.before_suite` shim setup became a
  `before_each` and the fixed shared `spec/tmp/apache2-fake-bin` dir became
  per-test `PluginSpecHelper.tmp_path("apache2-fake-bin")`.
- `adhoc_cli_test.cr`: `Spec.before_suite` build trigger replaced by a
  fail-fast check (minitest has no before_suite; the suite requires
  `./build.sh` first). `-t` tree dirs moved to `tmp_path`.
- `apt_key_test.cr`: the url:-fetch HTTP double's server moved from
  file-scoped locals to private file-level constants (all test files compile
  into one binary); `with_apt_key_shim` holds `ENV_MUTEX`; the shim's
  `gpg --with-colons` parse now runs with a throwaway `GNUPGHOME`
  (`mktemp -d`) because the default `~/.gnupg` made the parse intermittently
  return empty under concurrent load - both failing flavors of
  "post-add verification" flake traced to this.
- Fixture refs repointed from `File.join(PROJECT_ROOT, "spec", "fixtures", ...)`
  to `File.join(__DIR__, "..", "fixtures", ...)` (test/fixtures has the
  identical copies), matching test/unit's convention.
- `.ameba.yml`: `Lint/NotNil`, `Style/HeredocEscape` and
  `Style/HeredocIndent` now exclude `test/integration/*` (converted files
  carry the same heredoc shims the spec exclusions already covered).

- Shared converter now handles failure-message arguments
  (`x.should eq(y), "msg"` -> `x.must_equal(y, "msg")`) and argless
  `be_nil`/`be_empty`; crystal spec's `next unless <cond>` inside an `it`
  body becomes `skip "..." unless <cond>` (crystal spec's `next` counted a
  pass, minitest's skip counts a skip - blockinfile_param_coverage's
  chattr-guarded example is the first instance).
- cli_test: before_suite build trigger -> fail-fast check; scratch
  playbooks moved from shared spec/tmp to per-test tmp_path
  (run_playbook now accepts absolute fixture paths); the Dir.glob loop
  unrolling above; describe-body locals (testservers/magicvars/
  hostvars/explicit inventories) became methods; the loop-counting
  fixture's baked-in /tmp path is rewritten per test to a tmp_path.
- command_test's expanduser test and the ENV["HOME"]-mutating unit specs
  (filter_engine, jinja_renderer, mysql_connection, async_status_plugin,
  command_expand_argument_vars) now hold ENV_MUTEX and RESTORE HOME -
  the leaked /home/testuser HOME from the expanduser unit specs crashed
  the CLI async: spec's spawned binary (mkdir /home/testuser denied).
- connection_plugin_resolution_test: the conn_type loop around describe
  unrolled (5 static its); bare-`next` podman-skip became `skip`.
- copy_missing_src_test: `json = result.should be_a(JSON::Any)` (spec
  matchers return the narrowed value) became an explicit
  `result.as(JSON::Any)` cast plus the assertion.
- command_test's "starting directory deleted out from under it" spec no
  longer points the SHARED minitest process's cwd at a deleted dir
  (under -p 4 that handed every concurrently-spawned plugin child a
  deleted cwd, surfacing as "Error getting current directory" in
  unrelated tests); a throwaway shell now cds into a temp dir, deletes
  it out from under itself and execs the plugin, so the scenario is
  scoped to the plugin process.
- copy_vault_decrypt_test: vault-password mutations wrapped in the
  `with_vault` helper (STATE_MUTEX).
- copy_backup_file/copy_param_coverage: shared spec/tmp root ->
  tmp_path; chattr `next unless` -> `skip unless`.
- async_jobs_test's cleanup_all sweep (shared ~/.ansible_async) holds
  STATE_MUTEX, and the CLI async:/async_status: smoke test holds
  STATE_MUTEX + ENV_MUTEX - the sweep could delete an in-flight
  integration job's status file ("could not find job" flake under -p 4).
- cron_test: the backup specs count /tmp/crontab* set differences, not
  size deltas (leftover backup files from an earlier failed run skewed
  size deltas), and the three backup specs serialize on STATE_MUTEX -
  the cron plugin's real backups land in the fixed /tmp/crontab*
  namespace (real crontab's own convention), so concurrent tests would
  see each other's files.
- debugger_test: describe-body local `templated` became a method.
- assemble/authorized_key: shared `spec/tmp` roots moved to per-test
  `PluginSpecHelper.tmp_path`; before_suite mkdir_p dropped.

## Known pre-existing failures

- None so far. (test/unit's `local_executor_test.cr` "captures stderr" is
  flaky under heavy machine load, unrelated to integration conversion.)
