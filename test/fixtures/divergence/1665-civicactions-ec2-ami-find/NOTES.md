# #1665 - CivicActions.ec2-800-53-deploy's first task uses the unresolvable ec2_ami_find

- Issue: https://github.com/weirdbricks/krikri/issues/1665
- Role: `CivicActions.ec2-800-53` (ubuntu host, round `logs___1795231613`, round29920530)
- Class: behavioural bug (exit code + load-time module-resolution refusal: message and Origin)

**What diverged.** `roles/CivicActions.ec2-800-53-deploy/tasks/main.yml` opens
with `ec2_ami_find` at "Check if there is already an encrypted AMI with growpart
disabled" (line 1) and later uses the removed `include:` action (line 12).
`ec2_ami_find` was deleted from ansible-core in 2.9 (renamed to
`ec2_ami_info`) and was never migrated into `amazon.aws` or `community.aws`, so
ansible-core refuses the whole playbook at LOAD time on that first task and
never reaches the `include:`:

```
[ERROR]: couldn't resolve module/action 'ec2_ami_find'. This often indicates a misspelling, missing collection, or incorrect module path.
Origin: <WORK>/roles/CivicActions.ec2-800-53-deploy/tasks/main.yml:1:3
```

krikri did not tombstone the name, ran past the first task and aborted on the
later `include:` instead, printing the removed-action message at a different
Origin with rc=1 where real exits 4.

**Fixture.** The role's `tasks/main.yml` is copied verbatim from
`CivicActions.ec2-800-53-deploy` (master) along with its `defaults/main.yml`;
only the play is adapted to localhost. `expected.out` was captured from real
ansible-core 2.21.6 (302 bytes, matching the round's cold/warm ansible
preamble size).

**Fix.** `ec2_ami_find` (bare, `ansible.builtin.` and `ansible.legacy.`
spellings) joins `REMOVED_MODULE_TOMBSTONES` in `src/krikri/module_registry.cr`:
the name is unresolvable on every controller - not even a routing entry
survives in any collection - so real refuses with the generic couldn't-resolve
wording, rc=4. No collection-qualified spelling is added because no collection
ever shipped the module.
