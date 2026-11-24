# alvistack.firefox: flatpak remote-add

Extracted by `krikri-role-triager` from one divergent round of the real-host
differential run.

- issue: #1774
- role: alvistack.firefox (ubuntu)
- round dir: `/home/labros/git_work/krikri-role-tester/logs___1795546590/alvistack_firefox`
- phase: check
- task: flatpak remote-add (`roles/alvistack.firefox/tasks/main.yml:55`)
- divergence: task results differ: ansible=[failed] krikri=[skipping,skipping]
- first differing line:

  ```
  ansible: [ERROR]: Task failed: Module failed: Executable 'flatpak' was not found on the system.
  krikri:  skipping: [localhost] => (item={'state': 'present', 'name': 'flathub', ...})
  ```

- round versions: krikri 0.9.3079 (debug), ansible-playbook [core 2.21.6]

## Root cause

community.general.flatpak_remote and community.general.flatpak were not
implemented, so krikri dropped both tasks as unimplemented plugins: every loop
item skipped, recap `skipped=2`, exit 4. Real ansible runs the modules (their
`flatpak remote-list`/`list` queries execute even under `--check`) and fails the
first one on a host with no flatpak binary with the module's own fail_json
wording, so the play stops: recap `failed=1`, exit 2.

`plugins/flatpak_remote.cr` and `plugins/flatpak.cr` port the two modules.

## Corpus fit

`expected.out` is a fresh capture of `playbook.yml` from real ansible-core
2.21.6 over this directory, in `--check` mode (`flags.txt`) like the round.
`<WORK>` stands in for the case's scratch directory, and the round's `testhost`
inventory alias became `localhost`.

Adaptations, all transcript-neutral for this divergence:

- `gather_facts: false` (the task needs no facts; krikri prints a Gathering
  Facts block real 2.21.6 does not).
- a play-level `environment.PATH` without `/usr/bin` or `/bin`: flatpak is
  installed on the capture box, and the round's host had none. The failure
  message does not print the searched directories, so the exact PATH is not in
  the recording.
- `inventory.ini` pins the interpreter on the `[local]` host, the only spelling
  both engines read alike.

Capture it with:

    bin/krikri-capture-case test/fixtures/divergence/1774-alvistack-firefox-flatpak-remote-add

## Divergent block

### ansible

```
TASK [flatpak remote-add] ******************************************************
[ERROR]: Task failed: Module failed: Executable 'flatpak' was not found on the system.
Origin: <WORK>/playbook.yml:21:7
...
failed: [localhost] (item={'state': 'present', 'name': 'flathub', 'flatpakrepo_url': 'https://dl.flathub.org/repo/flathub.flatpakrepo'}) => {"ansible_loop_var": "item", "changed": false, "item": {...}, "msg": "Executable 'flatpak' was not found on the system."}

PLAY RECAP *********************************************************************
localhost                  : ok=0    changed=0    unreachable=0    failed=1    skipped=0    rescued=0    ignored=0
```

### krikri (before the fix)

```
TASK [flatpak remote-add] ******************************************************
skipping: [localhost] => (item={'state': 'present', 'name': 'flathub', 'flatpakrepo_url': 'https://dl.flathub.org/repo/flathub.flatpakrepo'})
skipping: [localhost]

PLAY RECAP *********************************************************************
localhost                  : ok=0    changed=0    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0
```
