# juju4.lxdconfigure: Debug | ansible_facts['env']

- issue: https://github.com/weirdbricks/krikri/issues/1584
- role: juju4.lxdconfigure
- round dir: `logs___1795043292/juju4_lxdconfigure`
- phase: check (block 4)
- task: Debug | ansible_facts['env'] (the role's very first task,
  `roles/juju4.lxdconfigure/tasks/main.yml:3`)
- divergence: bytes differ (2775 B ansible, 345 B krikri)

## What diverged

The role prints the whole `ansible_facts['env']` dict. Issue #1569 made
krikri copy its whole process environment into the fact, so the surviving
difference was `PWD`: real ansible runs the module through `sh -c`, and a
shell resets `PWD` to the module process's own working directory, while
krikri execs its local plugin binary directly and handed it the controller's
inherited - stale - `PWD`. The replay printed the controller's inherited
directory where real ansible printed the case's scratch directory.

## Why the case asserts one key

Every value of that dict is the environment of whoever ran the case, so a
transcript of the full dict can never be replayed (see 1569's NOTES.md).
`PWD` is the one value that is both stable across machines and outside the
shortlist: real ansible prints the case's working directory, which the
transcript normalizes to `<WORK>`.

`roles/juju4.lxdconfigure/` is the role tree the round ran, so the real
`var: ansible_facts['env']` YAML is in the case even though `playbook.yml`
reads one key of the fact.

`expected.out` was captured from real ansible-core 2.21.6 with
`bin/krikri-capture-case`; `inventory.ini` pins the interpreter on the
`[local]` host, which is the only spelling both engines read alike.
