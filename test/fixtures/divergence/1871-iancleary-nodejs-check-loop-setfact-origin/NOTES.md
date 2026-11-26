# #1871 - iancleary.nodejs: check mode loses the INJECT_FACTS_AS_VARS block a loop source's fact read prints

- Issue: https://github.com/weirdbricks/krikri/issues/1871
- Role: `iancleary.nodejs` (ubuntu, round round29928609)
- Class: check-mode output (real's PLAY RECAP block carries five
  INJECT_FACTS_AS_VARS blocks; krikri printed four - the one from the
  NodeSource repo task's loop source was missing)

**What diverged.** The role writes the NodeSource repo entries as a YAML
folded block scalar:

```yaml
- name: Nodejs - Add NodeSource repositories for Node.js.
  ansible.builtin.apt_repository:
    repo: "{{ item }}"
    state: present
  loop:
    - >-
      deb https://deb.nodesource.com/node_{{ nodejs_version }}
       {{ massaged_ansible_distribution_release }} main
```

That item template reads `massaged_ansible_distribution_release`, a
`set_fact` copy of `ansible_distribution_release`. Real ansible tags the
value the fact cache injects and `set_fact` stores that object unchanged,
so the read trips the deprecation and the block is Origin'd at the loop
item's own scalar start (`setup-nodejs-Debian.yml:36:7` in the round).
Krikri printed no block there at all:

- it treated every `set_fact`-written name as untagged, whatever value the
  write stored, and
- its loop-source Origin scan only matched an item's fact name on the
  `- ...` line itself, so a folded/literal block scalar item (whose text
  lives on the indented lines below) had no placeable Origin.

**Fix.** The set_fact write now records the AS-WRITTEN value text for each
key, and a read of that name warns when the text is a bare `{{ <tagged
name> }}` copy (optionally through identity-preserving filters such as
`default`); a literal, a concatenation or an `ansible_facts[...]` read
stays silent, matching 2.21.6. `ResultDisplay.loop_source_origin` looks
through a block scalar item's continuation lines and anchors the read at
the item's block indicator.

**Fixture.** The role's tasks up to the NodeSource repo task are kept
verbatim (`main.yml`'s own `import_tasks` when clause included) minus the
apt/apt_key/package tasks, whose ok/changed answer depends on the replay
host's own apt state and which the round's diff showed already matching.
Two adaptations: the looped task asks `debug` instead of `apt_repository`
(which needs a root apt host), and `massaged_ansible_distribution_release`
is written from `ansible_system` instead of `ansible_distribution_release`
- the value is rendered into every `(item=...)` label, so the real
transcript would otherwise differ per machine, while `ansible_system` is
the same deterministic "Linux" everywhere. Both are still bare fact copies,
which is what the issue's missing block comes from. `flags.txt` adds the
round's `--check`; `expected.out` was captured with `bin/krikri-capture-case`
from real ansible-core 2.21.6.
