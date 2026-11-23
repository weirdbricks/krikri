# `--diff` prints no diff for a real `file: state=absent` run

- issue: #1749 (https://github.com/weirdbricks/krikri/issues/1749)
- task: `ansible.builtin.file` with `state: absent` (the issue's repro)
- phase: real run (`--diff`, no `--check`)

## What diverged

Same root cause as `1749-file-absent-diff`: `ensure_absent` attaches
`initial_diff()` to the result whether or not check mode is on, and this
engine's `handle_absent` attached nothing. The issue's own "Other checks"
section reports the real run diverging identically while both engines still
removed the file.

## Case adaptations

- Same playbook adaptation as `1749-file-absent-diff`: the path points at the
  case's scratch copy of `target.conf` so a real removal only deletes the
  case's own input copy.
