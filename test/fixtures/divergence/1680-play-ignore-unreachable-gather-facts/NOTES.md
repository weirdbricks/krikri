Issue: https://github.com/weirdbricks/krikri/issues/1680

A play-level `ignore_unreachable:` was not applied to the implicit
`Gathering Facts` task: krikri halted the dead host there and exited 4,
while real ansible reports the gather `...ignoring`, counts it
ok+ignored, and keeps the host in the play (the debug task then runs).

Live-verified against ansible-core 2.21.6: `ignore_unreachable` is an
inherited FieldAttribute, so real's implicit setup task carries it just
like every other task and an ignored unreachable there never marks the
host unreachable.

Capture notes: same harness adaptations as
1680-ignore-unreachable-stays-in-play (`ansible_connection=ssh` because
the corpus forces `-c local`, the interpreter pin so the module exec is
the target's first ssh usage, `ANSIBLE_PIPELINING=True` for the
"Data could not be sent" lead).
