# #1798 - milad.ansible_role_create_dot_env_file: check mode fails where ansible reports changed

- Issue: https://github.com/weirdbricks/krikri/issues/1798
- Role: `milad.ansible_role_create_dot_env_file` (ubuntu host, round `round29926325`)
- Class: check-mode behaviour - krikri failed the play where real ansible reported a change

**What diverged.** The role's `defaults/main.yml` leaves `dot_env_directory`
as `""` (it is documented as required, and the round's play never set it),
so its first task runs `file` with `path: ""`, `state: directory`:

```yaml
- name: Confirm .env containing directory exists
  file:
    path: "{{ dot_env_directory }}"
    state: directory
    ...
  when: dot_env_confirm_directory_exists|bool
```

Under `--check` real ansible reports `changed` for that task: its
`ensure_directory` answers an absent path with `changed: True` *before* it
splits the path into components and `os.mkdir`s each one, so the empty-path
`OSError` the non-check run hits is never reached. krikri's plugin gated the
empty path in `execute` before dispatching to the state handler, so it
reported the non-check failure ("There was an issue creating  as requested:
[Errno 2] No such file or directory: b''") and the play stopped a task
early - `ok=1 changed=0 failed=1` against real ansible's `ok=2 changed=1
failed=1`, and the role's "Create .env file" task never ran.

The same gate swallowed `state=touch`'s check-mode answer: real ansible's
`execute_touch` also returns `changed: True` for an absent path before its
`open()`, so an empty touch path passed under `--check` and failed only in a
real run.

**Fix.** `plugins/file.cr`'s `empty_path_result` now only answers the
check-mode shape for the two states real ansible short-circuits
(`directory`: changed with the `path` echo and the absent -> directory diff;
`touch`: `changed: true` with touch's `dest` echo), and keeps failing the
non-check run and `state=file` (whose `ensure_file_attributes` has no
check-mode early return and still aborts "file () is absent, cannot
continue").

**Why the play is only this task.** The task is the role's `tasks/main.yml`
first task verbatim with the role's defaults as play vars; `become: yes` is
dropped because the case runs on localhost as the invoking user. The role's
second task (the `template:` that fails because the role ships no
`templates/` directory) is a separate upstream-role defect, not this
divergence.
