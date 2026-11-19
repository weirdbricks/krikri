# #1597 - mickengland.ldap-auth-client: the bare `with_dict:` lookup refusal

- Issue: https://github.com/weirdbricks/krikri/issues/1597
- Role: `mickengland.ldap-auth-client` (round `round29918136`, cold + warm)
- Class: output gap (error text and error block shape)

**What diverged.** The role's first task loops with
`with_dict: ldap_auth_config` - a BARE scalar, no `{{ }}`. Real's
`listify_lookup_plugin_terms` runs with `convert_bare=False`, so the text
itself is the lookup's one term and `lookup/dict.py` refuses it as a
non-Mapping:

    [ERROR]: The lookup plugin 'dict' failed: the 'dict' lookup plugin expects a dictionary, got 'ldap_auth_config' of type <class 'ansible.module_utils._internal._datatag._AnsibleTaggedStr'>)
    Origin: <unknown>

    invoke_lookup()

krikri's parser recognized only the hash and list forms of `with_dict:`, so
this task was not a loop at all: it ran once and failed later, at arg
finalization, with a three-level `<<< caused by >>>` chain ending in
`Error while resolving value for 'question': 'item' is undefined`.

**Fixture.** The role's `tasks/`, `vars/`, `handlers/` and `meta/` copied
verbatim, run through a localhost play with gathering off. The failing task is
the role's FIRST, so the `apt`/`shell` tasks below it never execute and need no
`--check`.
