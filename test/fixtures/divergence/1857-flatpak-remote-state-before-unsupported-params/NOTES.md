# #1857 - flatpak_remote reports a bad `state` before an unsupported parameter

- Issue: https://github.com/weirdbricks/krikri/issues/1857
- Playbook: krikri-playbook-generator `000027-multi-flatpak_remote-chaos.yml`
  ("Flatpak_remote #27.0"), kpg class
  `flatpak_remote: check mode, chaos` (`Hallucinate on t0:enabled`,
  `WrongType on t0:state`, ...)
- Class: output text - the task fails on both engines, but with a different
  message

**What diverged.** The generated task sets `state: 51` (an int where the
option wants `absent`/`present`) and also carries the hallucinated key
`enabled_bogus`. Real ansible prints

```
[ERROR]: Task failed: Module failed: value of state must be one of: absent, present, got: 51
```

while krikri printed

```
[ERROR]: Task failed: Module failed: Unsupported parameters for (community.general.flatpak_remote) module: enabled_bogus. Supported parameters include: enabled, executable, flatpakrepo_url, method, name, state.
```

and both failed results' `...ignoring` kept the rest of the play identical.

**Why krikri had it wrong.** AnsibleModule's validation walks the merged
argument spec in AnsibleModule's init steps, not in the order krikri's
plugin checked: `check_required_arguments`, then `_validate_argument_types`,
then `_validate_argument_values` (the `choices` check), and the
unsupported-parameters error is appended to the result's error list LAST
(`arg_spec.py`'s `UnsupportedError`). `basic.py` then fails with
`errors[0]` - so a bad value always outranks a typo'd key, and a missing
`name` outranks both. The plugin checked unsupported parameters first.

**Fix.** `plugins/flatpak_remote.cr` validates in real's order: required
arguments, bool conversion, `method`/`state` choices, and only then the
unsupported parameters. `method` before `state` follows the module's own
`argument_spec` declaration order (name, flatpakrepo_url, method, state,
enabled, executable). That reorder landed on main under issue #1858 (same
root cause, generated playbook `000028` exercising the required-vs-typo
tier); this directory keeps the issue #1857 playbook pinned as the case for
this report, whose tier is choices-vs-typo.

**Fixture.** The failing task is copied verbatim; only `delegate_to:
target2` is dropped so it runs on localhost, and the handler it notifies is
kept so the notify resolves. `expected.out` was captured with
`bin/krikri-capture-case` from real ansible-core 2.21.6 + community.general.
The task's validation failure happens before any `flatpak` lookup, so no
binary is needed.
