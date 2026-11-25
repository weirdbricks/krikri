# #1805 - copy with force: false against an existing dest must not reject typo'd options

- Issue: https://github.com/weirdbricks/krikri/issues/1805
- Playbook: krikri-playbook-generator `000016-multi-copy-chaos.yml`
  ("Copy #16.0"), kpg class `copy: chaos` (`Hallucinate on t0:dest`,
  `Hallucinate on t0:group`, `WrongType on t1:suites`, ...)
- Class: output text - krikri failed the copy task with an
  unsupported-parameter rejection where real ansible reported ok, which
  also flipped the next play's `when: kpg_task_0 is succeeded` gate

**What diverged.** The generated task carries two invented options
(`dest_bogus:`, `group_bogus:`) next to `force: false` and a `dest:` that
already exists on the host (the generator image ships
`/tmp/kpg-work/dest-0444.txt` at mode 0444, a different content). Real
ansible prints

```
ok: [target -> target2]
```

while krikri failed the task with

```
Unsupported parameters for (ansible.legacy.copy) module: dest_bogus, group_bogus. ...
```

and only that failure's `...ignoring` kept the play going; the second play
then skipped its `when: kpg_task_0 is succeeded` task instead of running
it.

**Why krikri had it wrong.** Ansible's copy ACTION plugin reads the dest
stat first and takes its exists-and-not-force branch
(`copy.py:280-283`), returning before any transfer - so the copy MODULE,
whose argument spec is what rejects an unsupported option, never runs.
krikri's controller-side "the module never runs" gate only knew the
check-mode and equal-content shortcuts, and treated a `content:` copy as
always reaching the module, so the spec check fired on a task real never
validated; the plugin's own strict-bool gate had the same gap.

**Fix.** The controller gate and `plugins/copy.cr`'s plugin gate both
short-circuit when `force` is present and falsy (Ansible reads it through
`boolean(strict=False)`, default yes) and the dest is a readable local
file. The no-op's registered result also drops the `diff: []` key krikri
used to append: the action's early return discards `_copy_file`'s own
result dict, the only place a diff was ever seeded (live-verified vs
ansible-core 2.21.6 on both the `content:` and `src:` paths).

**Fixture.** The failing task is copied verbatim except that `dest:` and
`dest_bogus:` point at the case's own file (a case may not touch the
machine), `kpg_owner`/`kpg_group` are pinned in the play's vars instead of
`-e`, and `delegate_to` is dropped so it runs on localhost. The seed task
recreates the image's existing 0444 destination, and `Kpg successor` is
the round's `when: kpg_task_0 is succeeded` dependency. `expected.out` was
captured with `bin/krikri-capture-case` from real ansible-core 2.21.6.
