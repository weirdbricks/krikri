# #1936 - krikri-lint: meta-runtime[invalid-version] never fires

- Issue: https://github.com/weirdbricks/krikri/issues/1936
- Class: lint coverage (`meta-runtime` was listed in the profile order but
  had no rule behind it, and `<dir>/meta/runtime.yml` was not a kind at all)
- Reproduced on main against ansible-lint 25.2.1 / ansible-core 2.21.6.

**What diverged.** ansible-lint classifies `**/meta/runtime.{yml,yaml}` as
kind `meta-runtime` and feeds a truthy `requires_ansible` through
`packaging.specifiers.SpecifierSet`; `~2.15.0` (a single tilde is not a
PEP 440 operator) raises, so it reports `meta-runtime[invalid-version]`.
krikri-lint had no such kind and no such rule, so it reported nothing.

**Fixture.** The issue's minimal role and play, verbatim. `requires_ansible`
is a runtime no-op for `ansible-playbook` (the role loads and its debug task
runs under both engines), so this case pins the engine transcript the lint
parity fixture's role produces; the lint triple itself is covered by
`testing/lint/cases/meta-runtime-invalid` and `test/lint/meta_runtime_test.cr`.
`expected.out` captured with `bin/krikri-capture-case` from ansible-core
2.21.6.
