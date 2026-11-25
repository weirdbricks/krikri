# #1827 - suzuki-shunsuke.consul_config: two fact-deprecation blocks where ansible prints one

- Issue: https://github.com/weirdbricks/krikri/issues/1827
- Role: suzuki-shunsuke.consul_config (v0.4.0, galaxy) from round
  `logs___1795626220` / round29927158 (rocky, krikri 0.9.3119)
- Class: output gap - an extra INJECT_FACTS_AS_VARS deprecation block in
  krikri's cold and warm transcripts.

## What diverged

The role's `defaults/main.yml` declares `consul_default_config`, a dict
whose `node_name` leaf reads `ansible_hostname` and whose `bind_addr` leaf
reads `ansible_default_ipv4`; `vars/main.yml` consumes it through
`combine()`. Real evaluates the role's `assert:` task's `that:` in ONE
templating operation, and that operation's audit context keeps only the
first fact access, so the whole dict prints ONE block at the earliest
fact-naming leaf (`defaults/main.yml:8:14`). Krikri's per-origin dedupe
had no operation identity for the eager preparation of the value (no task
param or `when:` site exists while an in-process assert evaluates), so the
second leaf printed its own block at `defaults/main.yml:9:14`.

## Fix

An expression evaluated in-process with no render site of its own
(assert's `that:`) now mints the templating-operation identity the
fact/vars-dict deprecation record needs (see
`VarSubstitutor.@@expression_op_scopes`). The outermost evaluation mints
it only when it uses a variable as a whole value - the case where real
finalizes every leaf of the container inside that one audit context - so a
subscripted use still resolves one leaf per access and keeps its own
block.

**Fixture.** `roles/suzuki-shunsuke.consul_config/defaults/main.yml`,
`vars/main.yml` and `tasks/assert.yml` are the role's verbatim files;
`tasks/main.yml` keeps only the diverging assertion (the role's later
tasks need a real host). `expected.out` was captured with
`bin/krikri-capture-case` from real ansible-core 2.21.6.
