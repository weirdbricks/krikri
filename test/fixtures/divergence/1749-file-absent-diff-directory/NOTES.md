# `--diff` prints no diff for `file: state=absent` on a directory

- issue: #1749 (https://github.com/weirdbricks/krikri/issues/1749)
- task: `ansible.builtin.file` with `state: absent` against a populated tree
- phase: check (`--check --diff`)

## What diverged

Same missing `diff` key as `1749-file-absent-diff`, plus the shape only a
directory removal has: `initial_diff` appends `os.walk`'s listing under
`before.path_content` (`directories`, then `files`, depth-first in walk
order), which the fix has to reproduce.

## Case adaptations

- `targetdir/` is the case's own input tree (`top.txt`, `sub/inner.txt`),
  copied into scratch by the replay/capture tools; `playbook.yml` references
  it through `{{ playbook_dir }}`.
- Symlink entries are not part of this case: the corpus copy helper follows
  symlinked directories (and cannot copy a dangling link), so a symlink in
  the fixture would not reach either engine as a link. The classification
  (a symlink to a directory listed under `directories` but not recursed
  into; a dangling symlink listed under `files`) is implemented in
  `walk_path_content` and was verified byte-for-byte against ansible-core
  2.21.6 by hand.
