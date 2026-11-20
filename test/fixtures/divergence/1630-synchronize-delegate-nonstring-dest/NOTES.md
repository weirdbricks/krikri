# #1630 - kpg synchronize (chaos): wrong non-string-dest crash wording

- Issue: https://github.com/weirdbricks/krikri/issues/1630
- Playbook: `000015-multi-synchronize-chaos` (krikri-playbook-generator)
- Class: output gap (action-plugin error message)

**What diverged.** The task's literal `dest: 10` is a non-string YAML
value, so real's synchronize action plugin crashes in its path munging
before the module runs. Which munging call crashes decides the message:
`_get_absolute_path`'s `':' in path` raises the TypeError
("argument of type '_AnsibleTaggedInt' is not iterable"),
`_format_rsync_rsh_target`'s `path.startswith('rsync://')` raises the
AttributeError ("'_AnsibleTaggedInt' object has no attribute
'startswith'"). Real picks between them from its `dest_is_local`, which
for a `delegate_to:` task is only `delegate_to in dest_host_ids` (the
task host's inventory_hostname/ansible_host) - the delegate's connection
transport is irrelevant. Here `delegate_to: target2` while the task host
is `target`, so dest stays remote and the AttributeError is what real
raises; krikri's old local-alias check (`ansible_connection=local` on the
task's vars) called it controller-local and printed the TypeError.

**Fixture.** The issue's `Synchronize #15.0` task verbatim plus its
handler; the generator's inventory of local aliases of one machine
(`target`, `target2`, `target3`) is in `inventory.ini`. The crash is in
the action plugin, so no fixture paths or rsync are needed.

`expected.out` was captured from real ansible-core 2.21.6 with
`bin/krikri-capture-case`, from this directory.
