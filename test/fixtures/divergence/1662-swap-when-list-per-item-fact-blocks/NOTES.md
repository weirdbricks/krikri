# #1662 - one INJECT_FACTS_AS_VARS block per when: list item reading the same fact

- Issue: https://github.com/weirdbricks/krikri/issues/1662
- Class: not an ansible-vs-krikri divergence - an environment lock for the
  CI-red issue (both engines agree; see below)

**What happened.** #1662 was main's CI being red on 17 specs plus a stalled
shard, all environment-driven (a 2.19.11 controller core vs the 2.21.6
capture target, missing docker SDK, rust-coreutils wording, a container
without systemd canaries). One of the two container-sensitive specs was
`inject_facts_deprecation_test.cr`'s "one block per when: item" case: its
`when:` list compared `ansible_virtualization_type` against the role's own
literals `docker`/`containerd`/`container`, and CI's job container gathers
`ansible_virtualization_type == "docker"`, so real short-circuits the list
at its first false item and legitimately prints one deprecation block where
a dev box prints three.

The spec now compares against values no host's virtualization fact can take
(`notdocker`/`notcontainerd`/`notcontainer`, from mullholland.swap's
"Enabling swap" gate, issue #1027), so every item stays truthy and the
per-item block count is host-independent. This corpus case pins the same
shape end to end: the task with the swapped literals, expecting three
INJECT_FACTS_AS_VARS blocks, one per item token (`:21:11`, `:22:11`,
`:23:11`), identical on a dev box and inside a container. The short-circuit
itself (a truthy run collapses to one block when item 1 IS false) is real
2.21.6 behaviour, verified during the round against the installed 2.21.6 in
a `/.dockerenv` container, so no case pins the 1-block side.

`expected.out` was captured with `bin/krikri-capture-case` from ansible-core
2.21.6 (the corpus's pinned parity target).
