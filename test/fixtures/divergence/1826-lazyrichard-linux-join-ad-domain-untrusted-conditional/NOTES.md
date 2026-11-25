# #1826 - lazyrichard.linux_join_ad_domain: assert fails as an untrusted expression

- Issue: https://github.com/weirdbricks/krikri/issues/1826
- Role: `lazyrichard.linux_join_ad_domain` (rocky host, round `round29927194`)
- Class: output gap (the wording and the help paragraph of a failing `assert:`)

**What diverged.** The role's second preflight assert loops over
`that: "{{ item }} is defined and {{ item }}"`, a condition that begins and
ends with template delimiters but is not one whole template. Real renders
such a condition whole, then refuses to evaluate the rendered string because
templated output is untrusted, so the task fails with

```
[ERROR]: Task failed: Encountered untrusted template or expression.
...
Encountered untrusted template or expression.
Origin: .../tasks/validate.yml:11:9
...
Templates and expressions must be defined by trusted sources such as playbooks or roles, not untrusted sources such as module results.
```

krikri classified any delimiter-bearing condition as Jinja's delimiter parse
error instead, reporting

```
[ERROR]: Task failed: Syntax error in expression. Template delimiters are not supported in expressions: expected token ':', got '}'
```

and printing no help paragraph.

**Fixture.** The role's `tasks/main.yml`, `tasks/validate.yml` and
`defaults/main.yml` are copied verbatim (`defaults/main.yml` is what makes
`domain_name` defined-but-empty, the round's shape). The play runs the role
against localhost and the assert fails on its first evaluated item, so no
later task of the role runs. `expected.out` was captured from real
ansible-core 2.21.6.

**Fix.** `ConditionalEvaluator.multi_span_template_conditional?` mirrors
ansible's `is_possibly_all_template` (the `_starts_and_ends_with_jinja_delimiters`
check alone) minus the one-whole-template case, and assert's `that:` loop renders
those items first - so an undefined reference still fails as
`Error while evaluating conditional: '<x>' is undefined` - then fails them as
the trust check does. `ResultDisplay`'s assert chain adds the error class's
help paragraph after the Origin block.
