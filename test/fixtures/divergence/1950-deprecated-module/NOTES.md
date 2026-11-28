# 1950 - krikri-lint: implement the deprecated-module rule

- Issue: https://github.com/weirdbricks/krikri/issues/1950
- Split from #1877: `deprecated-module` was missing from krikri-lint
  altogether, found by comparing `ansible-lint -L` against
  `krikri-lint --list-rules`.

## What diverged

The divergence is in the LINT tools, not in either engine.
`ansible-lint --nocolor -p cases/deprecated-module.yml` reports

```
cases/deprecated-module.yml:5: deprecated-module: Deprecated module. docker
```

while `krikri-lint` reported nothing and its `--list-rules` had no
`deprecated-module` entry. The fix is
`src/krikri_lint/rules/deprecated_module.cr` plus the
`testing/lint/cases/deprecated-module.yml` fixture (with the
`testing/lint/cases/library/docker.py` stub module upstream needs for the
deprecated name to resolve) that `testing/lint/parity.py` now compares
against upstream.

Upstream hand-keeps the deprecated module list instead of reading ansible's
deprecation metadata, so the rule mirrors that list as data.

## What this case pins

The playbook is the issue's, with the same stub `library/docker.py` beside
it so the deprecated module name resolves and the task actually executes.
Both engines run it identically (`ok=1 changed=0`), so the case pins that
real `ansible-playbook` executes the playbook krikri-playbook must execute
too - the deprecated module carries no runtime difference, only a lint
match. `expected.out` is real ansible-core 2.21.6's transcript, captured
with `bin/krikri-capture-case` (never from krikri).
