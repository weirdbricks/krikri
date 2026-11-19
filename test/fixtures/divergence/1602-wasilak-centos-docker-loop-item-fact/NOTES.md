# #1602 - wasilak.centos-docker: missing INJECT_FACTS_AS_VARS blocks (loop-item + when: hostvars reads)

- Issue: https://github.com/weirdbricks/krikri/issues/1602
- Role: `wasilak.centos-docker` (ubuntu host, round `logs___1795085158`)
- Class: output gap (missing stderr)

**What diverged.** Real ansible printed three
`[DEPRECATION WARNING]: INJECT_FACTS_AS_VARS` blocks that krikri did not:
one for the `with_items` entry's own `baseurl` template (Origin at the
leaf's value token, `tasks/main.yml:12:16` in the role) and one each for the
two `when:` clauses that read `hostvars[inventory_hostname]["ansible_distribution"]`
(`:31:9`, `:43:9`). The `when:` halves were fixed by #1596; the loop-item
leaf read had no placeable Origin, so its block stayed silent.

**Why.** A loop source written as a list of flow mappings
(`with_items: - { baseurl: '...{{ ... }}...' }`) puts the fact-naming
template one level INSIDE the item. The loop-source Origin lookup only
scanned the `- ` element lines, where the item's own start (`{`) names no
fact, so it answered nil and the deprecation was dropped. Real tags every
stored YAML scalar, so it anchors the read at that leaf's value token
(live-verified against ansible-core 2.21.6).

**Fixture.** `roles/wasilak.centos-docker/tasks/main.yml` carries the round's
first two tasks verbatim (both gated off on a non-CentOS host, so nothing
mutates the machine); the role's `pip: docker-compose` and `service: docker`
tasks are dropped because they mutate the host and their output is not part
of the divergence. `playbook.yml` is the round's play with localhost in place
of `testhost`.
