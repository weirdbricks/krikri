# cameronbroe.nvm: Check whether shell profile contains /nvm.sh

Extracted by `krikri-role-tester extract-repro` from one divergent round of the
real-host differential run, so the repro replays as a test instead of living in a
closed issue.

- issue: #1668
- role: cameronbroe.nvm
- round dir: /home/labros/git_work/krikri-role-tester/logs___1795231613/cameronbroe_nvm
- phase: cold (block 21)
- task: Check whether shell profile contains /nvm.sh
- divergence: bytes differ (1685 B ansible, 1151 B krikri)
- first differing line:

  ```
  ansible: ok: [localhost] => (item={'changed': False, 'failed': False, 'deprecations': [{'msg': 'INJECT_FACTS_AS_VARS default to `True` is deprecated, top-level facts will not be auto injected after the change.', 'collection_name': 'ansible.builtin', 'version': '2.24', 'deprecator': {'resolved_name': 'ansible.builtin', 'type': None}}], 'ansible_loop_var': 'item', 'item': '.bashrc', 'stat': {'exists': True, ...
  krikri:  ok: [localhost] => (item={'changed': False, 'failed': False, 'ansible_loop_var': 'item', 'item': '.bashrc', 'stat': {'exists': True, 'path': '/root/.bashrc', 'mode': '0644', 'isdir': False, 'ischr': False, 'isblk': False, 'isreg': True, 'isfifo': False, 'islnk': False, 'issock': False, 'uid': 0, 'gid': 0, 'size': 3303, 'inode': <INODE>, 'dev': <DEV>, 'nlink': 1, 'atime': <TIME>, 'mtime': <TIME>, '...
  ```

- round versions: krikri 0.9.3015, ansible-playbook [core 2.21.6]

## Corpus fit

`expected.out` is the full transcript real ansible-playbook 2.21.6 prints for
this `playbook.yml`, captured with `bin/krikri-capture-case`. It is not the
round's own output: the round's `testhost` inventory alias became `localhost`
and the role banner prefix is gone, so the transcript matches what the corpus
replay produces.

krikri's replay (`test/integration/divergence_corpus_test.cr`) compares a case's
whole transcript, and only real ansible may produce one
(`test/fixtures/divergence/README.md`). Capture it from this directory with the
checkout's capture tool (`bin/krikri-capture-case`, or its predecessor
`scripts/capture_divergence_case.sh`):

    bin/krikri-capture-case test/fixtures/divergence/1668-cameronbroe-nvm-check-whether-shell-profile-contains-nvm-sh

That overwrites `expected.out` with the full transcript of `playbook.yml` (real
ansible 2.21.6, plus `--check` from `flags.txt` when the case has one), after which
the case replays and only needs listing in `DIVERGENCE_CASES` and its own `it`
block. `inventory.ini` pins the interpreter on the `[local]` host, which is the
only spelling both engines read alike. A file the task reads from a `~` or
relative path (the role or its own earlier tasks created it in the round) is not
in the case yet: copy it in before capturing, or the transcript pins a
file-not-found instead of the divergence.

`roles/cameronbroe.nvm/` is the role tree the round ran, so the real YAML is in the case
even though `playbook.yml` only runs the divergent task and the task it loops over.

The divergent block's item lines are the loop's own registered `stat` results, so
`playbook.yml` keeps the "Find shell profile scripts" task those results come from
and defines `nvm_home` with the role's `vars/main.yml` value; running the extracted
task alone made its loop source undefined instead of replaying the divergence. Both
profile files are absent, leaving each `stat` result the deterministic
`{'exists': False}` - a present path's result carries inode/atime and could not be
replayed byte for byte - so both items skip and the item lines still carry the
per-iteration deprecation entries that diverged.

## Divergent block

### ansible

```
TASK [Check whether shell profile contains /nvm.sh] ****************************
ok: [localhost] => (item={'changed': False, 'failed': False, 'deprecations': [{'msg': 'INJECT_FACTS_AS_VARS default to `True` is deprecated, top-level facts will not be auto injected after the change.', 'collection_name': 'ansible.builtin', 'version': '2.24', 'deprecator': {'resolved_name': 'ansible.builtin', 'type': None}}], 'ansible_loop_var': 'item', 'item': '.bashrc', 'stat': {'exists': True, 'path': '/root/.bashrc', 'mode': '0644', 'isdir': False, 'ischr': False, 'isblk': False, 'isreg': True, 'isfifo': False, 'islnk': False, 'issock': False, 'uid': 0, 'gid': 0, 'size': 3303, 'inode': <INODE>, 'dev': <DEV>, 'nlink': 1, 'atime': <TIME>, 'mtime': <TIME>, 'ctime': <TIME>, 'wusr': True, 'rusr': True, 'xusr': False, 'wgrp': False, 'rgrp': True, 'xgrp': False, 'woth': False, 'roth': True, 'xoth': False, 'isuid': False, 'isgid': False, 'blocks': 24, 'disk_usage_bytes': 12288, 'block_size': 4096, 'device_type': 0, 'readable': True, 'writeable': True, 'executable': False, 'pw_name': 'root', 'gr_name': 'root', 'checksum': '061d58a76ac7a7b0f4218e7382b7e1a41508032f', 'mimetype': 'unknown', 'charset': 'unknown', 'version': '<VERSION>', 'attributes': ['extents'], 'attr_flags': 'e'}})
skipping: [localhost] => (item={'changed': False, 'failed': False, 'deprecations': [{'msg': 'INJECT_FACTS_AS_VARS default to `True` is deprecated, top-level facts will not be auto injected after the change.', 'collection_name': 'ansible.builtin', 'version': '2.24', 'deprecator': {'resolved_name': 'ansible.builtin', 'type': None}}], 'ansible_loop_var': 'item', 'item': '.zshrc', 'stat': {'exists': False}}) 

```

### krikri

```
TASK [Check whether shell profile contains /nvm.sh] ****************************
ok: [localhost] => (item={'changed': False, 'failed': False, 'ansible_loop_var': 'item', 'item': '.bashrc', 'stat': {'exists': True, 'path': '/root/.bashrc', 'mode': '0644', 'isdir': False, 'ischr': False, 'isblk': False, 'isreg': True, 'isfifo': False, 'islnk': False, 'issock': False, 'uid': 0, 'gid': 0, 'size': 3303, 'inode': <INODE>, 'dev': <DEV>, 'nlink': 1, 'atime': <TIME>, 'mtime': <TIME>, 'ctime': <TIME>, 'wusr': True, 'rusr': True, 'xusr': False, 'wgrp': False, 'rgrp': True, 'xgrp': False, 'woth': False, 'roth': True, 'xoth': False, 'isuid': False, 'isgid': False, 'blocks': 24, 'disk_usage_bytes': 12288, 'block_size': 4096, 'device_type': 0, 'readable': True, 'writeable': True, 'executable': False, 'pw_name': 'root', 'gr_name': 'root', 'checksum': '061d58a76ac7a7b0f4218e7382b7e1a41508032f', 'mimetype': 'unknown', 'charset': 'unknown', 'version': '<VERSION>', 'attributes': ['extents'], 'attr_flags': 'e'}})
skipping: [localhost] => (item={'changed': False, 'failed': False, 'ansible_loop_var': 'item', 'item': '.zshrc', 'stat': {'exists': False}}) 

```
