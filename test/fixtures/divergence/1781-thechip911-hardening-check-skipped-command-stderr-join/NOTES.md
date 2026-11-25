# #1781 - thechip911.hardening: check mode diverges from real ansible

- Issue: https://github.com/weirdbricks/krikri/issues/1781
- Role: `thechip911.hardening` (ubuntu host, round `round29925782`)
- Class: check-mode behaviour - a task real ansible fails on, krikri passed

**What diverged.** In the round's `--check` phase real ansible failed the
role's `sshconfig.yml` "Set ssh version as fact" task and krikri did not.
The task reads a registered `command:` result:

```yaml
ssh_installed_version: "{{ ssh_version.stderr | regex_search('^OpenSSH_([0-9+].[0-9]+)', '\\1') | join('.') | float }}"
```

Under `--check` the preceding `command:` is skipped, so its registered
result has no `stderr` key: real ansible resolves `ssh_version.stderr` to
None, `regex_search` finds no match (None again) and `join` raises Python's
`TypeError: 'NoneType' object is not iterable`, which ansible reports as:

```
The filter plugin 'ansible.builtin.join' failed: 'NoneType' object is not iterable
```

krikri's `join` filter coerced every non-array operand to `[]` through
`as_array`, so the whole expression resolved to an empty string and the task
reported `ok` - exit 2 for real ansible versus a run krikri continued past
the failure point.

**Fix.** `join` in `src/krikri/filters/filter_dispatch.cr` now iterates the
operand the way Jinja2's `do_join` does (str per character, dict over keys)
and raises Python's TypeError wording for None/int/bool/float (live-verified
against ansible-core 2.21.6). The same leniency also hid `join` of a string
or dict in the fallback path, which is now correct too.

**Why the play is only this task.** The round's own krikri `--check`
transcript died at "Gathering Facts" with an SSH connection timeout (the
host was gone; `run.log` records the plugin-upload retries and a later
`package time: guest read failed ... Connection timed out`), so the recorded
diff never reached the task that diverges. The play is the role's
`sshconfig.yml` first two tasks verbatim, run with `--check`, which is the
trigger.
