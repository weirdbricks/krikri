# #1750 - postgresql_privs rejects schema: for a type that has no schema, before it complains about privs

- Issue: https://github.com/weirdbricks/krikri/issues/1750
- Playbook: kpg `000000-multi-postgresql_privs-happy` (and `000035-...-chaos`)
- Class: argument-validation order and wording (check mode, happy path)

**What diverged.** The generated task passes `type: database` together with
`schema: zlolmi` and no `privs:`. community.postgresql validates those in
Ansible's own order - schema/type compatibility, then objs, then privs - and
fails first on the schema:

```
fatal: [localhost]: FAILED! => {"changed": false, "msg": "Argument \"schema\" is not allowed for type \"database\"."}
```

krikri validated privs first and reported
`privs is required for type 'database'` instead (and its pre-connection
validation messages used a lowercase `'type'` spelling of their own rather
than Ansible's `Argument "X" is required for type "Y".` wording).

**Fixture.** The round's failing task is copied verbatim (only `delegate_to`
dropped, since the case runs on localhost); `expected.out` was captured from
real ansible-core 2.21.6 + community.postgresql 4.2.0 in `--check` mode.

**Fix.** `plugins/postgresql_privs.cr` now runs Ansible's validation in its
own order before connecting: schema is rejected for every type that does not
live in one (`Argument "schema" is not allowed for type "X".`), then objs,
then privs, with Ansible's exact messages.
