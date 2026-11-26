# Azulinho.azulinho-google-dns: configure /etc/resolv.conf

Extracted from the round the issue cites, so the role's failing task replays as a
test instead of living in the issue body.

- issue: #1841
- role: Azulinho.azulinho-google-dns
- round dir: `/home/labros/git_work/krikri-role-tester/logs___1795686235/Azulinho_azulinho-google-dns`
- phase: cold (block 4) and warm (block 4)
- task: configure /etc/resolv.conf (`copy: dest=/etc/resolv.conf src=resolv.conf`)
- divergence: bytes differ (1118 B ansible, 609 B krikri)
- first differing line:

  ```
  ansible: [ERROR]: Task failed: Module failed: Unable to make b'/root/.ansible/tmp/<TMP> into to '/etc/resolv.conf', failed final rename from '/etc/.ansible_tmp<TMP>resolv.conf': [Errno 16] Device or resource busy: b'/etc/.ansible_tmp<TMP>resolv.conf' -> b'/etc/resolv.conf'
  krikri:  [ERROR]: Task failed: Module failed: Failed to move file to destination: Error renaming file: '/etc/.krikri-playbook-copy-<TMP>.tmp' -> '/etc/resolv.conf': Device or resource busy
  ```

- round versions: krikri 0.9.3139 (debug), ansible-playbook [core 2.21.6]

## Corpus fit

`expected.out` is the ansible side of one run of this play, captured with
`bin/krikri-capture-case` (real ansible 2.21.6, `<WORK>` standing in for the
case's scratch directory). It pins the shape the same task takes for an
UNPRIVILEGED user on a normal filesystem: copy.py's dest-directory
writability pre-check, which krikri's copy module did not have at all (it
went on to write its own staging temp and failed with "Failed to write
temporary file: ... Permission denied", no checksum). Both engines now print
`Destination /etc not writable` with the action-injected checksum.

The round's own divergence is one step further down the same write ladder: in
the round's podman container `/etc/resolv.conf` is a bind mount, so root
passes that pre-check and the crash lands in `atomic_move`'s failed final
rename. That shape cannot be recorded here - its detail names the stage
file's random `.ansible_tmp<random>` and the action's random
`ansible-tmp-<epoch>-<pid>-<random>` directory, and two runs of real ansible
disagree on both, so no transcript could replay byte-exactly. It is pinned
instead by `test/integration/copy_atomic_move_test.cr`, which drives the same
ladder to its final rename through podman's foreign-uid trick (a sticky-dir
EPERM, live-verified side by side with real ansible 2.21.6 on the same dest).

`extract-repro` cannot derive this case automatically: the role ships a
`vagrantbox/roles/google-dns` symlink to its own parent, so copying the role
tree recurses until the filesystem's symlink limit.

## Divergent block

### ansible

```
TASK [configure /etc/resolv.conf] **********************************************
[ERROR]: Task failed: Module failed: Unable to make b'/root/.ansible/tmp/<TMP> into to '/etc/resolv.conf', failed final rename from '/etc/.ansible_tmp<TMP>resolv.conf': [Errno 16] Device or resource busy: b'/etc/.ansible_tmp<TMP>resolv.conf' -> b'/etc/resolv.conf'

Task failed: Module failed: Unable to make b'/root/.ansible/tmp/<TMP> into to '/etc/resolv.conf', failed final rename from '/etc/.ansible_tmp<TMP>resolv.conf'.
Origin: <WORK>/roles/Azulinho.azulinho-google-dns/tasks/main.yml:1:3

1 - name: configure /etc/resolv.conf
    ^ column 3

<<< caused by >>>

[Errno 16] Device or resource busy: b'/etc/.ansible_tmp<TMP>resolv.conf' -> b'/etc/resolv.conf'

fatal: [testhost]: FAILED! => {"changed": false, "checksum": "c3f9736e9af7bd0885578859a50b205c8fa5fc8e", "msg": "Task failed: Module failed: Unable to make b'/root/.ansible/tmp/<TMP> into to '/etc/resolv.conf', failed final rename from '/etc/.ansible_tmp<TMP>resolv.conf': [Errno 16] Device or resource busy: b'/etc/.ansible_tmp<TMP>resolv.conf' -> b'/etc/resolv.conf'"}

PLAY RECAP *********************************************************************
testhost                   : ok=1    changed=0    unreachable=0    failed=1    skipped=0    rescued=0    ignored=0
```

### krikri (before this fix)

```
TASK [configure /etc/resolv.conf] **********************************************
[ERROR]: Task failed: Module failed: Failed to move file to destination: Error renaming file: '/etc/.krikri-playbook-copy-<TMP>.tmp' -> '/etc/resolv.conf': Device or resource busy
Origin: <WORK>/roles/Azulinho.azulinho-google-dns/tasks/main.yml:1:3

1 - name: configure /etc/resolv.conf
    ^ column 3

fatal: [testhost]: FAILED! => {"changed": false, "msg": "Failed to move file to destination: Error renaming file: '/etc/.krikri-playbook-copy-<TMP>.tmp' -> '/etc/resolv.conf': Device or resource busy"}

PLAY RECAP *********************************************************************
testhost                   : ok=1    changed=0    unreachable=0    failed=1    skipped=0    rescued=0    ignored=0
```
