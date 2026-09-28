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
