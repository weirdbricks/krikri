# #1904 - eendroroy.rbenv: a debug loop over fact NAMES loses their blocks

- Issue: https://github.com/weirdbricks/krikri/issues/1904
- Role: `eendroroy.rbenv` (ubuntu host, round `logs___1795725136`, cold + warm)
- Class: output gap (missing deprecation blocks)

**What diverged.** The role's `tasks/info.yml` runs
`debug: var: "{{ item }}"` over a `with_items` list that names two role vars
and four gathered facts. Real ansible printed one INJECT_FACTS_AS_VARS block
per fact item, Origin'd at that item's own YAML scalar
(`tasks/info.yml:9:7`..`:12:7`); krikri printed none of the four.

**Why.** Real hands debug's `var:` argument's RESOLVED value to
`evaluate_expression`, so the read is blamed at that value's defining
position - for a loop item, the item's scalar. Krikri resolves `var:` in the
action plugin and only claimed an Origin for a site whose template TEXT
names the read variable, so a templated `var:` (which names `item`, never
the fact) stayed silent. The manager now computes the passed-through
value's own Origin: a declared variable's declaration for `{{ name }}`, the
loop element's scalar for `{{ item }}` (quoted and flow-sequence elements
anchored at their own scalar start).

**Fixture.** The role's failing task, with `no_log: true` added (three
items print host-specific fact values) and `rbenv`/`rubies` supplied so the
first four items resolve - the role's real `rubies` is a list whose
`rubies.version` read raises a template-error warning real prints ahead of
the deprecation blocks, a separate (cosmetic-order) warning this case keeps
out. The four pinned Origins, their columns and the excerpt shape match the
round's transcript.

`expected.out` was captured with `bin/krikri-capture-case` from ansible-core
2.21.6 (the corpus's pinned parity target).
