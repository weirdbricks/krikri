# #1646 - t_woerner.ipareplica: a missing module interpreter ran the task

- Issue: https://github.com/weirdbricks/krikri/issues/1646
- Role: `t_woerner.ipareplica` (round29919650, ubuntu, cold+warm+check)
- Class: behaviour (a python-module task ran where real dies before any
  module code)

**What diverged.** The round's `Install - IPA client test` task (the
role's own `ipaclient_test` library module) ran on a target where the
role had just pinned `ansible_python_interpreter: /usr/bin/python2`, a
path the Ubuntu host does not have. Real ansible dies before the module
payload runs (rc 127, non-JSON stdout) and reports the
module-interpreter-not-found action failure; krikri's modules are
compiled binaries that never need python, so the task ran on and failed
inside the module instead.

The round's own shape is ssh-side (`module_stderr` then carries the
`Shared connection to <host> closed.` notice, the shell's line rides the
`-tt` pty into `module_stdout`), and the interpreter-missing path also
covers `command`/`shell`: their action plugins are thin wrappers around
`_execute_module('ansible.legacy.command'/'shell')`, so the payload is
python and real fails them exactly like any other module. Only `raw` and
`script` hand their payload straight to the connection's shell.

**Fixture.** That rule, replayed in-process: one `command:` task under
`-c local` with an inventory-pinned interpreter path no host has. Real
reports the failure block with the shell's not-found line on
`module_stderr` and an empty `module_stdout` (the ssh close-notice split
is the only difference from the round's transcript, and it cannot be
reproduced without a real sshd). The ssh-side shape is covered by
`test/integration/remote_interpreter_missing_test.cr`.

`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6.
