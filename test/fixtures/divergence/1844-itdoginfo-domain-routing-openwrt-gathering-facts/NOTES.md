# itdoginfo.domain_routing_openwrt: Gathering Facts

Extracted by `krikri-role-tester extract-repro` from one divergent round of the
real-host differential run, so the repro replays as a test instead of living in a
closed issue.

- issue: #1844
- role: itdoginfo.domain_routing_openwrt
- round dir: /home/labros/git_work/krikri-role-tester/logs___1795686235/itdoginfo_domain_routing_openwrt
- phase: cold (block 3)
- task: Gathering Facts
- divergence: task results differ: ansible=[fatal] krikri=[ok]
- first differing line:

  ```
  ansible: [ERROR]: Task failed: not enough values to unpack (expected 4, got 2)
  krikri:  ok: [localhost]
  ```

- round versions: krikri 0.9.3139, ansible-playbook [core 2.21.6]

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

    bin/krikri-capture-case test/fixtures/divergence/1844-itdoginfo-domain-routing-openwrt-gathering-facts

That overwrites `expected.out` with the full transcript of `playbook.yml` (real
ansible 2.21.6, plus `--check` from `flags.txt` when the case has one), after which
the case replays and only needs listing in `DIVERGENCE_CASES` and its own `it`
block. `inventory.ini` pins the interpreter on the `[local]` host, which is the
only spelling both engines read alike. A file the task reads from a `~` or
relative path (the role or its own earlier tasks created it in the round) is not
in the case yet: copy it in before capturing, or the transcript pins a
file-not-found instead of the divergence.

`roles/itdoginfo.domain_routing_openwrt/` is the role tree the round ran, so the real YAML is in the case
even when `playbook.yml` only runs the one divergent task.

The task body could not be located in the round's role tree (a pruned `work/`),
so `playbook.yml` only names the task - its YAML is the banner's name, and the role's
real parameters are only in the block above.

## Divergent block

### ansible

```
TASK [Gathering Facts] *********************************************************
[ERROR]: Task failed: not enough values to unpack (expected 4, got 2)
fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: not enough values to unpack (expected 4, got 2)"}

```

### krikri

```
TASK [Gathering Facts] *********************************************************
ok: [localhost]

```
