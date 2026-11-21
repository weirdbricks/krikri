Issue: https://github.com/weirdbricks/krikri/issues/1680

`ignore_unreachable` was only partly honored. A host whose unreachable
result was ignored stayed in krikri's "known unreachable" set (filled by
the pre-upload pass), so every later task was pre-booked UNREACHABLE
instead of being attempted, and the play-level `ignore_unreachable:` was
never applied to the implicit `Gathering Facts` task.

Live-verified against ansible-core 2.21.6: ansible only marks a host
unreachable for a FATAL result - an ignored one leaves the host in the
play and the next task tries the connection again. A controller-side
task (debug:, set_fact:, ...) then succeeds, while a connecting one
books its own unreachable. The implicit setup task inherits the play's
`ignore_unreachable:` like any other task, so it is reported
`...ignoring` and counted ok+ignored instead of halting the host.

Capture notes:

- the repro's inventory line, adapted for this harness: the corpus runs
  every case with `-c local`, so the dead host states
  `ansible_connection=ssh` itself.
- `ansible_python_interpreter=/usr/bin/python3` is pinned so the module
  exec is the target's first ssh usage: per 1688's notes, real then
  prints the plain single-block unreachable shape (the one krikri
  produces) rather than the interpreter-discovery `Task failed.` +
  `<<< caused by >>>` chain.
- `env.txt` pins `ANSIBLE_PIPELINING=True`, which is what makes real use
  the "Data could not be sent to remote host" lead krikri's transport
  produces (1688's notes).
