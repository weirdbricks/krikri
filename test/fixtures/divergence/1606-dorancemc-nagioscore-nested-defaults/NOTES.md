# #1606 - dorancemc.ansible_nagioscore: nested defaults/main/ subdirectories ignored

- Issue: https://github.com/weirdbricks/krikri/issues/1606
- Role: `dorancemc.ansible_nagioscore` (round `round29918157`, check phase)
- Class: check-mode behavioural bug (task result, exit code)

**What diverged.** The role keeps its defaults in `defaults/main/`
subdirectories (`defaults/main/nagios/vars.yaml` holds
`install_pnp4nagios: true`, `defaults/main/nrdp/vars.yaml` holds the nrdp
switches) beside `defaults/main/main.yml`. ansible-core's DataLoader walks a
role's `defaults/main/` directory RECURSIVELY, so those files are loaded;
krikri's flat `*.yml` glob read only the top level, leaving
`install_pnp4nagios` undefined. The role's own
`Install rrdtool packages` task guards on
`when: install_pnp4nagios | bool`, so krikri failed there
(`'install_pnp4nagios' is undefined`) and stopped the play with exit code 2,
while real ansible reported it `ok`/`changed` and ran on.

**Fixture.** The two nested defaults files the switch and the probe read, plus
the guard as a `debug:` probe. The real task is an `ansible.builtin.apt`
package install, which cannot run in-process (it reports `changed` or `ok`
depending on what the runner already has), so the case pins the guard's own
input instead - both engines must resolve the nested defaults and report the
same values. No `inventory.ini`: the probe is a controller-side action and
gathering is off, so no interpreter is discovered.
