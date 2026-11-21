# #1683 - a bad ansible_ssh_executable is a FAILED controller error, not UNREACHABLE

- Issue: https://github.com/weirdbricks/krikri/issues/1683
- Repro: the issue's own inventory line (`ansible_ssh_executable=/nonexistent/ssh`)
  against a `ping:` task; no role or live host is involved - the ssh command
  line cannot even be spawned, so nothing ever dials anywhere (the `-c ssh`
  flag in flags.txt overrides the harness default `-c local`).

**What diverged.** ansible-core's ssh connection plugin wraps its
`subprocess.Popen([ssh, ...])` OSError in
`AnsibleError("Unable to execute ssh command line on a controller.")` and
FAILS the task with it: recap `failed=1`, exit 2, and an `[ERROR]: Task
failed:` block whose caused-by section carries the OSError repr
(`[Errno 2] No such file or directory: b'/nonexistent/ssh'`). krikri instead
booked a 255-shaped UNREACHABLE (exit 4) whose message named plain `ssh`
("ssh: No same file or directory") - the residue of scp relaying the missing
`-S` binary's exec failure through the upload error's `ssh: ` detail
extraction.

The same issue's other two shapes (the unreachable msg dropping every ssh
stderr line but the first, and the changed-host-key class/rc) need a live
sshd and are recorded in test/fixtures/divergence/live/cases.txt.
