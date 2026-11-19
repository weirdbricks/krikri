# stafwag.ntpd: Combine with provider_defaults

Extracted by `krikri-role-tester extract-repro` from one divergent round of the
real-host differential run, so the repro replays as a test instead of living in a
closed issue.

- issue: #1600
- role: stafwag.ntpd
- round dir: /home/labros/git_work/krikri-role-tester/logs___1795085158/stafwag_ntpd
- phase: cold (block 10)
- task: Combine with provider_defaults
- divergence: bytes differ (1515 B ansible, 1464 B krikri)
- first differing line:

  ```
  ansible: [ERROR]: Task failed: A 'when' expression failed: Conditional result (True) was derived from value of type 'dict' at '<WORK>/roles/stafwag.ntpd/vars/provider/chrony/defaults.yml:3:3'. Conditionals must have a boolean result.
  krikri:  [ERROR]: Task failed: A 'when' expression failed: Conditional result (True) was derived from value of type 'dict' at '<WORK>/roles/stafwag.ntpd/tasks/main.yml:100:7'. Conditionals must have a boolean result.
  ```

- round versions: krikri 0.9.2959, ansible-playbook [core 2.21.6]

## Corpus fit

`expected.out` is a fresh capture of `playbook.yml`: the round's own divergent
block, plus the lead-in vars load and PLAY RECAP a full run prints, with
`<WORK>` standing in for the scratch directory and the round's `testhost`
inventory alias rewritten to `localhost`. The banner lost its
`TASK [<role> : ...]` prefix.

krikri's replay (`test/integration/divergence_corpus_test.cr`) compares a case's
whole transcript, and only real ansible may produce one
(`test/fixtures/divergence/README.md`). Capture it from this directory with the
checkout's capture tool (`bin/krikri-capture-case`, or its predecessor
`scripts/capture_divergence_case.sh`):

    bin/krikri-capture-case test/fixtures/divergence/1600-stafwag-ntpd-combine-with-provider-defaults

That overwrites `expected.out` with the full transcript of `playbook.yml` (real
ansible 2.21.6, plus `--check` from `flags.txt` when the case has one), after which
the case replays and only needs listing in `DIVERGENCE_CASES` and its own `it`
block. `inventory.ini` pins the interpreter on the `[local]` host, which is the
only spelling both engines read alike. A file the task reads from a `~` or
relative path (the role or its own earlier tasks created it in the round) is not
in the case yet: copy it in before capturing, or the transcript pins a
file-not-found instead of the divergence.

`roles/stafwag.ntpd/` is the role tree the round ran, so the real YAML is in the case
even when `playbook.yml` only runs the one divergent task.

The task body was lifted verbatim from `work/roles/stafwag.ntpd/tasks/main.yml:96`; its
parameters are verbatim, so its role variables are loaded by the lead-in
`include_vars:` task (`roles/stafwag.ntpd/vars/provider/chrony/defaults.yml`), the
same load the role performs before reaching this task. Without it
`ntpd_provider_defaults` is undefined, the `when:` is falsy, and the task is simply
skipped - which pins no divergence at all.

## Divergent block

### ansible

```
TASK [Combine with provider_defaults] ******************************************
[ERROR]: Task failed: A 'when' expression failed: Conditional result (True) was derived from value of type 'dict' at '<WORK>/roles/stafwag.ntpd/vars/provider/chrony/defaults.yml:3:3'. Conditionals must have a boolean result.

Task failed.
Origin: <WORK>/roles/stafwag.ntpd/tasks/main.yml:96:3

94     - never
95
96 - name: Combine with provider_defaults
     ^ column 3

<<< caused by >>>

A 'when' expression failed.
Origin: <WORK>/roles/stafwag.ntpd/tasks/main.yml:100:7

 98     _ntpd: "{{ ntpd_provider_defaults | ansible.builtin.combine(_ntpd) }}"
 99   when:
100     - ntpd_provider_defaults | default(false)
          ^ column 7

<<< caused by >>>

Conditional result (True) was derived from value of type 'dict' at '<WORK>/roles/stafwag.ntpd/vars/provider/chrony/defaults.yml:3:3'. Conditionals must have a boolean result.
Origin: <WORK>/roles/stafwag.ntpd/tasks/main.yml:100:7

 98     _ntpd: "{{ ntpd_provider_defaults | ansible.builtin.combine(_ntpd) }}"
 99   when:
100     - ntpd_provider_defaults | default(false)
          ^ column 7

Broken conditionals can be temporarily allowed with the `ALLOW_BROKEN_CONDITIONALS` configuration option.

fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: A 'when' expression failed: Conditional result (True) was derived from value of type 'dict' at '<WORK>/roles/stafwag.ntpd/vars/provider/chrony/defaults.yml:3:3'. Conditionals must have a boolean result."}

```

### krikri

```
TASK [Combine with provider_defaults] ******************************************
[ERROR]: Task failed: A 'when' expression failed: Conditional result (True) was derived from value of type 'dict' at '<WORK>/roles/stafwag.ntpd/tasks/main.yml:100:7'. Conditionals must have a boolean result.

Task failed.
Origin: <WORK>/roles/stafwag.ntpd/tasks/main.yml:96:3

94     - never
95
96 - name: Combine with provider_defaults
     ^ column 3

<<< caused by >>>

A 'when' expression failed.
Origin: <WORK>/roles/stafwag.ntpd/tasks/main.yml:100:7

 98     _ntpd: "{{ ntpd_provider_defaults | ansible.builtin.combine(_ntpd) }}"
 99   when:
100     - ntpd_provider_defaults | default(false)
          ^ column 7

<<< caused by >>>

Conditional result (True) was derived from value of type 'dict' at '<WORK>/roles/stafwag.ntpd/tasks/main.yml:100:7'. Conditionals must have a boolean result.
Origin: <WORK>/roles/stafwag.ntpd/tasks/main.yml:100:7

 98     _ntpd: "{{ ntpd_provider_defaults | ansible.builtin.combine(_ntpd) }}"
 99   when:
100     - ntpd_provider_defaults | default(false)
          ^ column 7

Broken conditionals can be temporarily allowed with the `ALLOW_BROKEN_CONDITIONALS` configuration option.

fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: A 'when' expression failed: Conditional result (True) was derived from value of type 'dict' at '<WORK>/roles/stafwag.ntpd/tasks/main.yml:100:7'. Conditionals must have a boolean result."}

```
