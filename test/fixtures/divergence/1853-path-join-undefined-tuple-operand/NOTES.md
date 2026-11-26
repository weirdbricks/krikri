# 1853 - xolyu.acmesh get_url dest with an undefined tuple operand

Issue: https://github.com/weirdbricks/krikri/issues/1853
Role: `xolyu.acmesh` (1.2.0, ubuntu), round round29928159, krikri 0.9.3139.

## What diverged

`tasks/10_install.yml` builds get_url's `dest` from a `tempfile` result:

```yaml
dest: "{{ (_acmesh_tempdir.path, 'acmesh.zip') | path_join }}"
```

In check mode `tempfile` does not support check mode, so the task is skipped and
the register holds `{"skipped": true, "changed": false}` - no `path` key.
Ansible's path_join hands a TUPLE operand straight to `os.path.join`, so the
undefined `_acmesh_tempdir.path` crosses the filter unconsumed and fails there:

    The filter plugin 'ansible.builtin.path_join' failed: expected str, bytes or os.PathLike object, not UndefinedMarker

krikri finalized the tuple on the way into its JSON-wrapped filter and reported
the attribute miss instead:

    object of type 'dict' has no attribute 'path'

The two differ only in wording; the exit code, the skipped task and the recap
counters already matched.

## Fix

`path_join` is registered as a native krikri-jinja filter so a strict undefined
inside a TUPLE operand raises the os.path.join TypeError wrapped as the filter
plugin's failure. A LIST literal deliberately keeps the attribute-miss wording:
real ansible consumes a list literal's elements before the filter runs (both
shapes live-verified against ansible-core 2.21.6).

## Notes

Both tasks are the role's own YAML, copied verbatim; the play pins only
`_acmesh_zipball_url`, which the role computes from its release vars and which
the get_url task never reaches (the `dest` failure comes first). The playbook
runs with `--check` (see `flags.txt`), which is what makes `tempfile` skip.
