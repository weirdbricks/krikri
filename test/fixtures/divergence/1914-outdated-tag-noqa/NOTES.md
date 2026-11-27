# 1914 - krikri-lint: warning[outdated-tag] for a legacy noqa tag

- Issue: https://github.com/weirdbricks/krikri/issues/1914
- Split from #1898: the `warning` rule family was missing from krikri-lint
  altogether.

## What diverged

The divergence is in the LINT tools, not in either engine.
`ansible-lint --nocolor -p cases/tasks/warning.yml` reports

```
cases/tasks/warning.yml:2: warning[outdated-tag]: Replaced outdated tag '301' with 'no-changed-when', replace it to avoid future errors (warning)
```

while `krikri-lint` reported no violations, and its `--list-rules` had no
`warning` family. The fix is `src/krikri_lint/rules/outdated_tag.cr` plus the
`testing/lint/cases/warning/tasks/main.yml` fixture that
`testing/lint/parity.py` now compares against upstream.

That fixture names legacy tag `305`, not the issue's `301`: upstream reports
each legacy tag once per run, and which of two files naming the same tag gets
the match depends on the iteration order of its lintable set (a Python set of
path-hashed objects, so it flips between runs). `301` already appears in
`testing/lint/cases/noqa-legacy-tag`, which would make the tree-wide parity
run disagree half the time on which file carries the match.

## What this case pins

The playbook is the one the issue reports from, with its `# noqa: 301`
comment intact and only the host adapted to localhost. That comment is inert
at runtime, so the transcript is identical on both engines: the case pins
that the lint-only tag never leaks into a play run, i.e. the playbook real
`ansible-playbook` executes with no mention of the tag is the playbook
krikri-playbook must execute too. `expected.out` is real ansible-core
2.21.6's transcript, captured with `bin/krikri-capture-case` (never from
krikri).
