# #1599 - opendevshop.users: bare top-level fact read in `is defined` when clause

- Issue: https://github.com/weirdbricks/krikri/issues/1599
- Role: `opendevshop.users` 1.7.0-alpha4 (ubuntu host, round `logs___1795085158`)
- Class: output gap (missing INJECT_FACTS_AS_VARS blocks)

**What diverged.** `tasks/prepare-user.yml` gates three tasks on
`when: getent_passwd is defined`. The round's warm phase ran with the role's
`aegir` user already created by the cold phase, so the `getent` facts were
defined and every one of those clauses read the injected bare
`getent_passwd` fact - real ansible printed one INJECT_FACTS_AS_VARS block
per clause, Origin'd at the `when:` item (19:7, 25:7, 31:7). krikri printed
none of them; only the `set_fact` argument template at 17:29 warned.

**Fixture.** The role's `tasks/prepare-user.yml` is copied verbatim from the
round's role tree, trimmed right after the three `when:` clauses above (the
later tasks create users/groups on the host). `defaults/main.yml` is verbatim,
and `aegir_user_name` is `root` so the localhost `getent` lookups succeed the
way they did on the warm round host; `flags.txt` passes it as an extra var
because the defaults loaded through `vars_files` outrank play vars.
`expected.out` was captured from real ansible-core 2.21.6.

**Fix.** A whole-condition `is defined` test is answered leniently without
resolving the name, so the read never reaches the substitutor; the code that
compensates scanned the clause text only for `ansible_`-prefixed fact
spellings. The names now also come from the expression's own parse, so a bare
injected key like `getent_passwd` warns exactly like the prefixed spelling.
