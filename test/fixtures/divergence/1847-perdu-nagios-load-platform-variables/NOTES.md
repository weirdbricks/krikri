# perdu.nagios: Load platform variables

- issue: #1847
- role: perdu.nagios
- round dir: /home/labros/git_work/krikri-role-tester/logs___1795686235/perdu_nagios
- phase: cold and warm (block 4)
- task: Load platform variables
- divergence: task results differ: ansible=[ok] krikri=[fatal]

## What diverged

The role's first task is

```yaml
- name: Load platform variables
  ansible.builtin.include_vars:
    file: "{{ lookup('first_found', platform_vars_files, errors='ignore') }}"
  vars:
    platform_vars_files:
      files:
        - "{{ role_path }}/vars/{{ ansible_facts['distribution'] | lower }}/{{ ansible_facts['distribution_major_version'] }}.yml"
        - ...
        - "{{ role_path }}/vars/main.yml"
```

Every candidate renders ABSOLUTE. ansible-playbook's DataLoader#path_dwim_relative_stack
checks an absolute source against the filesystem directly, finds the last entry
(`<role>/vars/main.yml`) and the task is `ok`. krikri joined each absolute
candidate under every search root (`<role>`, `<role>/tasks`, the play
directory), matched nothing, and with `errors='ignore'` handed include_vars an
empty path, which its own search resolved to the role's vars/ DIRECTORY:

```
fatal: [testhost]: FAILED! => {"changed": false, "message": "YAML parsing failed: read <WORK>/roles/perdu.nagios/vars: Is a directory", ...}
```

## Corpus fit

`roles/perdu.nagios/` is the round's role tree with everything past the failing
task trimmed: the rest of `tasks/main.yml` installs packages and builds nagios
from source, which cannot run in a read-only case. The failing task's YAML and
`vars/main.yml` are copied verbatim. The round ran on rocky; the lookup's
absolute candidates behave identically on the Debian-family box the suite runs
on (the first three candidates still miss, `vars/main.yml` still exists).

`expected.out` was captured with `bin/krikri-capture-case` from ansible-core
2.21.6; `inventory.ini` pins the interpreter on the `[local]` host.
