# #1900 - adminsnzh.update_el8: a failing include's when: still warns

- Issue: https://github.com/weirdbricks/krikri/issues/1900
- Role: `adminsnzh.update_el8` (round `logs___1795725136`, rocky, cold + warm)
- Class: output gap (missing deprecation block)

**What diverged.** The role's block reaches
`include_tasks: rhel.yml` guarded by `when: ansible_lsb.id == 'RedHatEnterprise'`.
On the round's Rocky host gathering produced no lsb data, so the clause raised
"object of type 'dict' has no attribute 'id'" - both engines fail the include
and rescue it identically - but real ansible still printed the
INJECT_FACTS_AS_VARS block for the `ansible_lsb` read, ahead of its error, and
krikri printed nothing. Krikri holds a dynamic include's `when:` readings back
and flushes them only for hosts the include SKIPS (issue #974); a host whose
clause raised landed in neither the run nor the skip set, so the buffer was
dropped. `partition_by_when` now flushes it at the failure display point.

**Fixture.** The role's block and its three platform includes, with the
`lineinfile` task dropped (it rewrites `/etc/dnf/dnf.conf` and cannot run
in-process; it is not part of the failing path) and the guard's fact spelled
`ansible_env.KRIKRI_1900_MISSING_KEY` instead of `ansible_lsb.id`. The role's
own spelling only raises on a host whose `lsb_release` never ran - on a host
where it did, the same clause merely skips, which krikri already handled - so
the substitution keeps the same AttributeError on the same top-level fact read
while staying deterministic on every host (`ansible_env` exists everywhere and
cannot own that key). Nothing else about the failing task changes: the include
statement, its Origin columns (`:5:5` for the statement, `:6:11` for the
clause), the error text and the rescued recap all match the round.

`expected.out` was captured with `bin/krikri-capture-case` from ansible-core
2.21.6 (the corpus's pinned parity target).
