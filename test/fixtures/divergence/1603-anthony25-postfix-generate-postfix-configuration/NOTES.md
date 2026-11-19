# Anthony25.postfix: Generate Postfix configuration

Extracted by `krikri-role-tester extract-repro` from one divergent round of the
real-host differential run, so the repro replays as a test instead of living in a
closed issue.

- issue: #1603
- role: Anthony25.postfix
- round dir: /home/labros/git_work/krikri-role-tester/logs___1795085158/Anthony25_postfix
- phase: cold (block 13)
- task: Generate Postfix configuration
- divergence: task results differ: ansible=[changed,changed] krikri=[failed,changed]
- first differing line:

  ```
  ansible: changed: [localhost] => (item=main.cf)
  krikri:  [ERROR]: Task failed: Error rendering template: No filter named 'ansible.utils.ipwrap' found.
  ```

- round versions: krikri 0.9.2959, ansible-playbook [core 2.21.6]

## Corpus fit

`expected.out` is the ansible side of that one block: what the round itself proves,
with `<WORK>` standing in for each engine's playbook directory in the round and the
round's `testhost` inventory alias rewritten to `localhost`. The banner lost
its `TASK [<role> : ...]` prefix.

krikri's replay (`test/integration/divergence_corpus_test.cr`) compares a case's
whole transcript, and only real ansible may produce one
(`test/fixtures/divergence/README.md`). Capture it from this directory with the
checkout's capture tool (`bin/krikri-capture-case`, or its predecessor
`scripts/capture_divergence_case.sh`):

    bin/krikri-capture-case test/fixtures/divergence/1603-anthony25-postfix-generate-postfix-configuration

That overwrites `expected.out` with the full transcript of `playbook.yml` (real
ansible 2.21.6, plus `--check` from `flags.txt` when the case has one), after which
the case replays and only needs listing in `DIVERGENCE_CASES` and its own `it`
block. `inventory.ini` pins the interpreter on the `[local]` host, which is the
only spelling both engines read alike. A file the task reads from a `~` or
relative path (the role or its own earlier tasks created it in the round) is not
in the case yet: copy it in before capturing, or the transcript pins a
file-not-found instead of the divergence.

`roles/Anthony25.postfix/` is the role tree the round ran, so the real YAML is in the case
even when `playbook.yml` only runs the one divergent task.

The task body was lifted verbatim from `work/roles/Anthony25.postfix/tasks/configure.yml:25`; its parameters are
verbatim, so any role variables they reference are not defined here.

## Divergent block

### ansible

```
TASK [Generate Postfix configuration] ******************************************
changed: [localhost] => (item=main.cf)
changed: [localhost] => (item=master.cf)

```

### krikri

```
TASK [Generate Postfix configuration] ******************************************
[ERROR]: Task failed: Error rendering template: No filter named 'ansible.utils.ipwrap' found.

Task failed.
Origin: <WORK>/roles/Anthony25.postfix/tasks/configure.yml:25:3

23   with_items: [ 'etc/mailname' ]
24
25 - name: Generate Postfix configuration
     ^ column 3

<<< caused by >>>

Error rendering template: No filter named 'ansible.utils.ipwrap' found.
Origin: <WORK>/roles/Anthony25.postfix/templates/etc/postfix/main.cf/ansible.j2

failed: [localhost] (item=main.cf) => {"ansible_loop_var": "item", "changed": false, "item": "main.cf", "msg": "Task failed: Error rendering template: No filter named 'ansible.utils.ipwrap' found."}
changed: [localhost] => (item=master.cf)

```
