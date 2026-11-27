# #1907 - idealista.prometheus_mysqld_exporter-role: when: compile error

- Issue: https://github.com/weirdbricks/krikri/issues/1907
- Role: `idealista.prometheus_mysqld_exporter-role` (round `logs___1795725136`, ubuntu, cold + warm)
- Class: output gap (wrong conditional-error wording + an extra warning block)

**What diverged.** The role's `MYSQLD_EXPORTER | Download package` task
guards itself with `... or mysqld_exporter_check|failed or "mysqld_exporter,
version {{ mysqld_exporter_version }}" not in ...`. `failed` is a test, not
a filter, so Jinja rejects the expression while compiling it. Real ansible
words that `A 'when' expression failed: Syntax error in expression.
Template delimiters are not supported in expressions: No filter named
'failed'.` - it appends the delimiter sentence to any expression syntax
error whose RAW clause contains a template start string, without skipping
string literals. krikri only produced the colon form, because its delimiter
pre-reject looks for a `{{ }}` outside a quoted span and this one sits
inside `"..."`. It also printed the `Jinja constant strings should not
contain embedded templates` warning, which real emits only while RENDERING
the expression - something a compile failure never reaches.

**Fixture.** The role's failing task verbatim, with the play supplying the
role defaults the clause reads plus the registered result of the role's own
preceding `command: mysqld_exporter -version` probe (which is what makes
`|failed` even look plausible). The module is never reached - the clause
fails to compile first - so nothing is mutated.

`expected.out` was captured with `bin/krikri-capture-case` from ansible-core
2.21.6 (the corpus's pinned parity target).
2.21.6 (the corpus's pinned parity target).
