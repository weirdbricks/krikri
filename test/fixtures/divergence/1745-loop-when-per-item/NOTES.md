# #1745 - a looped task's when: is evaluated per item, never item-less

- Issue: https://github.com/weirdbricks/krikri/issues/1745
- Repro: a `with_sequence:` task (the generic `with_<lookup>:` loop form) on
  a dead ssh endpoint (the always-fail stub), with an item-dependent `when:`.

**Why it matters.** Carrying the probe's verdict into when_passes? is only
correct for a non-looped task: evaluating a looped task's clause item-less and
letting the first item consume that verdict skips item 1 where ansible runs
it. The probe therefore hands over every loop form, and this case pins the
per-item evaluation (item 1 dials and fails, item 2 skips).
