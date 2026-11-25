# #1800 - rgroten.docker: deprecation blocks printed in the wrong order

- Issue: https://github.com/weirdbricks/krikri/issues/1800
- Role: rgroten.docker (master)
- Class: check-mode output: the two deprecation blocks a whole-template
  `when:` raises are byte-identical to real, but printed in the opposite order

**What diverged.** The role's `tasks/main.yml:2-7` task gated on
`when: "{{ ansible_distribution == 'RedHat' }}"` triggers two deprecations at
the same Origin: `INJECT_FACTS_AS_VARS` (from reading `ansible_distribution`)
and "Conditionals should not be surrounded by templating delimiters" (from the
non-string result of templating the whole conditional). Real renders the
conditional first, so the fact block comes out first and the delimiters block
second; krikri decided the delimiters block before rendering and printed them
the other way round.

**Why krikri had it wrong.** The delimiters block was emitted before the
conditional was substituted, and it went out through the plain stderr funnel
while the fact block raised by the render was held by the task's deprecation
window (or the pre-upload probe's deferral scope), so the held fact block
replayed after it however early it was raised.

**Fix.** The block is now probed before the render and emitted after it, and
it is emitted through the same hold chain the fact/vars-dict blocks use, so
both replay in the order real raises them. The `until:`, `changed_when:`,
`failed_when:` and assert `that:` sites were reordered the same way, since
real templates every conditional before deprecating its delimiters.

**Fixture.** The role's failing task is copied verbatim; the condition is
false on this Ubuntu host, so `--check` touches nothing. `flags.txt` adds the
round's `--check`, `inventory.ini` pins the interpreter. `expected.out` was
captured with `bin/krikri-capture-case` from real ansible-core 2.21.6.
