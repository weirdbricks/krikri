# palvarez89.easy_rsa3: Copy easyrsa files needed to /etc

Extracted by hand from the issue's own diff (the round directory named in the
issue body is gone), so the repro replays as a test instead of living in a
closed issue.

- issue: #1643
- role: palvarez89.easy_rsa3
- round: round29919624 (krikri 0.9.2998, commit e3dd2c0dd103)
- phase: cold and warm (block 6), plus the PLAY RECAP that follows it
- task: Copy easyrsa files needed to /etc
- divergence: the task fails on both engines, but with different text:

  ```
  ansible: [ERROR]: Task failed: Module failed: Failed to find required executable "rsync" in paths: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin
  krikri:  [ERROR]: Task failed: Module failed: Plugin execution failed: Error executing process: 'rsync': No such file or directory
  ```

  and ansible also prints the module payload's own `to_bytes`/`to_native`
  import deprecations, which krikri lost because its plugin crashed before the
  result was built.

- round versions: krikri 0.9.2998, ansible-playbook [core 2.21.6]

## Corpus fit

`expected.out` is a fresh capture of `playbook.yml` from real ansible-core
2.21.6 over this directory. `<WORK>` stands in for the case's scratch
directory.

Four adaptations keep the transcript about THIS divergence:

- `gather_facts: false`: the task needs no facts, and ansible-core 2.21.6
  gathers them without printing a task (krikri still prints its Gathering Facts
  block, a separate divergence).
- the role's `become: yes` is dropped: a localhost capture cannot sudo, and the
  rsync probe fails before any privileged work (the same adaptation 1583 uses).
- the role's `easy_rsa_dir`/`easy_rsa_ca_dir` defaults are spelled out as play
  vars because the task runs inline; neither path is touched before the probe
  fails.
- `env.txt` pins `PATH` to a directory that does not exist, so no rsync binary
  is found - exactly the state the round's host was in. This is what the
  divergence is about: `get_bin_path`'s failure quotes the directories it
  searched, so the captured PATH must not be the developer's own.

`roles/palvarez89.easy_rsa3/` is the role tree the round ran, so the real YAML
is in the case even though `playbook.yml` only runs the one divergent task.
`inventory.ini` pins the interpreter on the `[local]` host, the only spelling
both engines read alike.

Capture it with:

    bin/krikri-capture-case test/fixtures/divergence/1643-palvarez89-easyrsa3-synchronize-rsync-missing

The task body was lifted verbatim from `roles/palvarez89.easy_rsa3/tasks/main.yml:21`.

## Divergent block

### ansible

```
TASK [Copy easyrsa files needed to /etc] ***************************************
[ERROR]: Task failed: Module failed: Failed to find required executable "rsync" in paths: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin
Origin: <WORK>/roles/palvarez89.easy_rsa3/tasks/main.yml:21:3

19     dest: "{{ easy_rsa_ca_dir }}"
20     recursive: yes
21 - name: Copy easyrsa files needed to /etc
     ^ column 3

fatal: [testhost]: FAILED! => {"changed": false, "msg": "Failed to find required executable \"rsync\" in paths: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"}
```

### krikri

```
TASK [Copy easyrsa files needed to /etc] ***************************************
[ERROR]: Task failed: Module failed: Plugin execution failed: Error executing process: 'rsync': No such file or directory
Origin: <WORK>/roles/palvarez89.easy_rsa3/tasks/main.yml:21:3

fatal: [testhost]: FAILED! => {"changed": false, "msg": "Plugin execution failed: Error executing process: 'rsync': No such file or directory"}
```
