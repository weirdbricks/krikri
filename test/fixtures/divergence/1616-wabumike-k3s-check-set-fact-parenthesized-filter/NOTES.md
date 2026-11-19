# #1616 - wabumike.k3s: check-mode set_fact reports the filter's JSON error instead of the missing dict attribute

- Issue: https://github.com/weirdbricks/krikri/issues/1616
- Role: `wabumike.k3s` (round `round29918097`, check phase)
- Class: check-mode output gap (error text in a failed task)

**What diverged.** In check mode the role's `uri` task is skipped, so the
registered `k3s_latest_release` is the skip result dict
(`changed`/`failed`/`skipped`/`skip_reason`) and has no `content` key. The
next task renders `{{ (k3s_latest_release.content | from_json).tag_name }}`.
Ansible's Jinja evaluates `k3s_latest_release.content` before the filter runs
and fails arg finalization with
`object of type 'dict' has no attribute 'content'`. krikri rendered the
missing attribute as empty text, ran `from_json` on it, and reported the
filter's own `Expecting value: line 1 column 1 (char 0)`, so every line of
the failure block and the fatal `msg` differed.

**Fixture.** The role's `tasks/get_version.yml` verbatim (the rest of the role
only installs and configures k3s, which check mode cannot run), behind a
`main.yml` that imports it, run with `--check` as the round did.
