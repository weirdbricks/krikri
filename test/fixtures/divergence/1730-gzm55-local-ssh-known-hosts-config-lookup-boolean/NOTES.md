# 1730 - gzm55.local_ssh_known_hosts: the config lookup hands back a string where ansible has a bool

- Issue: https://github.com/weirdbricks/krikri/issues/1730
- Role: `gzm55.prepare_setup` -> `gzm55.local_ssh_known_hosts` (rocky), round
  `logs___1795423891` (`round29923826`)
- Evidence: `logs___1795423891/gzm55_prepare_setup/compare_cold.diff`

## What diverged

The role's known-hosts block gates itself on

```yaml
when:
- inv_conn_is_ssh
- inv_conn_native_ssh_host_key_cheking or inv_conn_paramiko_ssh_host_key_cheking
```

where both `inv_conn_*_host_key_cheking` vars are built from
`lookup('ansible.builtin.config', 'HOST_KEY_CHECKING')`. The round's runner
sets `ANSIBLE_HOST_KEY_CHECKING=False`, so real ansible-core 2.21.6's config
manager casts the option to its declared `boolean` type and the lookup
returns the BOOL `False`; the `or` of two `False` operands is `False`, and the
block is skipped.

krikri's config lookup returned the option as the STRING `"False"`. A
non-empty string is truthy, so `True and "False"` produced a str, the second
`when:` item was a truthy str, and the strict conditional check failed the
task:

```
[ERROR]: Task failed: A 'when' expression failed: Conditional result (True)
was derived from value of type 'str' at
'<WORK>/roles/gzm55.local_ssh_known_hosts/tasks/main.yml:24:43'.
Conditionals must have a boolean result.
```

ansible instead printed `skipping:` for the block's four tasks and failed
later on an unrelated sudo-password error.

## Fix

`Krikri::LookupPlugins.ansible_config_typed_value` now applies the option's
declared TYPE, like ansible's `config.get_config_value`: `HOST_KEY_CHECKING`
comes back as a real Bool (default `True`, matching real), and the
integer-typed `DEFAULT_FORKS` / `DEFAULT_TIMEOUT` as real numbers.

## Case

`playbook.yml` carries the role's block verbatim from
`tasks/main.yml:13-89`, with the two `inv_conn_*` facts the role's
`Save context` action plugin supplies inlined for an ssh host (the case runs
`ansible_connection=local`, the round ran against a remote ssh target) and
the `lookup('id', 'uname')` become-user var dropped (no become in the case).
`env.txt` pins `ANSIBLE_HOST_KEY_CHECKING=False`, the runner's setting that
makes the lookups resolve to `False`. `expected.out` is
`bin/krikri-capture-case`'s capture from ansible-core 2.21.6: four skipped
block tasks.
