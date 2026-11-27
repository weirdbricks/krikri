# #1909 - jedimt.nebulon_manage_volumes' `nebulon.nebulon_on.*` FQCNs are refused at load

- Issue: https://github.com/weirdbricks/krikri/issues/1909
- Role: `jedimt.nebulon_manage_volumes` (rocky host, round `logs___1795725136`, round29928793)
- Class: behavioural bug - exit code and block count differ (ansible rc=4
  with one output block, krikri rc=2 with a full PLAY RECAP)

**What diverged.** The role's `tasks/main.yml:4` runs
`nebulon.nebulon_on.neb_npod_info`. The role's `meta/main.yml` declares no
`collections:` and nothing installed `nebulon.nebulon_on`, so real's loader
found no such collection and refused the whole playbook at LOAD time - rc=4,
no PLAY output, only the `[ERROR]: couldn't resolve module/action ...` line
plus the task's Origin block (328 bytes cold and warm). The role leaves
`npod_name` undefined on purpose, which real never reaches.

krikri treated an FQCN whose `namespace.collection` its captured tables know
nothing about as undecidable and ran the play: `Gathering Facts` succeeded,
the task's `name:` argument failed to finalize on `npod_name` and the run
ended with a PLAY RECAP and rc=2 - five blocks where real printed one.

**Fixture.** The role's `tasks/main.yml` is copied verbatim from the Galaxy
install (v1.0.5); only the play is adapted to localhost. `expected.out` was
captured from real ansible-core 2.21.6 by `bin/krikri-capture-case`.

**Fix.** The parser now refuses an FQCN under a collection the captured
environment never saw at all (`CollectionIndex.known_collection?`), unless
the playbook-adjacent `collections/ansible_collections` tree ships it (play
input, where a round's role dependencies land). That is real's own
load-time miss: no installed collection can resolve the name. A collection
the capture DID see - even with routing/version data only - stays
undecidable and keeps the graceful unavailable-module flow, since the
controller real runs on has it installed (kubernetes.core, issue #1155).
`ansible.*` collections are core-provided and never refused.

Replayed in-process by
`test/integration/divergence_cases/1909-jedimt-nebulon-manage-volumes-neb-npod-info.cr`.
