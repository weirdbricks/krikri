# External plugin `params` arrive flattened, without their YAML types

- issue: #1758 (https://github.com/weirdbricks/krikri/issues/1758)
- task: an external (`--plugin-path`/`KRIKRI_PLUGIN_PATH`) module plugin
  called with a bool, an int, a float, a null, a dict, a list of strings, a
  list of ints, a one-member list holding a comma, and a string that holds
  the dict's JSON (the issue's repro, verbatim)
- phase: run

## What diverged

The external-plugin protocol's `params` is a strings-only wire, so krikri
flattened every non-string argument and marked it with an undocumented
U+E000-prefixed sentinel: `a_bool` arrived as
`"\u{E000}nonstring:true"`, `a_int` as `"\u{E000}nonstring:5"`, `a_none` as
`__crystal_ansible_none__`, a dict as its JSON text, and a list as its
members joined with `,`. Two pairs of different inputs therefore arrived as
the same bytes - a dict and the string holding the same JSON, and `[x, y]`
vs `["x,y"]` - so a plugin could not recover the types its task wrote.
ansible-playbook passes modules the types the playbook wrote, which is what
this transcript shows.

krikri now adds a typed `args` copy beside `params` for external plugins
(docs/external-plugins.md), so the plugin reports real ansible's values.

## Case shape

No such thing exists in ansible-playbook: `--plugin-path` and
`KRIKRI_PLUGIN_PATH` are krikri-only. The case therefore ships both halves
of the same task name:

- `library/echoargs.py` - the module ansible-playbook runs (playbook-adjacent
  `library/`, its normal search path).
- `plugins/echoargs` - the external plugin krikri runs; `env.txt` puts it on
  `KRIKRI_PLUGIN_PATH`, which ansible-playbook ignores.

krikri resolves a registered external plugin before a `library/` source with
the same name, so each engine runs its own half of the same task YAML.
`plugins/echoargs` reads `args` and falls back to `params`; on an engine
without `args` (pre-fix, or protocol 1) it prints the flattened strings,
which is exactly the reported divergence.

## Capturing

`expected.out` is `bin/krikri-capture-case`'s capture of ansible-core 2.21.6
running `library/echoargs.py`. Nothing is adapted from the issue's repro
beyond what localhost already needs (the interpreter pin in `inventory.ini`).
