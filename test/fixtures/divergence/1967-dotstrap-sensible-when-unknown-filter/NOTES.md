# #1967 - dotstrap.sensible: an extra INJECT_FACTS_AS_VARS block for a when: that never compiled

- Issue: https://github.com/weirdbricks/krikri/issues/1967
- Role: `dotstrap.sensible` (round `logs___1795853943`, ubuntu, cold + warm)
- Class: output gap (extra deprecation block)

**What diverged.** The role's block task is guarded by
`when: ansible_user_shell | match(".*\/(bash|zsh)")`, and ansible-core 2.21.6
has no `match` FILTER (only a `match` test), so the clause fails with
"Syntax error in expression: No filter named 'match'." - identically in both
engines. Real ansible's Jinja engine resolves filter names while COMPILING the
expression, so the clause's `ansible_user_shell` name is never resolved and no
INJECT_FACTS_AS_VARS block prints. Krikri emitted the block for the fact read
its short-circuit pre-pass makes, landing a second, identical-looking
deprecation the round's cold and warm transcripts both flagged as extra.

The fix gates that pre-pass on the clause compiling: when the expression names
a filter or test nothing implements, the evaluation fails before any name is
read, exactly as real does.

**Fixture.** The role's failing block task, copied verbatim (the `setup`
include_vars task is dropped: both engines print the same block for its own
fact read there, and the shell vars file it loads depends on the running
user's shell). The module's params still template the role's own defaults,
which never resolve because the `when:` fails first.

`expected.out` was captured with `bin/krikri-capture-case` from ansible-core
2.21.6 (the corpus's pinned parity target).
