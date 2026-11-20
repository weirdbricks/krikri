# #1651 - pgkehle.nvm: the reserved-tagnames warning was missing

- Issue: https://github.com/weirdbricks/krikri/issues/1651
- Role: `pgkehle.nvm` v3.0.0, `tasks/main.yml:176-180` ("Clean artifact path")
- Class: check-mode output (a missing `[WARNING]` block)

**What diverged.** Under `--check` real ansible printed

```
[WARNING]: Found reserved tagnames in tags: ['all'], we do not recommend
doing this as it might give unexpected results
Origin: <WORK>/roles/pgkehle.nvm/tasks/main.yml:9:9
...
9   tags: ["all"]
          ^ column 9
```

while krikri printed nothing: it parsed `tags:` but never reproduced
ansible-core's `Taggable._load_tags` warning for the reserved words
`tagged`/`all`/`untagged`.

**Why.** Every Taggable object (play, block, task, roles: entry,
import_tasks: line) warns once when its loaded tags name a reserved
word. The Origin points at the tags VALUE node - the opening bracket of
a flow list, the first item's line of a block list, the scalar itself
otherwise - not at the `tags:` key, and the source excerpt plus caret
follow `_error_utils.SourceContext` (live-verified vs 2.21.6).

**Fixture.** The role's task YAML verbatim (the play supplies
`remote_base_dir` so the `file:` path stays inside the scratch tree),
on `--check` (`flags.txt`).

`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6.
