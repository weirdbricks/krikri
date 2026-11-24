# 1766 - lerwys.logrotate: fact deprecation Origin points at the with_first_found candidate

- Issue: https://github.com/weirdbricks/krikri/issues/1766
- Role: `lerwys.logrotate` (ubuntu), round `logs___1795546590`
- Evidence: `logs___1795546590/lerwys_logrotate/compare_cold.diff` (block 9)

## What diverged

Both engines print one INJECT_FACTS_AS_VARS deprecation block for the role's
first task, but name a different declaration:

```
-Origin: <WORK>/roles/lerwys.logrotate/tasks/main.yml:17:19   # ansible
+Origin: <WORK>/roles/lerwys.logrotate/tasks/main.yml:6:11    # krikri
```

`tasks/main.yml`'s task-level `vars:` read the distribution facts
(`distribution: '{{ ansible_distribution }}'`), and the `with_first_found:`
candidate list consumes `distribution`/`distribution_version`. Real templates
those values lazily at the candidate render and tags the VALUE, so the block
names the `distribution:` declaration (17:19).

krikri's `VariableSubstitutor.top_level_fact_name?` decided "is this read the
injected fact?" by looking the name up in the `ansible_facts` dict, whose keys
namespace_facts has already stripped of their `ansible_` prefix. A task var
named `distribution` (exactly the stripped spelling) whose rendered text - the
fact's own text - equalled `ansible_facts['distribution']` therefore read as
the deprecated fact, and that read fired first in the loop-source templating
operation, claiming the one block per operation and pushing the real value's
declaration out of the dedupe. Real never injects a setup fact under its bare
name at all (`{{ distribution }}` with no author var is undefined), so the
block was both mis-Origined and, for a var that merely holds the fact's text
without reading it, printed where real prints nothing.

The fix publishes the fact store's own key spellings per host and requires the
read name to be one of them.

## Case

`playbook.yml` runs the role; `roles/logrotate/tasks/main.yml` is the role's
`tasks/main.yml` first task copied verbatim. `roles/logrotate/vars/defaults.yml`
is the only addition, the `defaults.yml` fallback candidate, so first_found
matches on any distribution and the task completes. `expected.out` is
`bin/krikri-capture-case`'s capture from ansible-core 2.21.6.
