# dorancemc.ansible_nagioscore: Install rrdtool packages

- issue: #1593
- role: dorancemc.ansible_nagioscore
- round dir: /home/labros/git_work/krikri-role-tester/logs___1795085158/dorancemc_ansible_nagioscore
- phase: cold (block 13)
- task: Install rrdtool packages
- divergence: task results differ: ansible=[changed] krikri=[fatal]
- first differing line:

  ```
  ansible: changed: [testhost]
  krikri:  [ERROR]: Task failed: A 'when' expression failed: Error while evaluating conditional: 'install_pnp4nagios' is undefined
  ```

- round versions: krikri 0.9.2959, ansible-playbook [core 2.21.6]

## Root cause

The role keeps `install_pnp4nagios` in `defaults/main/nagios/vars.yaml`, one
level below `defaults/main/`. ansible-core's `DataLoader._get_dir_vars_files`
walks a role's `defaults/main/` (and `vars/main/`) tree recursively, so the
name is an ordinary role default there; krikri only read the top level of that
directory, so the default was undefined and the role's own
`when: install_pnp4nagios | bool` aborted the play (exit 2 where ansible
exits 0).

## Corpus fit

`playbook.yml` runs the role trimmed to the two tasks that lead to the
divergent one: the role's own "Set OS dependent variables" (it loads
`rrdtool_packages` from `vars/Debian.yaml`) and the `Install rrdtool packages`
task from `tasks/Debian.yaml`, both verbatim. The rest of the role installs
nagios, apache, postfix and the services, which cannot run in-process.

`roles/dorancemc.ansible_nagioscore/` is that trimmed role: the real
`defaults/` tree (the bug's trigger), `vars/`, and `tasks/{main.yml,vars.yml}`.
The role's `tests/` directory is left out: it carries a symlink pointing back
at the role, which a recursive copy cannot follow.

`flags.txt` runs the case in `--check` mode, like the round's own check phase,
so the apt task only simulates and never installs anything.

`expected.out` was captured from real ansible-core 2.21.6 with
`bin/krikri-capture-case` over this directory: ansible evaluates the default
and the task reports `changed`, where the pre-fix engine aborted on the
undefined name.

## Divergent block

### ansible

```
TASK [dorancemc.ansible_nagioscore : Install rrdtool packages] *****************
changed: [testhost]

TASK [dorancemc.ansible_nagioscore : Add apache user to nagios group] **********
changed: [testhost]

```

### krikri

```
TASK [dorancemc.ansible_nagioscore : Install rrdtool packages] *****************
[ERROR]: Task failed: A 'when' expression failed: Error while evaluating conditional: 'install_pnp4nagios' is undefined

Task failed.
Origin: <WORK>/roles/dorancemc.ansible_nagioscore/tasks/Debian.yaml:47:3

45     cache_valid_time: 3600
46
47 - name: Install rrdtool packages
     ^ column 3

<<< caused by >>>

A 'when' expression failed: Error while evaluating conditional: 'install_pnp4nagios' is undefined
Origin: <WORK>/roles/dorancemc.ansible_nagioscore/tasks/Debian.yaml:53:9

51     update_cache: true
52     cache_valid_time: 3600
53   when: install_pnp4nagios | bool
           ^ column 9

fatal: [testhost]: FAILED! => {"changed": false, "msg": "Task failed: A 'when' expression failed: Error while evaluating conditional: 'install_pnp4nagios' is undefined"}

PLAY RECAP *********************************************************************
testhost                   : ok=10   changed=6    unreachable=0    failed=1    skipped=0    rescued=0    ignored=0
```
