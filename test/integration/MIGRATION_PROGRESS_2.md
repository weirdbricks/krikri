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

## Batch 5 (committed): template_handler .. tmp_symlink_race (13 files)

| file | spec its | test its | notes |
|------|---------|----------|-------|
| template_handler_test.cr | 1 | 1 | |
| template_import_with_context_test.cr | 2 | 2 | |
| template_include_search_path_test.cr | 2 | 2 | |
| template_in_operator_test.cr | 1 | 1 | |
| template_markup_safe_toplevel_test.cr | 2 | 2 | |
| template_nbsp_whitespace_test.cr | 1 | 1 | |
| template_test.cr | 32 | 32 | before_suite fixture tree -> file-level begin-block constant (unique per process); 6 `next if root/no-chattr` guards -> `skip "..." if`; nested describe `newline_sequence: (default "\n")` renamed to `(default LF)` - minitest interpolates nested describe names into generated code, a literal backslash-escape breaks it |
| template_string_entry_retemplating_test.cr | 2 | 2 | |
| template_trailing_slash_dest_test.cr | 3 | 3 | |
| template_tuple_sort_test.cr | 1 | 1 | spec's `fail(...)` -> minitest `flunk(...)`; `should be <` -> `(a < b).must_equal(true)` |
| template_undefined_chain_default_test.cr | 1 | 1 | |
| template_validate_remote_tmp_test.cr | 2 | 2 | |
| tmp_symlink_race_test.cr | 1 | 1 | before_suite fixture tree + HTTP server + `race_base` closure local -> file-level constants (RACE_DIR/RACE_TEST_SERVER/RACE_BASE, unique per process) |

## Batch 6 (committed): touch_result_shape .. until_list_retry (13 files)

| file | spec its | test its | notes |
|------|---------|----------|-------|
| touch_result_shape_test.cr | 6 | 6 | |
| unarchive_controller_src_staging_test.cr | 3 | 3 | before_suite tar build -> file-level constant (unique per process) |
| unarchive_loop_creates_skip_test.cr | 3 | 3 | same; one `should contain("...(item=")` (unbalanced paren) fixed by hand |
| unarchive_test.cr | 28 | 28 | before_suite fixture tree -> begin-block constant; HTTP server locals -> UNARCHIVE_* constants |
| unarchive_zip_slip_test.cr | 5 | 5 | before_suite (python hostile-archive build) -> file-level setup |
| undefined_filter_chain_strict_test.cr | 3 | 3 | |
| unknown_filter_task_vars_test.cr | 3 | 3 | |
| unreachable_host_halt_test.cr | 3 | 3 | |
| unreachable_host_test.cr | 6 | 6 | |
| unreachable_port_refused_test.cr | 3 | 3 | |
| unresolved_module_hard_stop_test.cr | 5 | 5 | |
| unsafe_data_test.cr | 33 it-lines (matches spec runtime count) | 32 it-lines | spec's runtime `.each`-loop describes/tests -> nested `{% for %}` macro loops replicating the matrix_cases filter and index order; `assert_not_executed` helper -> macro stamping one named test per call site; spec's parenless two-line `should be_false, "msg"` forms -> `must_equal(false, "msg")`; single-char/short block params renamed (ameba) |
| until_list_retry_test.cr | 1 | 1 | |

Verification (both batches): serial 5208 tests, 0 failures / 0 errors;
`-p 4` clean.
