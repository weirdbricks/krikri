# #1922 - krikri-lint: syntax-check missed task parse errors

- Issue: https://github.com/weirdbricks/krikri/issues/1922
- Class: lint `syntax-check[specific]` coverage (the tag existed; this
  failure kind was not gated)
- Reproduced on main `f85f2dffe` against ansible-lint 25.2.1, ansible-core
  2.21.6 and krikri-lint 0.8.7 while verifying issue #1894.

**What diverged.** The playbook's task carries only task keywords (`name:`,
`become:`) and no module/action. Both engines refuse the load with the same
block - `[ERROR]: no module/action detected in task.` at the task mapping,
exit 4 - so the engine half of the repro was never the bug. ansible-lint
turns that load failure into a single `syntax-check[specific]` match and runs
no other rule on the file; krikri-lint reported only `name[play]` because its
`SyntaxCheck` gate modelled just an unresolvable module name and a missing
role entry, never a task `ModuleArgsParser` itself rejects.

**Fixture.** The issue's minimal playbook, verbatim, with the `inventory.ini`
pinned to the local interpreter (the failure happens at load, before any
host is contacted, but the corpus runs every case the same way).
`expected.out` was captured with `bin/krikri-capture-case` from ansible-core
2.21.6 (the corpus's pinned parity target).
