# #1591 - Anthony25.postfix: ansible.utils.ipwrap unknown under its FQCN

- Issue: https://github.com/weirdbricks/krikri/issues/1591
- Role: `Anthony25.postfix` (rocky host, round `logs___1795085158`, round29918156)
- Class: behavioural bug (ansible exit 0, krikri exit 2)

**What diverged.** The role's `Generate Postfix configuration` task renders
`templates/etc/postfix/main.cf/ansible.j2`, whose `basic_options.j2` builds
`mynetworks` with

```
{{ ', '.join((postfix_mynetworks + ['127.0.0.0/8','::ffff:127.0.0.0/104', '::1/128']) | map('ansible.utils.ipwrap') | list) }}
```

Real ansible resolves `ansible.utils.ipwrap` against the installed
ansible.utils collection and wraps the IPv6 entries (`[::ffff:127.0.0.0]/104`,
`[::1]/128`); krikri rejected the name as unknown, failing the task and
aborting the play (exit 2 against real's 0).

**Fixture.** The role's `Generate Postfix configuration` task verbatim
(`with_items: [main.cf, master.cf]`, both `.j2` trees included), with only the
destination redirected from `/etc/postfix/` to a scratch `out/` directory (and
a `file:` task creating it) since the case tree must not mutate the host. The
role defaults are loaded as `vars_files`, and the facts the template reads
(`ansible_fqdn`/`ansible_hostname`/`ansible_domain`/`ansible_local`) are pinned
in the play so the rendered file is machine-independent.

`ansible.cfg` disables `deprecation_warnings`: real 2.21.6 emits Python
module_utils import deprecations for every rendered template here, and those
are ansible's own runtime artifacts, not output krikri can produce. This case
also exposed two `format_v6` bugs (`::1` rendered as `:1`, IPv4-mapped
addresses as `::ffff:7f00:0`), so the fixture also pins the exact mynetworks
spelling.

**Fix.** `IpAddrCore.ipwrap` (shared by the hand-rolled `FilterEngine` and the
krikri-jinja registration) mirrors the collection plugin's type check and
per-element pass-through, and only the FQCN spelling resolves (bare `ipwrap`
stays unknown, #134).
