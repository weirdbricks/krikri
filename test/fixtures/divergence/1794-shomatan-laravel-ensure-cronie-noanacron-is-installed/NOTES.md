# shomatan.laravel: Ensure cronie-noanacron is installed.

Extracted by `krikri-role-tester extract-repro` from one divergent round of the
real-host differential run, so the repro replays as a test instead of living in a
closed issue.

- issue: #1794
- role: shomatan.laravel
- round dir: /home/labros/git_work/krikri-role-tester/logs___1795578916/shomatan_laravel
- phase: cold (block 5)
- task: Ensure cronie-noanacron is installed.
- divergence: task results differ: ansible=[ok] krikri=[changed]
- first differing line:

  ```
  ansible: ok: [localhost]
  krikri:  changed: [localhost]
  ```

- round versions: krikri 0.9.3095, ansible-playbook [core 2.21.6]

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

    bin/krikri-capture-case test/fixtures/divergence/1794-shomatan-laravel-ensure-cronie-noanacron-is-installed

That overwrites `expected.out` with the full transcript of `playbook.yml` (real
ansible 2.21.6, plus `--check` from `flags.txt` when the case has one), after which
the case replays and only needs listing in `DIVERGENCE_CASES` and its own `it`
block. `inventory.ini` pins the interpreter on the `[local]` host, which is the
only spelling both engines read alike. A file the task reads from a `~` or
relative path (the role or its own earlier tasks created it in the round) is not
in the case yet: copy it in before capturing, or the transcript pins a
file-not-found instead of the divergence.

`roles/shomatan.laravel/` is the role tree the round ran, so the real YAML is in the case
even when `playbook.yml` only runs the one divergent task.

The task body could not be located in the round's role tree (a pruned `work/`),
so `playbook.yml` only names the task - its YAML is the banner's name, and the role's
real parameters are only in the block above.

## Divergent block

### ansible

```
TASK [Ensure cronie-noanacron is installed.] ***********************************
ok: [localhost]

```

### krikri

```
TASK [Ensure cronie-noanacron is installed.] ***********************************
changed: [localhost]

```
