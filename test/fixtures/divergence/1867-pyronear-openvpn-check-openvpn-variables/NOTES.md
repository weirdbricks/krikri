# #1867 - an item-referencing when: that raises does not skip a failing loop

- Issue: https://github.com/weirdbricks/krikri/issues/1867
- Role: pyronear.openvpn (ubuntu), round `logs___1795714389`
- Class: behaviour - the task failed on ansible but skipped on krikri

**What diverged.** The role's first task loops over two literal templates of
undefined variables (`openvpn_ca_password`, `openvpn_server_dns`) and gates
the loop with `when: [item is none or item | length == 0]`. Real ansible
templates the loop list first, fails with `'openvpn_ca_password' is
undefined`, and the recap is `failed=1`. krikri treated the task as skipped
and ran on to the next task, where `openvpn_server_dns` failed inside a
command's arguments.

**Why krikri had it wrong.** `render_loop_items_strict_or_raise`'s rescue
took an item-rooted undefined reference in the `when:` (here `item` is
unbound because the loop list never rendered) as a unconditional skip. Real
only ends up skipping when the conditional evaluates to a clean `False` with
`item` unbound (definedness tests, `default()`); a conditional that itself
raises is displayed as its own `[ERROR]: A 'when' expression failed: ...`
block and the task then fails with the deferred loop error.

**Fix.** The skip now needs the same `when_tolerates_undefined?` gate the
loop-source path already used, and the conditional's own error block is
printed (stderr, as real defers it) before the loop error fails the task.

**Fixture.** The failing task is copied verbatim from the role's
`tasks/main.yml`; only the play wrapper is adapted so it runs on localhost.
`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6.
