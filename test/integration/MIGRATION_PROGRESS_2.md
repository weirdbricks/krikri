# MIGRATION_PROGRESS_2.md — range role_dependency_when .. yum_versionlock

Separate log for this range (the middle range is tracked in
MIGRATION_PROGRESS.md). One entry per committed batch: files, per-file
test counts, renames, and notes.

## Batch 1 (committed): role_dependency_when .. role_scope (5 files)

| file | spec its | test its | notes |
|------|---------|----------|-------|
| role_dependency_when_test.cr | 4 | 4 | |
| role_local_filter_plugins_test.cr | 9 | 9 | |
| role_local_lookup_plugins_test.cr | 5 | 5 | |
| role_name_magic_var_test.cr | 2 | 2 | |
| role_scope_test.cr | 7 | 7 | |

Verification: `scripts/minitest.sh` 4568 tests, 0 failures / 0 errors;
`-p 4` second run clean (first run had a flaky Docker-daemon failure in
cli_test.cr's end-to-end Docker smoke test - host-wide Docker resource
race, not in this range; re-run confirmed).

## Batch 2 (committed): rpm_key_param_coverage .. slurp (13 files)

| file | spec its | test its | notes |
|------|---------|----------|-------|
| rpm_key_param_coverage_test.cr | 5 | 5 | describe got `serial!` (PATH ENV shim) |
| script_test.cr | 14 | 14 | before_suite TMP_DIR -> per-test tmp_path; chdir arg now sc_path |
| serial_test.cr | 7 | 7 | |
| service_param_coverage_test.cr | 6 | 6 | two `next unless /etc/init.d/cron` skips -> `skip "..." unless` |
| set_fact_changed_when_self_reference_test.cr | 1 | 1 | |
| set_fact_native_typing_test.cr | 5 | 5 | fixed /tmp/pid path -> PluginSpecHelper.tmp_path |
| set_fact_resolved_brace_text_verbatim_test.cr | 3 | 3 | |
| set_fact_run_scope_test.cr | 1 | 1 | |
| set_fact_test.cr | 7 | 7 | |
| set_fact_strict_undefined_access_test.cr | 7 | 7 | |
| shell_quote_escape_regression_test.cr | 4 | 4 | |
| shell_test.cr | 15 | 15 | |
| slurp_test.cr | 6 | 6 | before_suite TMP_DIR -> per-test tmp_path |

Verification: serial 4649 tests, 0 failures / 0 errors; `-p 4` second
run clean (first run had a flaky test/unit/local_executor_test.cr
failure under concurrency, not in this range; re-run confirmed).

## Batch 3 (committed): start_at_force_handlers .. systemd (13 files)

| file | spec its | test its | notes |
|------|---------|----------|-------|
| start_at_force_handlers_test.cr | 5 | 5 | |
| static_import_undefined_test.cr | 3 | 3 | |
| stat_test.cr | 6 | 6 | describe got `serial!` (HOME ENV shim); before_suite TMP_DIR -> per-test tmp_path |
| strategy_test.cr | 5 | 5 | two `should be <` orderings -> `(a < b).must_equal(true)` |
| strict_conditionals_test.cr | 12 | 12 | |
| subversion_param_coverage_test.cr | 15 | 15 | |
| subversion_result_shape_test.cr | 6 | 6 | |
| subversion_test.cr | 2 | 2 | fixed /tmp/svn-checkout-test -> PluginSpecHelper.tmp_path |
| sudoers_test.cr | 17 | 17 | before_suite TMP_DIR -> per-test tmp_path |
| symbolic_mode_test.cr | 2 | 2 | |
| synchronize_test.cr | 8 | 8 | |
| sysctl_test.cr | 14 | 14 | before_suite rm_rf+mkdir of shared sysctl dir -> per-test tmp_path |
| systemd_test.cr | 19 it-lines (20 tests) | 19 it-lines (20 tests) | runtime `.each`-loop `it`s -> `{% for %}` macro loop |

Verification: serial 4782 tests, 0 failures / 0 errors; `-p 4` clean
first try.

## Batch 4 (committed): tag_selection .. template_for_loop_undefined_iteration (13 files)

| file | spec its | test its | notes |
|------|---------|----------|-------|
| tag_selection_test.cr | 14 | 14 | |
| task_arg_undefined_context_test.cr | 1 | 1 | |
| task_check_mode_test.cr | 5 | 5 | before_suite rm_rf+mkdir of shared dir -> per-test tmp_path |
| task_less_play_facts_test.cr | 2 | 2 | |
| task_role_prefix_test.cr | 3 | 3 | |
| tempfile_test.cr | 6 | 6 | |
| template_ansible_hostname_undefined_test.cr | 2 | 2 | |
| template_bare_if_undefined_test.cr | 4 | 4 | |
| templated_action_plugin_upload_test.cr | 1 | 1 | |
| template_destpath_magic_var_test.cr | 1 | 1 | |
| templated_ignore_errors_test.cr | 2 | 2 | |
| templated_no_log_test.cr | 3 | 3 | |
| template_for_loop_undefined_iteration_test.cr | 2 | 2 | |

Verification: serial 4828 tests, 0 failures / 0 errors; `-p 4` clean.
