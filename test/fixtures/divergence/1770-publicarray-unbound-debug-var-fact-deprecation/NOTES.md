# 1770 - publicarray.unbound: `debug: var:` fact read loses its deprecation block

- Issue: https://github.com/weirdbricks/krikri/issues/1770
- Role: `publicarray.unbound` (ubuntu host, round `round29925810`)
- Class: output gap (missing stderr)

**What diverged.** Real ansible printed an
`[DEPRECATION WARNING]: INJECT_FACTS_AS_VARS` block for each of the role's
two `debug: var:` fact reads (`tasks/main.yml:16:10` for
`ansible_service_mgr`, `:47:10` for `ansible_env.PATH`); krikri printed
neither, while it already matched the `when:`-clause blocks around them.

**Why.** krikri resolves `debug: var:` inside the action plugin, after the
task-param substitution sites that normally carry a read's Origin have been
popped, so the manager registers a bare `var` site with no TEXT. A fact
read's Origin is only claimed for a site whose template names the read
variable, so the read was dropped instead of being blamed on the `var:`
value token real anchors it at.

**Case.** The two role tasks are verbatim, with `no_log: true` added: they
print the fact VALUES (`systemd`, the runner's collected `PATH`), which are
host-dependent, while the deprecation block this case pins is printed either
way. `expected.out` was captured from real ansible-core 2.21.6 with
`bin/krikri-capture-case`; `inventory.ini` pins the interpreter on the
`[local]` host.
