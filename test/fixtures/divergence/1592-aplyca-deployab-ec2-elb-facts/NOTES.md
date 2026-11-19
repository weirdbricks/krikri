# #1592 - Aplyca.deployab's first unresolvable module is ec2_elb_facts, not ec2_remote_facts

- Issue: https://github.com/weirdbricks/krikri/issues/1592
- Role: `Aplyca.deployab` (ubuntu host, round `logs___1795085158`, round29918091)
- Class: output gap (load-time module-resolution refusal: name and Origin)

**What diverged.** The role's `tasks/main.yml` names two modules no current
controller can resolve: `ec2_elb_facts` at "Get ELB facts" (line 13) and
`ec2_remote_facts` at "Get Instance AMI facts" (line 24). ansible-core
refuses the playbook at LOAD time for the FIRST one it cannot resolve and
never reaches the second, printing

```
[ERROR]: couldn't resolve module/action 'ec2_elb_facts'. ...
Origin: <WORK>/roles/Aplyca.deployab/tasks/main.yml:13:3
```

krikri tombstoned only `ec2_remote_facts` (Aplyca.EC2Describe, round71000),
ran past the first refusal and reported the LATER name and Origin block -
same rc=4 and same shape, different name and position.

**Fixture.** The role's `tasks/main.yml` is copied verbatim from
`Aplyca.deployab` 1.0.4 along with its `defaults/main.yml`; only the play is
adapted to localhost. `expected.out` was captured from real ansible-core
2.21.6 (267 bytes, matching the round's cold/warm ansible preamble).

**Fix.** `ec2_elb_facts` (bare, `ansible.builtin.`, `ansible.legacy.` and
`community.aws.` spellings) joins `REMOVED_MODULE_TOMBSTONES` in
`src/krikri/module_registry.cr`: community.aws deprecated the name in 2.0.0
with `removal_version` 3.0.0 and ships neither a module nor a routing entry
for it since, while ansible-core's builtin runtime still redirects the bare
spelling onto `community.aws.ec2_elb_facts`, so real refuses with the generic
couldn't-resolve wording on every current controller.
