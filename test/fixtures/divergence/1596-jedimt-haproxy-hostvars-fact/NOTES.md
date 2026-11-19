# #1596 - jedimt.haproxy: missing INJECT_FACTS_AS_VARS block (hostvars read)

- Issue: https://github.com/weirdbricks/krikri/issues/1596 (recurrence of #1354)
- Role: `jedimt.haproxy` (ubuntu host, round `logs___1795085158`)
- Class: output gap (missing stderr)

**What diverged.** The role's `Customize haproxy.cfg` task renders
`haproxy.j2` through `lookup('ansible.builtin.template', ...)` and then fails:
the template's second line reads `hostvars[inventory_hostname]['ansible_default_ipv4']`,
its later lines name an undefined `k8s_master` group. Real ansible printed the
`[DEPRECATION WARNING]: INJECT_FACTS_AS_VARS` block - Origin'd at the template
FILE and emitted before the render raised - and krikri printed nothing.

**Why.** The deprecation rides the tagged fact VALUE: fetching one back out of
a `hostvars[...]` entry is an access of that tag and warns, while the
`ansible_facts[...]` spelling (an untagged copy) stays silent. krikri's
deprecation probes only ever recognised bare fact NAMES, so a `hostvars[...]`
subscript read was invisible; the strict-undefined probe raises before the
render runs, so nothing else had a chance to notice either (live-verified vs
ansible-core 2.21.6).

**Fixture.** `roles/jedimt.haproxy/templates/haproxy.j2` is the role's file
verbatim. `tasks/main.yml` drops only the preceding `Install HAProxy` apt task
(it mutates the machine) and points `path:` at a scratch file so the case
cannot write outside its work dir - the render fails before the module runs
either way. `playbook.yml` is the round's play with localhost in place of
`testhost`.
