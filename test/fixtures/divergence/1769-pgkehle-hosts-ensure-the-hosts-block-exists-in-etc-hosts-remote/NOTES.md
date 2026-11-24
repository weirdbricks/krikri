# pgkehle.hosts: Ensure the hosts block exists in /etc/hosts (remote)

Extracted by `krikri-role-tester extract-repro` from one divergent round of the
real-host differential run, so the repro replays as a test instead of living in a
closed issue.

- issue: #1769
- role: pgkehle.hosts
- round dir: /home/labros/git_work/krikri-role-tester/logs___1795546590/pgkehle_hosts
- phase: cold (block 10)
- task: Ensure the hosts block exists in /etc/hosts (remote)
- divergence: bytes differ (1080 B ansible, 704 B krikri)
- first differing line:

  ```
  ansible: [ERROR]: Task failed: Module failed: Unable to make '/root/.ansible/tmp/<TMP> into to '/etc/hosts', failed final rename from '/etc/.ansible_tmp<TMP>hosts': [Errno 16] Device or resource busy: b'/etc/.ansible_tmp<TMP>hosts' -> b'/etc/hosts'
  krikri:  [ERROR]: Task failed: Module failed: Failed to move file to destination: Error renaming file: '/etc/.krikri-playbook-blockinfile-bf1b3c6702e8dbd1.tmp' -> '/etc/hosts': Device or resource busy
  ```

- round versions: krikri 0.9.3079, ansible-playbook [core 2.21.6]

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

    bin/krikri-capture-case test/fixtures/divergence/1769-pgkehle-hosts-ensure-the-hosts-block-exists-in-etc-hosts-remote

That overwrites `expected.out` with the full transcript of `playbook.yml` (real
ansible 2.21.6, plus `--check` from `flags.txt` when the case has one), after which
the case replays and only needs listing in `DIVERGENCE_CASES` and its own `it`
block. `inventory.ini` pins the interpreter on the `[local]` host, which is the
only spelling both engines read alike. A file the task reads from a `~` or
relative path (the role or its own earlier tasks created it in the round) is not
in the case yet: copy it in before capturing, or the transcript pins a
file-not-found instead of the divergence.

`roles/pgkehle.hosts/` is the role tree the round ran, so the real YAML is in the case
even when `playbook.yml` only runs the one divergent task.

The task body was lifted verbatim from `work/roles/pgkehle.hosts/tasks/hosts.remote.yml:11`; its parameters are
verbatim, so any role variables they reference are not defined here.

## Divergent block

### ansible

```
TASK [Ensure the hosts block exists in /etc/hosts (remote)] ********************
[ERROR]: Task failed: Module failed: Unable to make '/root/.ansible/tmp/<TMP> into to '/etc/hosts', failed final rename from '/etc/.ansible_tmp<TMP>hosts': [Errno 16] Device or resource busy: b'/etc/.ansible_tmp<TMP>hosts' -> b'/etc/hosts'

Task failed: Module failed: Unable to make '/root/.ansible/tmp/<TMP> into to '/etc/hosts', failed final rename from '/etc/.ansible_tmp<TMP>hosts'.
Origin: <WORK>/roles/pgkehle.hosts/tasks/hosts.remote.yml:11:3

 9     b1: "['# Updated at {{ date_cmd.stdout }}', ''] + {{ b1 }}"
10
11 - name: Ensure the hosts block exists in /etc/hosts (remote)
     ^ column 3

<<< caused by >>>

[Errno 16] Device or resource busy: b'/etc/.ansible_tmp<TMP>hosts' -> b'/etc/hosts'

fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Module failed: Unable to make '/root/.ansible/tmp/<TMP> into to '/etc/hosts', failed final rename from '/etc/.ansible_tmp<TMP>hosts': [Errno 16] Device or resource busy: b'/etc/.ansible_tmp<TMP>hosts' -> b'/etc/hosts'"}

```

### krikri

```
TASK [Ensure the hosts block exists in /etc/hosts (remote)] ********************
[ERROR]: Task failed: Module failed: Failed to move file to destination: Error renaming file: '/etc/.krikri-playbook-blockinfile-bf1b3c6702e8dbd1.tmp' -> '/etc/hosts': Device or resource busy
Origin: <WORK>/roles/pgkehle.hosts/tasks/hosts.remote.yml:11:3

 9     b1: "['# Updated at {{ date_cmd.stdout }}', ''] + {{ b1 }}"
10
11 - name: Ensure the hosts block exists in /etc/hosts (remote)
     ^ column 3

fatal: [localhost]: FAILED! => {"changed": false, "msg": "Failed to move file to destination: Error renaming file: '/etc/.krikri-playbook-blockinfile-bf1b3c6702e8dbd1.tmp' -> '/etc/hosts': Device or resource busy"}

```
