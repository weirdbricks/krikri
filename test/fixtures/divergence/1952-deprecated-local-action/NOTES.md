# #1952 - krikri-lint: missing deprecated-local-action rule

- Issue: https://github.com/weirdbricks/krikri/issues/1952
- Class: lint rule coverage (`deprecated-local-action` was absent from
  `--list-rules`, so parity.py filed its upstream triples as unimplemented)
- Reproduced on main `f85f2dffe` against ansible-lint 25.2.1 (really
  25.6.1) and krikri-lint 0.8.7.

**What diverged.** The playbook runs identically under real `ansible-playbook`
and `krikri-playbook` - same tasks, recap and mapping-form deprecation
warning - so this is a lint-only gap. ansible-lint reports
`deprecated-local-action` once per `local_action` task (no column) plus
`fqcn[action-core]` inside the directive's value, and no `no-free-form`;
krikri-lint had no rule for the directive at all, and treated `local_action`
as a module key, which both hid those fqcn matches and invented a
`no-free-form` match for the string form.

**Fixture.** The issue's playbook, verbatim. The engine transcript is
recorded here because the corpus replays whole playbook runs; the rule-level
repro is the lint case at `testing/lint/cases/deprecated-local-action.yml`,
where `testing/lint/parity.py` compares all seven triples against
ansible-lint. `expected.out` was captured with `bin/krikri-capture-case`
from ansible-core 2.21.6 (the corpus's pinned parity target).
