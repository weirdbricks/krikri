# #1644 - pgkehle.nvm's task tags name the reserved tag `all`

- Issue: https://github.com/weirdbricks/krikri/issues/1644
- Role: `pgkehle.nvm` (ubuntu host, round `logs___1795172676`, round29919554)
- Class: output gap (missing reserved-tagnames warning)

**What diverged.** `tasks/main.yml`'s "Clean artifact path" task carries
`tags: ["all"]`. ansible-core 2.21.6's `Taggable._load_tags` warns for any
tags value naming one of its reserved tags (`all`, `tagged`, `untagged`) -
`always`/`never` are ordinary tags there - with the tags value's own Origin
block. Real printed that block on stderr for every phase (cold, warm and
check); krikri printed nothing, so the round's PLAY RECAP block differed by
the whole warning (484 B vs 200 B).

**Fixture.** The role is trimmed to the failing task copied verbatim from the
round's `roles/pgkehle.nvm/tasks/main.yml`, and the play is the round's
`site.yml` adapted to localhost with `gather_facts: false`. `remote_base_dir`
is redirected into the scratch tree (the role's default is
`/opt/servers/node`) so the only task that runs - a `file: state: absent` on
a path that does not exist - cannot touch the machine.

**Fix.** `src/krikri/playbook_parser.cr` emits real's reserved-tagnames
warning (message plus Origin) at every place real loads tags: play, block
(before the block's children load), task/handler, import/include statements,
`roles:`/meta-dependency entries, and the include-family `apply: {tags:}`
mapping, which real builds only when the include actually runs.
