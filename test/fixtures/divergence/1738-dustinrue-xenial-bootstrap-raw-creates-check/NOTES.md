# #1738 - dustinrue.docker: raw: with creates: reported changed under --check

- Issue: https://github.com/weirdbricks/krikri/issues/1738
- Role: `dustinrue.docker` (dependency `dustinrue.xenial-bootstrap`, rocky
  host, round `logs___1795423891`)
- Class: check-mode behaviour (task verdict and recap counters)

**What diverged.** Under `--check` the dependency role's "Install python 2.7
on xenial" task (`raw:` with `args: {creates: /usr/bin/python}`) printed
`skipping: [testhost]` on real ansible and `changed: [testhost]` on krikri,
shifting the recap from `ok=1 changed=0 skipped=1` to `ok=2 changed=1
skipped=0`.

**Why.** raw is an action plugin with no module side. Its `run()` returns
`{'skipped': True}` the moment the task is in check mode, before it reads
`_raw_params`, `executable` or any other argument
(`ansible/plugins/action/raw.py`, live-verified against ansible-core 2.21.6),
so `creates:`/`removes:` never reach the command module's gate logic. krikri
aliases `raw:` onto the command/shell plugins, whose own check-mode branch
does honor those gates and reports a gated would-run command as `changed`.

**Fix.** The executor answers check mode for a raw task with real's bare
`{skipped, failed, changed}` shape before dispatching the aliased shell
plugin, the same shape raw's missing-`_raw_params` check-mode path already
used.

**Fixture.** The role's task verbatim, run against localhost under `--check`
(`flags.txt`), on a host where `/usr/bin/python` does not exist so the gate
would have let the command through. `expected.out` was captured with
`bin/krikri-capture-case` from real ansible-core 2.21.6.
