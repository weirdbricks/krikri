# 1957 - with_subelements: a bare first term is not a variable reference

- Issue: https://github.com/weirdbricks/krikri/issues/1957
- Split from #1875 (the bare-variable `with_*` forms).

## What diverged

Ansible templates each lookup term before handing it to the plugin, but only
when the term itself carries template syntax. A bare `my_list` therefore
reaches the subelements lookup as the literal string "my_list", and
lookup/subelements.py refuses it:

```
[ERROR]: The lookup plugin 'subelements' failed: subelements lookup expects a list of two or three items, first a dict or a list, second a string pointing to the subkey
Origin: <unknown>

invoke_lookup()

fatal: [localhost]: FAILED! => {"msg": "The lookup plugin 'subelements' failed: subelements lookup expects a list of two or three items, first a dict or a list, second a string pointing to the subkey"}
```

krikri instead resolved the bare term against the variable context and
iterated `my_list`, so the task reported `ok: [localhost]` with one item and
`failed=0` where real ansible fails.

The templated spelling (`- "{{ my_list }}"`) works identically on both
engines, so this case pins only the bare form. ansible-lint likewise flags
the bare form with `deprecated-bare-vars`.

## What this case pins

The playbook is the issue's own, with the host adapted to localhost.
`expected.out` is real ansible-core 2.21.6's transcript, captured with
`bin/krikri-capture-case` (never from krikri).
