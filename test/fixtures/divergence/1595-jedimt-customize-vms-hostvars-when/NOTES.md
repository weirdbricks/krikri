# #1595 - jedimt.customize_vms: hostvars entry miss in `when:` names dict, not HostVarsVars

- Issue: https://github.com/weirdbricks/krikri/issues/1595
- Role: `jedimt.customize_vms` (rocky host, round `logs___1795085158`, round29918106)
- Class: output gap (strict-undefined wording in a `when:` condition)

**What diverged.** The role's first task gates on
`when: not hostvars['localhost']['skip_vm_check']`, and no inventory host
defines `skip_vm_check`. Real ansible fails the task with

```
A 'when' expression failed: Error while evaluating conditional: object of type 'HostVarsVars' has no attribute 'skip_vm_check'
```

while krikri printed `object of type 'dict' has no attribute
'skip_vm_check'` - same task, same rc.

**Fixture.** The role's `tasks/main.yml` is copied verbatim from
`jedimt.customize_vms` 1.0.1 (its `defaults/main.yml` supplies no vars).
The first task fails, so no later task can run. `expected.out` was captured
from real ansible-core 2.21.6 (1253 bytes of transcript).

**Fix.** The strict-undefined probe's operand walk blanked every quoted
literal before scanning for plain chains, turning the expression into
`hostvars[ ][ ]`; the chain walker could no longer see which bracket step
yielded the hostvars entry, so it fell back to the engine's plain 'dict'
label. `Krikri.plain_chain_operands` now keeps quoted bracket keys and only
skips matches that START inside a string literal, restoring the
HostVarsVars wording for both the quoted-key and dotted spellings.
