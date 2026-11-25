# #1819 - ben-le.awx_nginx: the container's later read loses the fact deprecation block

- Issue: https://github.com/weirdbricks/krikri/issues/1819
- Role: ben-le.awx_nginx (master, galaxy) from round `logs___1795626220` /
  round29927202 (rocky, krikri 0.9.3119)
- Class: output gap - the INJECT_FACTS_AS_VARS deprecation block is missing
  from krikri's cold and warm transcripts.

## What diverged

The role's `awx_nginx.j2` reads one leaf of the `awx_config` default first
(`awx_config.ALLOWED_HOSTS[0]`, whose `{{ inventory_hostname }}` names no
fact) and only then the whole container (`awx_config.ALLOWED_HOSTS | join`,
whose second leaf is `{{ ansible_default_ipv4.address }}`). Real templates a
container's leaves lazily, so the fact is read by the SECOND read alone, and
the block is Origin'd at that leaf's declaration
(`roles/ben-le.awx_nginx/defaults/main.yml:5:7`). The block prints even
though the render then dies on the undefined `host_port` in the same file.

Krikri's template-file deprecation probe recorded only the FIRST syntactic
read path of each variable, and that subtree named no fact, so the probe
reported no read and printed nothing.

## Fix

`TemplateActionPlugin#record_read_path` now records the subscript path of
the read currently being walked (the matcher call site), not the name's
first occurrence in the file; the whole-container/first-read rules for a
single occurrence are unchanged.

**Fixture.** `roles/ben-le.awx_nginx/defaults/main.yml` and
`templates/awx_nginx.j2` are the role's verbatim files; `tasks/main.yml`
keeps only the diverging `Copy over awx nginx configuration` task (the
apt/file/copy tasks before it need a real host) with its `dest:` adapted to
a scratch-relative path. The render fails on `host_port` exactly as it did
in the round, which is also what pins the warning to a failed render.
`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6.
