# 1825 - kaos2oak.oracle_java: PLAY RECAP loses two `vars` deprecation blocks

- Issue: https://github.com/weirdbricks/krikri/issues/1825
- Role: `kaos2oak.oracle_java` (rocky), round `logs___1795626220`
- Evidence: `logs___1795626220/kaos2oak_oracle_java/compare_cold.diff` (block 16)

## What diverged

Real ansible prints three `[DEPRECATION WARNING]: The internal "vars"
dictionary is deprecated.` blocks for the role's first `set_fact` loop; krikri
printed one:

```yaml
- name: Set facts using any 'default_java_' vars
  set_fact:
    "{{ item[8:] }}": "{{  vars[item[8:]] | default(vars[item]) }}"
  loop: "{{ vars | flatten(levels=1) | select('match', '^default_java_') | list }}"
```

- `default_java_vars.yml:25:9` - the `loop:` source, printed by both.
- `default_java_vars.yml:24:23` - the args value's own token. Its mapping KEY
  is itself a template (`"{{ item[8:] }}":`), and krikri's Origin scan looked
  for a literal `<key>:` token, which a quoted key never contains (the closing
  quote sits between the key text and the colon), so the read had no Origin
  and stayed silent. A second, latent bug hid the same shape: the "only
  whitespace/quotes before the key" guard compared a String against a tuple of
  Chars, so even a resolved quoted key was rejected.
- `tasks/set/Linux/env_vars.yml:11:41` - the third block comes from the NEXT
  task reading the fact this one stored. ansible-core tags the OBJECT a `vars`
  read hands back, set_fact stores that tagged object, and reading it again
  trips the same deprecation at the reading template. krikri modelled the tag
  only at the read that produced it.

## Case

Both tasks are the role's own, verbatim, plus the role's `vars/main.yml`
`default_java_local_installer_path_env_vars` value inline. `expected.out` is
`bin/krikri-capture-case`'s capture from ansible-core 2.21.6.
