# #1941 - krikri-lint never reports internal-error

- Issue: https://github.com/weirdbricks/krikri/issues/1941
- Class: output gap (load-time error, run refuses where krikri ran on)

**What diverged.** `vars_files: ['.']` resolves to the playbook's own
directory. Real ansible's vars manager searches for a vars_files entry by
existence only (`os.path.exists` is true for a directory), so it finds the
directory and `DataLoader.load_from_file`'s `read_bytes` raises
`IsADirectoryError`; that becomes an `AnsibleParserError` with no `Origin:`
block, printed before any `PLAY` output with `rc=4`:

```text
[ERROR]: An error occurred while trying to read the file '<WORK>': [Errno 21] Is a directory: '<WORK>'
```

krikri-playbook used to skip a vars_files candidate that was not a regular
file and then run the play as if the entry were simply absent (exit 0). The
same playbook is also the repro for the lint half of the issue: ansible-lint
matches no `OUTPUT_PATTERNS` entry against that `Origin:`-less message, so it
reports its catch-all `internal-error` at line 1 with no column and runs no
other rule on the file, where `krikri-lint` reported nothing. That half is
pinned by `testing/lint/cases/internal-error.yml` (re-linted against
ansible-lint by `testing/lint/parity.py`) and `test/lint/lint_test.cr`.

**Fixture.** The issue's playbook verbatim, plus an `inventory.ini` so the
run has a `[local]` host pinned to the interpreter. The play never executes a
task: the load refuses before any `PLAY` banner.
