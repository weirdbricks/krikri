# 1956 - with_nested/with_together/with_indexed_items: bare word loop runs unlooped

- Issue: https://github.com/weirdbricks/krikri/issues/1956
- Split from #1875 (found while checking the bare-variable `with_*` forms;
  no role in the corpus).

## What diverged

A bare (non-`{{ }}`) scalar loop source was dropped for `with_nested:`,
`with_together:` and `with_indexed_items:`: krikri ran the task ONCE with
`item` unbound ("'item' is undefined" at arg finalization), where
ansible-core hands the scalar to the lookup as one literal term.

Ansible's `listify_lookup_plugin_terms` runs with `convert_bare=False`, so a
bare word is never a variable reference - it is the term itself. The
`nested`/`together` lookups iterate a term as a sequence, so a string
contributes one character per product/row (`with_nested: my_list` yields
`['m']` .. `['t']`), while `indexed_items` enumerates its (single) term and
yields exactly one pair, `[0, "my_list"]`.

The parser (`src/krikri/playbook_parser.cr`) only had the YAML-array branches
for these three keys, so a scalar matched nothing and the loop resolved
empty. Scalar-source helpers existed only for `with_items:`/`with_dict:`.

## What this case pins

The issue's failing tasks for all three keywords, verbatim except `hosts:
localhost` for a local run. `expected.out` is real ansible-core 2.21.6's
transcript, captured with `bin/krikri-capture-case` (never from krikri).
