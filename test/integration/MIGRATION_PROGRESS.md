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

### Next file to convert
- assemble_role_relative_src_spec.cr (then assemble_spec.cr, assert_spec.cr, ...)

## Count table

| Batch | Files | `it` blocks | Notes |
|-------|-------|-------------|-------|
| 1 | 16 | 124 | see renames/deviations below |

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

## Known pre-existing failures

- None so far. (test/unit's `local_executor_test.cr` "captures stderr" is
  flaky under heavy machine load, unrelated to integration conversion.)
