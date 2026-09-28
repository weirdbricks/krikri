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

### Batch 6 (10 files): delegate_to_undefined .. ec2_metadata_facts
- delegate_to_undefined_spec.cr, diff_mode_spec.cr, dnf_list_query_spec.cr,
  dnf_param_coverage_spec.cr, dnf_versionlock_spec.cr,
  docker_compose_v2_spec.cr, docker_network_info_spec.cr,
  dpkg_divert_spec.cr, dpkg_selections_spec.cr, ec2_metadata_facts_spec.cr

### Batch 7 (15 files): empty_loop_unavailable_module .. find
- empty_loop_unavailable_module_spec.cr, empty_loop_vars_skip_spec.cr,
  environment_key_injection_spec.cr, environment_strict_undefined_spec.cr,
  expect_spec.cr, extra_vars_spec.cr, fact_cache_spec.cr, facts_spec.cr,
  failed_when_arg_templating_spec.cr, fetch_spec.cr,
  file_common_result_fields_spec.cr, fileglob_list_spec.cr,
  fileglob_role_files_dir_spec.cr, file_spec.cr, find_spec.cr

### Batch 8 (10 files): firewalld_state .. git_config
- firewalld_state_spec.cr, first_found_list_candidate_lenient_spec.cr,
  first_found_no_match_fails_spec.cr, first_found_subdir_order_spec.cr,
  gather_subset_remote_user_spec.cr, generic_lookup_loop_spec.cr,
  getent_loop_invocation_spec.cr, getent_spec.cr, get_url_spec.cr,
  git_config_spec.cr

### Batch 10 (15 files): htpasswd .. include_vars_templated_value
- htpasswd_spec.cr, ignore_errors_recap_stats_spec.cr,
  import_role_when_expansion_spec.cr,
  import_tasks_parent_when_short_circuit_spec.cr,
  include_load_failure_recap_spec.cr,
  include_loop_broken_when_recap_spec.cr,
  include_loop_no_load_after_halt_spec.cr,
  include_role_missing_recap_spec.cr,
  include_role_vars_cross_reference_spec.cr,
  include_tasks_empty_file_spec.cr, include_tasks_index_var_spec.cr,
  include_vars_dir_spec.cr, include_vars_failed_when_spec.cr,
  include_vars_loop_spec.cr, include_vars_templated_value_spec.cr

### Batch 11 (15 files): include_vars_undefined_path .. lookup_url_task_failure
- include_vars_undefined_path_spec.cr, ini_file_spec.cr,
  inventory_hostnames_lookup_spec.cr, inventory_ranges_magic_vars_spec.cr,
  inventory_sources_spec.cr, java_cert_spec.cr, kernel_blacklist_spec.cr,
  known_hosts_spec.cr, lazy_selectattr_undefined_leaf_spec.cr,
  lineinfile_spec.cr, list_hosts_tags_spec.cr,
  list_tasks_syntax_check_spec.cr, local_action_localhost_spec.cr,
  locale_gen_spec.cr, lookup_url_task_failure_spec.cr

### Batch 12 (15 files): loop_batched_task_vars .. modprobe
- loop_batched_task_vars_spec.cr, loop_control_spec.cr,
  looped_include_task_name_spec.cr, loop_register_aggregate_shape_spec.cr,
  loop_scalar_flatten_spec.cr, loop_source_list_type_spec.cr,
  loop_source_strict_undefined_spec.cr, loop_ternary_filter_chain_spec.cr,
  lvol_spec.cr, make_spec.cr, maven_artifact_spec.cr,
  missing_dest_dir_spec.cr, mode_octal_string_spec.cr,
  mode_octal_via_variable_spec.cr, modprobe_spec.cr

### Next file to convert
- module_defaults_spec.cr and on (alphabetical)

## Count table

| Batch | Files | `it` blocks | Notes |
|-------|-------|-------------|-------|
| 1 | 16 | 124 | see renames/deviations below |
| 2 | 16 | 105 | see renames/deviations below |
| 3 | 4 | 180 | cli_spec's `it`-per-fixture Dir.glob loop unrolled; counts below are RUNTIME tests (spec file shows 101 `it` blocks because the loop counts once) |
| 4 | 15 | 71 | connection_plugin_resolution's conn_type loop unrolled (spec file shows 4 `it` blocks, one is the loop) |
| 5 | 15 | 107 | cron backup specs serialize on STATE_MUTEX and count glob SET differences (see below) |
| 6 | 10 | 56 | dnf recording helper holds ENV_MUTEX; dpkg_divert's `tags:` kwarg dropped |
| 7 | 15 | 170 | file/find fixture trees moved to per-test tmp_path; describe-body locals became methods |
| 8 | 10 | 93 | get_url's file-scoped server locals became private constants; git_config tmp_path'd |
| 10 | 15 | 55 | htpasswd before_suite/tmp_path folded into PluginSpecHelper.tmp_path |
| 12 | 15 | 91 | make's fixed shared spec/tmp/make_spec dir became per-test tmp_path (concurrent make tests clobbered each other's Makefile); modprobe pending!s became skips |
| 11 | 15 | 150 | inventory_hostnames' CASES runtime loop became a compile-time {% for %} (12 tests); ini_file/kernel_blacklist/known_hosts/lineinfile/inventory_sources before_suite+TMP_DIR became per-test tmp_path; java_cert/locale_gen `next if` became skip; lookup_url's HTTP double became require-time constants; lineinfile chattr `next unless` became skip |

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
- dnf_param_coverage_test: with_recording_pkg_managers (fake dnf/rpm on
  PATH + log path via ENV) holds ENV_MUTEX - concurrent dnf specs got
  each other's log paths and flaked.
- dpkg_divert_test: crystal spec's `tags: "needs_dpkg"` kwarg dropped
  (minitest's it macro has no tags; -n pattern filtering covers it).
- dnf_versionlock_test: block-form matcher `each(&.as_s.should(match(re)))`
  became `each(&.as_s.must_match(re))`.
- file_test/find_test: shared spec/tmp fixture trees -> per-test
  tmp_path (find's before_suite tree builder became a per-call def).
- facts_test: `x = y.should_not be_nil` (returns the narrowed value)
  split into assertion + not_nil! read.
- environment_key_injection_test: describe-body local `marker` became a
  method (stays a fixed /tmp path by design - the probe deletes and
  checks it).
- get_url_test: the file-scoped HTTP-double locals (server/address/base)
  became private file-level constants, started once at require time (all
  test files compile into one binary).
- generic_lookup_loop_test: one `code, output = run_play(...)` with a
  dead `output` became `code, _ =` (ameba Lint/UselessAssign).
- assemble/authorized_key: shared `spec/tmp` roots moved to per-test
  `PluginSpecHelper.tmp_path`; before_suite mkdir_p dropped.
- htpasswd_test: the before_suite mkdir_p + file-scoped `tmp_path` def
  became per-test `PluginSpecHelper.tmp_path`; the `start_with` hash-prefix
  check became `expect(str_starts_with?(...)).must_equal(true)`.
- make_test: the fixed shared `spec/tmp/make_spec` TMP_DIR (Makefile +
  output.txt rewritten and deleted per test) became per-test
  `PluginSpecHelper.tmp_path("make")` - two concurrent make tests would
  have clobbered each other's files under -p 4.
- modprobe_test: the two `pending!` environment guards became `skip`.
- lookup_url_task_failure_test: the file-scoped HTTP-double locals
  (server/address/base) became private constants started once at require
  time (same shape as get_url_test); java_cert/locale_gen's `next if`
  guards became `skip ... if` (crystal spec's bare `next` is a compile
  error inside minitest's generated method bodies).
- inventory_hostnames_lookup_test: the `CASES.each` runtime loop with
  interpolated `it` names became a compile-time `{% begin %}`/`{% for %}`
  table (12 static tests, same names); the playbook heredoc moved into a
  `pattern_playbook(expr)` def so its literal `{{ }}` stays outside the
  macro expansion.
- inventory_sources_test: the before_suite directory-of-sources tree is
  rebuilt per test by an `inv_dir` def under that test's tmp_path; the
  bare.ini/single.ini writes also moved to tmp_path.
- lineinfile_test: `param_path` repointed to tmp_path; the chattr
  `next unless` guard became `skip ... unless` (probe dir arg dropped -
  the helper's default probe is fine).
- Batch 10's `File.join(PROJECT_ROOT, "spec", "fixtures", ...)` inventory
  refs repointed to `File.join(__DIR__, "..", "fixtures", ...)` per the
  batch-4 convention (test/fixtures carries identical copies).

## Known pre-existing failures

- None so far. (test/unit's `local_executor_test.cr` "captures stderr" is
  flaky under heavy machine load, unrelated to integration conversion.)
