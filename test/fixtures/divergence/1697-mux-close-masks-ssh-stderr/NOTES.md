# #1697 - ssh transport failure reported as "Shared connection ... closed."

- Issue: https://github.com/weirdbricks/krikri/issues/1697
- Class: behavioural bug (both engines UNREACHABLE, exit 4; only the detail diverged)

**What diverged.** A task delegated to a dead endpoint reported

    Failed to connect to the host via ssh: Shared connection to 127.0.0.1 closed.

where real ansible-core 2.21.6 reported

    Failed to connect to the host via ssh: ssh: connect to host 127.0.0.1 port 1: Connection refused

The class and exit code already matched; only the ssh detail was lost.

**Fixture.** The issue's playbook and inventory verbatim. The delegate is the
issue's dead endpoint (127.0.0.1:1), and `ansible_connection=ssh` on it keeps
the corpus harness's own `-c local` from routing the delegated task through the
controller, so a real (refused) dial is what fails. `env.txt` pins
`ANSIBLE_PIPELINING=False` because a `raw:` task carries no module payload:
Ansible's ssh plugin can only ever take its plain "Failed to connect" lead
there, and an inherited `ANSIBLE_PIPELINING` would change krikri's lead instead.

**Root cause (two masking layers on the same run path).**

1. The plugin-staging listing (`SSHManager.exec_script`, the task's first
   remote operation) failed with the correct ssh stderr, but
   `upload_plugins_to_host` parsed its empty stdout as "no plugins staged" and
   carried on to rsync/scp. Those dials raced the dead master's control socket
   and answered `Shared connection ... closed.`, and the scp failure's text is
   what reached the unreachable msg. Fixed by raising the listing's own
   transport failure (`SSHManager::SshTransportFailureError`) before any
   transfer is attempted.
2. `raw:`'s pty shaping then rewrote the result's `stderr` to the synthesized
   ssh close notice - correct for a command that ran on a pty, wrong for a
   result whose transport never got there. An unreachable raw result now keeps
   ssh's own stderr.

The same masking existed on the warm path (plugin-state cache says the binary
is staged, so the resident daemon's spawn is the first dial): `spawn_daemon`
closed the dial's stderr, so its real error was dropped and the one-shot
fallback reported the mux notice. The daemon spawn now drains that stderr and
reports a connection-level handshake failure itself.
