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
