# `command` on an ansible_connection=local host sees the controller's PS1

- issue: https://github.com/weirdbricks/krikri/issues/1834
- follow-up to: https://github.com/weirdbricks/krikri/issues/1747 (the same
  leak on the ssh daemon's environment)
- reported against: krikri 0.9.3130 vs ansible-core 2.21.5, macOS
- task: `-m command -a env` (the playbook's `command env` task is that same
  invocation)

## What diverged

With `PS1='x> '` exported into the controller, krikri's local `command` module
printed `PS1=x> ` in the module's `env` output; real ansible printed nothing.

Ansible starts a local module through `sh -c` (`_low_level_execute_command`'s
shell executable). A non-interactive bash removes PS1 from the environment it
hands on, and on macOS - where the issue was reported - `/bin/sh` IS bash, so
the module process never sees the controller's prompt. krikri execs its local
plugin binary directly (no shell in between), so the exported PS1 reached the
module's environment unchanged. The `shell` module was already correct: krikri
runs it through `/bin/bash -c`, so bash drops PS1 on that path.

## Why the case pins the shell executable

This box's `/bin/sh` is dash, which forwards PS1 (real ansible leaks it here
too), so a default-inventory case could not reproduce the macOS observation.
`inventory.ini` pins `ansible_shell_executable=/bin/bash` on the `[local]`
host, which reproduces exactly the shell the issue was reported against
without making the recording depend on which `sh` the box happens to have.

## Why the playbook reports one boolean

The `env` dump is the whole environment of whoever ran the case, so no
transcript of it can be replayed byte for byte (see 1584's and 1569's
NOTES.md). `PS1=` presence is the one part that is stable across machines and
is exactly what the issue measured.

`env.txt` pins `PS1` for the controller's own environment, because the
trigger lives in the RUNNING process, not in the play: the `environment:`
keyword reaches only the module process and would defeat the test.

`expected.out` was captured from real ansible-core 2.21.6 with
`bin/krikri-capture-case`.
