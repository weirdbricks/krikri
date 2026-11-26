# #1842 - barraponto.aws-vpc's bare `ec2_vpc:` is refused at load, not run

- Issue: https://github.com/weirdbricks/krikri/issues/1842
- Role: `barraponto.aws-vpc` (ubuntu host, round `logs___1795686235`, round29928201)
- Class: behavioural bug - exit code and block count differ (ansible rc=4
  with one output block, krikri rc=2 with a full PLAY RECAP)

**What diverged.** The role's `tasks/main.yml:3` spells the module bare:
`ec2_vpc:` - ansible-core's own VPC module in the pre-collections era,
dropped rather than migrated (amazon.aws shipped the split
`ec2_vpc_net`/`ec2_vpc_subnet`/... modules instead). It is in no current
amazon.aws or community.aws release, and ansible_builtin_runtime.yml
carries no redirect for it, so real refused the whole playbook at LOAD
time - rc=4, no PLAY output, only the `[ERROR]: couldn't resolve
module/action 'ec2_vpc'.` line and the task's Origin block (294 bytes
cold and warm).

The role deliberately leaves `aws_vpc_cidr_block` undefined (its
`vars/main.yml` sample is commented out), which real never reaches.

krikri instead ran the play: `Gathering Facts` succeeded, the task name
templated with `<< error 1 - 'aws_vpc_cidr_block' is undefined >>`, arg
finalization failed, and the run ended with a PLAY RECAP, a template-error
warning and rc=2 - five blocks where real printed one.

**Fixture.** The role's `tasks/main.yml` is copied verbatim from the
Galaxy install (v1.0); only the play is adapted to localhost. The rest of
the role (defaults/vars/meta/handlers) is not needed: real refuses the
role at its first task, before any of it is templated. `expected.out` was
captured from real ansible-core 2.21.6 by `bin/krikri-capture-case`.

**Fix.** `ec2_vpc` (bare, `ansible.builtin.`/`ansible.legacy.`, and the
`amazon.aws.`/`community.aws.` FQCN spellings - amazon.aws 12.1.0 and
community.aws 12.0.0 ship neither the module nor a routing entry for it)
joined `REMOVED_MODULE_TOMBSTONES`, so the parser refuses all five
spellings with real's own `[ERROR]` line and Origin block, rc=4, matching
the load-time refusal. The bare-name shape (no builtin module, no redirect
at all) is not covered by the issue #1763 redirect-chain rule, which needs
a builtin-runtime redirect target to prove a definitive miss.

Replayed in-process by
`test/integration/divergence_cases/1842-barraponto-aws-vpc-ec2-vpc.cr`.
