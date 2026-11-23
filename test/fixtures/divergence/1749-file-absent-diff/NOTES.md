# `--diff` prints no diff for `file: state=absent`

- issue: #1749 (https://github.com/weirdbricks/krikri/issues/1749)
- task: `ansible.builtin.file` with `state: absent` (the issue's repro)
- phase: check (`--check --diff`)

## What diverged

ansible-core's `ensure_absent` builds `initial_diff(path, 'absent',
prev_state)` BEFORE removing anything and keeps it on the result, so `--diff`
prints the `file` -> `absent` transition. krikri's `handle_absent` returned a
changed result with no `diff` key at all, so both engines reported `changed=1`
and krikri printed no `--- before` / `+++ after` block.

## Case adaptations

- `playbook.yml` is the issue's repro; only the path is adapted to the case's
  scratch tree (`{{ playbook_dir }}/target.conf`, shipped as `target.conf`) so
  the replay cannot touch a real `/tmp` path or race a parallel case.
- `--check` keeps the file in place, exactly like the issue's capture.
