# 1899 - AgePartnership.selinux (via its AgePartnership.reboot dependency)

- Issue: https://github.com/weirdbricks/krikri/issues/1899
- Role: `AgePartnership.selinux` (ubuntu), round round29928771, warm phase
- Task: `AgePartnership.reboot : Reboot host`, from the role dependency the
  selinux role runs twice per cold run.

## What diverged

The warm phase's `Gathering Facts` was UNREACHABLE under krikri
(`kex_exchange_identification: read: Connection reset by peer`, exit 4) where
real ansible gathered fine. The host was still rebooting: the role's reboot
task is `shell: sleep 2 && shutdown -r now` with `async: 1, poll: 0`, and real
ansible's `async_wrapper` enforces `async:` on the target itself - it SIGKILLs
the module's whole process group when the second is up, so the shell dies
during its `sleep 2` and the host is never rebooted (its job file keeps
`{"msg": "Timeout exceeded", "failed": true, "child_pid": <pid>}`). krikri only
enforced the budget in its controller-side poll loop, which a `poll: 0` job
never enters, so the shutdown really ran and the next phase's first connection
could land in the reboot.

## What this case pins

The play is the role's reboot task verbatim, with only the shutdown swapped for
a marker file so it can run in-process, plus a pause that outlives the job's
one-second budget and a `stat:` of the marker. Real ansible prints
`rebooted=False` - the job was killed before its second command ran - and
printed `rebooted=True` under krikri before the fix. The task's own result is
identical on both engines (`changed: [localhost]`), so only the side effect
separates them; giving the marker a `$HOME`-relative path keeps the case inside
its scratch tree.

`playbook.yml` is the input; `expected.out` is real ansible-core 2.21.6's
transcript, captured with `bin/krikri-capture-case`. The remote half of the
same fix (the target-side worker's timer, and dropping the synthetic terminal
that let a plugin `setsid` out of the kill's process group) is covered by
`test/integration/async_timeout_output_shape_test.cr`, which runs its ssh case
against the suite's throwaway sshd.
