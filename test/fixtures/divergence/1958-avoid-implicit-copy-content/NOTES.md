# 1958 - krikri-lint: implement the avoid-implicit rule

- Issue: https://github.com/weirdbricks/krikri/issues/1958
- Split from #1874: `avoid-implicit` was missing from krikri-lint
  altogether, found by comparing `ansible-lint -L` against
  `krikri-lint --list-rules`.

## What diverged

The divergence is in the LINT tools, not in either engine.
`ansible-lint --nocolor -p cases/avoid-implicit.yml` reports

```
cases/avoid-implicit.yml:5: avoid-implicit: Avoid implicit behaviors
```

while `krikri-lint` reported nothing and its `--list-rules` had no
`avoid-implicit` entry. The fix is
`src/krikri_lint/rules/avoid_implicit.cr` plus the
`testing/lint/cases/avoid-implicit.yml` fixture that
`testing/lint/parity.py` now compares against upstream.

Upstream's matchtask flags a `copy` task whose `content` value is not a
Python str. A YAML mapping, a list, and a plain scalar that resolves to
null/bool/int/float all fail that test, while a Jinja expression is a
string at parse time even when the variable holds a mapping.

## What this case pins

The playbook is the issue's, with `dest:` moved into the case's scratch
directory. Both engines run it identically (`changed=1`), so the case pins
that real `ansible-playbook` executes the playbook krikri-playbook must
execute too - copy's handling of a mapping `content` carries no runtime
difference, only a lint match. `expected.out` is real ansible-core
2.21.6's transcript, captured with `bin/krikri-capture-case` (never from
krikri).
