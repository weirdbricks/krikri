# juju4.lxdconfigure: Debug | ansible_facts['env']

- issue: https://github.com/weirdbricks/krikri/issues/1569
- role: juju4.lxdconfigure
- round dir: /home/labros/git_work/krikri-role-tester/logs___1795043292/juju4_lxdconfigure
- phase: cold (block 4)
- task: Debug | ansible_facts['env'] (the role's very first task,
  `roles/juju4.lxdconfigure/tasks/main.yml:3`)
- divergence: bytes differ (2775 B ansible, 345 B krikri)

## What diverged

The role prints the whole `ansible_facts['env']` dict, and real ansible's
`EnvFactCollector` copies the module process's `os.environ` wholesale, so the
transcript carries every variable the session exported (`SSH_CLIENT`,
`LS_COLORS`, `PWD`, `_`, the `BASH_FUNC_*` shell functions, ...). krikri
gathered a fixed six-name shortlist (`PATH`, `HOME`, `USER`, `SHELL`, `TERM`,
`LANG`) instead, so every other line ansible printed was missing.

## Why the case does not dump the whole dict

Every value of that dict is the environment of whoever ran the case, so a
transcript of the full dict can never be replayed - it differs between two
shells on the same machine, and between the capture and the replay. The case
therefore keeps the fact and asserts one variable that is in the environment of
both engines and is outside krikri's old shortlist: `ANSIBLE_NOCOLOR`, which
the corpus harness itself sets (`Krikri::DivergenceCase.env`). `default('absent')`
turns the pre-fix output (the key missing from the shortlist) into a stable
transcript instead of a template error.

`roles/juju4.lxdconfigure/` is the role tree the round ran, so the real
`var: ansible_facts['env']` YAML is in the case even though `playbook.yml`
reads one key of the fact.

`expected.out` was captured from real ansible-core 2.21.6 with
`bin/krikri-capture-case`; `inventory.ini` pins the interpreter on the
`[local]` host, which is the only spelling both engines read alike.
