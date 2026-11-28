# 1953 - krikri-lint: local_action is an action alias, not a module

- Issue: https://github.com/weirdbricks/krikri/issues/1953
- Split from #1876 (found by auditing `ansible-lint -L` against
  `bin/krikri-lint --list-rules`; no role in the corpus uses the keyword).

## What diverged

The divergence is in the LINT tools, not in either engine. For the
`local_action:` tasks below, `ansible-lint --nocolor -p -q` reports
`fqcn[action-core]` at 6:17 (the mapping's `module: debug` value) and 9:21
(the `debug` token of the string form), and no `no-free-form` at all. krikri-lint
reported neither fqcn match and a false `no-free-form ... (local_action)` on the
string form: `local_action`/`action` were missing from the lint task model's
keyword table, so `module_name` resolved to the literal directive keyword
instead of the module it names.

The fix teaches `LintTask` that `action:`/`local_action:` is an action alias
(`src/krikri_lint/task.cr`), so `fqcn[action-core]` resolves to the named
module at the value node ansible-lint reports, and `no-free-form` exempts it
(upstream reads the free form from the raw task under the RESOLVED action name,
which an alias task never carries as a key). `deprecated-local-action` itself
is filed separately.

## What this case pins

Both engines already agree at runtime on this playbook: the same two `ok`
tasks and the same DEPRECATION WARNING about using a mapping for `action`
(with the same `Origin:`/column-9 detail), so the replay pins that the
lint-only keyword never changes what the play executes or prints.
`expected.out` is real ansible-core 2.21.6's transcript, captured with
`bin/krikri-capture-case` (never from krikri).
