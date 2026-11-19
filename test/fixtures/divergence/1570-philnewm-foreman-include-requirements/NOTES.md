# #1570 - philnewm.foreman: imported role missing inside an included file

- Issue: https://github.com/weirdbricks/krikri/issues/1570
- Role: `philnewm.foreman` (ubuntu host, round `logs___1795043292`, cold block 9)
- Class: output gap (same failure, different transcript and result shape)

Extracted by `krikri-role-tester extract-repro` from one divergent round of the
real-host differential run, so the repro replays as a test instead of living in a
closed issue.

- round dir: /home/labros/git_work/krikri-role-tester/logs___1795043292/philnewm_foreman
- phase: cold (block 9)
- task: Include requirements
- divergence: bytes differ (671 B ansible, 337 B krikri)
- first differing line:

  ```
  ansible: [ERROR]: The role 'theforeman.operations.puppet_repositories' was not found in: <WORK>/roles:/home/labros/.ansible/roles:/usr/share/ansible/roles:/etc/ansible/roles:<WORK>
  krikri:  fatal: [localhost]: FAILED! => {"changed": false, "include": "repo_setup.yml", "reason": "The role 'theforeman.operations.puppet_repositories' was not found in: <WORK>/roles:/home/labros/.ansible/roles:/usr/share/ansible/roles:/etc/ansible/roles:<WORK>"}
  ```

- round versions: krikri 0.9.2939, ansible-playbook [core 2.21.6]

**What diverged.** The role's `present.yml` runs `include_tasks: repo_setup.yml`,
whose first task is a static `import_role:` naming
`theforeman.operations.puppet_repositories`, which is not installed. Ansible
2.21 fails the include task itself: one `[ERROR]:` block on stdout with the
Origin pointing at the included file, then a `fatal:` line with the message
under `msg`, then the play recap - all before the message is repeated. krikri
instead printed the older wrapped three-message block on stderr plus a
`changed/include/reason` result dump, so the block landed after the recap and
the fatal line looked nothing like Ansible's.

**Fixture.** The role's `include_tasks: repo_setup.yml` chain, verbatim, with
the play adapted to run against localhost. The play has to include the role file
*dynamically*: an `import_role:` written directly in the play fails while the
playbook is loaded, before `TASK` is printed, which is a different transcript
(no recap at all) than the runtime failure this case records.

`expected.out` is the captured transcript of `playbook.yml` from real
ansible-core 2.21.6 (`bin/krikri-capture-case`); `roles/philnewm.foreman/` is
the role tree the round ran, so the real YAML is in the case.
`inventory.ini` pins the interpreter on the `[local]` host, the only spelling
both engines read alike.

## Divergent block

### ansible

```
TASK [Include requirements] ****************************************************
[ERROR]: The role 'theforeman.operations.puppet_repositories' was not found in: <WORK>/roles:/home/labros/.ansible/roles:/usr/share/ansible/roles:/etc/ansible/roles:<WORK>
Origin: <WORK>/roles/philnewm.foreman/tasks/repo_setup.yml:6:11

4   become: true
5   ansible.builtin.import_role:
6     name: theforeman.operations.puppet_repositories
            ^ column 11

fatal: [localhost]: FAILED! => {"changed": false, "msg": "The role 'theforeman.operations.puppet_repositories' was not found in: <WORK>/roles:/home/labros/.ansible/roles:/usr/share/ansible/roles:/etc/ansible/roles:<WORK>"}

```

### krikri

```
TASK [Include requirements] ****************************************************
fatal: [localhost]: FAILED! => {"changed": false, "include": "repo_setup.yml", "reason": "The role 'theforeman.operations.puppet_repositories' was not found in: <WORK>/roles:/home/labros/.ansible/roles:/usr/share/ansible/roles:/etc/ansible/roles:<WORK>"}

```
