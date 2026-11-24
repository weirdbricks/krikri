# #1763 - dtorresf.backups3's bare `aws_s3:` is refused at load, not skipped

- Issue: https://github.com/weirdbricks/krikri/issues/1763
- Role: `dtorresf.backups3` (ubuntu host, round `logs___1795546590`, round29925822)
- Class: behavioural bug (a task ran or was skipped on one side only)

**What diverged.** The role's `tasks/main.yml:19` spells the module bare:
`aws_s3:` (removed from amazon.aws 2.0 in favour of `s3_object`).
ansible-core's builtin runtime still redirects that bare spelling onto
`amazon.aws.aws_s3`, and the round's controller had no usable amazon.aws
and nothing beside the playbook, so real refused the whole playbook at
LOAD time - rc=4, no PLAY output, only the
`[ERROR]: couldn't resolve module/action 'aws_s3'.` line and the task's
Origin block (290 bytes cold and warm):

```
[ERROR]: couldn't resolve module/action 'aws_s3'. This often indicates a
         misspelling, missing collection, or incorrect module path.
Origin: <WORK>/roles/dtorresf.backups3/tasks/main.yml:19:3
```

krikri instead ran the play, skipped the task with a `uses unimplemented
plugin: aws_s3` line and exit 4 at the end - ten output blocks where real
printed one.

**Fixture.** The role's `tasks/main.yml` and `defaults/main.yml` are
copied verbatim from the Galaxy install (1.0.x master); only the play is
adapted to localhost. `fixture-collections/` is a file-less `amazon.aws`
stub, put on the collection search path through `env.txt`: the round's
controller had an amazon.aws tree that ships no module files, and this
box's system amazon.aws copy would otherwise resolve `aws_s3` (via its own
`aws_s3 -> s3_object` redirect) and run it against S3. It is NOT placed
playbook-adjacent (`collections/`), because the fix deliberately treats
that tree as play input that makes real resolve the name; the case pins
the controller state where real refuses. `expected.out` was captured from
real ansible-core 2.21.6 by `bin/krikri-capture-case`.

**Fix.** The parser refuses a BARE spelling whose ansible-core
builtin-runtime redirect chain is a definitive miss against krikri's baked
collection tables, with real's own `[ERROR]` line and Origin block. Two
escapes keep it from refusing where real resolves: the collection
shipping in the PLAYBOOK-ADJACENT `collections/` tree (the layout a
round's role dependencies land in, e.g. the `ec2_vpc_peer` case from issue
#865) and the task/play naming it in `collections:`. Undecidable chains
stay on the graceful unavailable-module flow (issue #1744's
`gcp_compute_disk`), and FQCNs are never refused this way.
`CollectionIndex.bare_resolution` also stops turning an undecidable
redirect chain into a `false` verdict.

Replayed in-process by
`test/integration/divergence_cases/1763-dtorresf-backups3-aws-s3.cr`.
