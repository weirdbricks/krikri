# #1609 - jedimt.haproxy: missing INJECT_FACTS_AS_VARS block in check mode

- Issue: https://github.com/weirdbricks/krikri/issues/1609
- Role: `jedimt.haproxy` (ubuntu host, round `logs___1795085158`)
- Class: check-mode output gap (missing stderr)

**What diverged.** The same role, task and template as
`1596-jedimt-haproxy-hostvars-fact`, run with `--check`: real ansible still
prints the `[DEPRECATION WARNING]: INJECT_FACTS_AS_VARS` block - Origin'd at
`templates/haproxy.j2` and emitted before the render raises on the undefined
`k8s_master` group - while krikri printed none. Check mode changes nothing
about the reading of `hostvars[inventory_hostname]['ansible_default_ipv4']`:
task args are finalized (and the template lookup runs) before either engine
looks at check mode.

**Why.** Same root cause as #1596: the deprecation rides the tagged fact
VALUE, so fetching one back out of a `hostvars[...]` entry warns, and
krikri's deprecation probes only recognised bare fact NAMES. `--check` adds
no separate trigger; this case exists because the corpus replay of #1596 runs
without flags and never exercised the check-phase transcript the round
recorded.

**Fixture.** Identical input to the #1596 case (`roles/jedimt.haproxy` is the
role's YAML verbatim, the apt task dropped because it mutates the machine);
only `flags.txt` differs, pinning `--check`.
