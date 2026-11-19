# rooland-provisioning.atom-editor: Install Atom editor

Extracted by `krikri-role-tester extract-repro` from one divergent round of the
real-host differential run, so the repro replays as a test instead of living in a
closed issue.

- issue: #1587
- role: rooland-provisioning.atom-editor
- round dir: /home/labros/git_work/krikri-role-tester/logs___1795043292/rooland-provisioning_atom-editor
- phase: cold (block 4)
- task: Install Atom editor
- divergence: task results differ: ansible=[fatal] krikri=[skipping]
- first differing line:

  ```
  ansible: [ERROR]: Task failed: Module failed: Failed to find required executable "brew" in paths: /usr/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin
  krikri:  skipping: [localhost]
  ```

- round versions: krikri 0.9.2939, ansible-playbook [core 2.21.6]

## Corpus fit

`expected.out` is a fresh capture of `playbook.yml` from real ansible-core
2.21.6 over this directory, in `--check` mode (`flags.txt`) like the round.
`<WORK>` stands in for the case's scratch directory, and the round's `testhost`
inventory alias became `localhost`.

Three adaptations keep the transcript about THIS divergence:

- `gather_facts: false`: the task needs no facts, and ansible-core 2.21.6
  gathers them without printing a task (krikri still prints its Gathering
  Facts block, a separate divergence).
- a play-level `environment.PATH`: the failure message quotes the searched
  directory list, so an unpinned PATH would record the capturing developer's
  PATH.
- `inventory.ini` pins the interpreter on the `[local]` host, the only
  spelling both engines read alike.

`roles/rooland-provisioning.atom-editor/` is the role tree the round ran, so
the real YAML is in the case even though `playbook.yml` only runs the one
divergent task.

Capture it with:

    bin/krikri-capture-case test/fixtures/divergence/1587-rooland-provisioning-atom-editor-install-atom-editor

The task body was lifted verbatim from `work/roles/rooland-provisioning.atom-editor/tasks/main.yaml:2`; its parameters are
verbatim, so any role variables they reference are not defined here.

## Divergent block

### ansible

```
TASK [Install Atom editor] *****************************************************
[ERROR]: Task failed: Module failed: Failed to find required executable "brew" in paths: /usr/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin
Origin: <WORK>/roles/rooland-provisioning.atom-editor/tasks/main.yaml:2:3

1 ---
2 - name: Install Atom editor
    ^ column 3

fatal: [localhost]: FAILED! => {"changed": false, "msg": "Failed to find required executable \"brew\" in paths: /usr/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"}
...ignoring

```

### krikri

```
TASK [Install Atom editor] *****************************************************
skipping: [localhost]

```
