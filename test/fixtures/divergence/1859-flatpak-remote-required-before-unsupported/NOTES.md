# #1859 - kpg flatpak_remote (check mode): required argument before unsupported parameter

- Issue: https://github.com/weirdbricks/krikri/issues/1859
- Playbook: `000028-multi-flatpak_remote-chaos` (krikri-playbook-generator)
- Class: output gap (argspec error selection, check mode)

**What diverged.** The generator's `Flatpak_remote #28.0` task carries both a
typo'd parameter key (`nmae`) and no required `name`. Real ansible reports
`missing required arguments: name`; krikri reported the unsupported-parameter
message. ansible-core's `ArgumentSpecValidator.validate` appends its
unsupported-parameters error LAST (after the required, type and choice
checks) and `AnsibleModule` only ever surfaces `errors[0]`, so a missing
required argument always wins over a typo'd key. `plugins/flatpak_remote.cr`
(and `plugins/flatpak.cr`, whose task carries the `on_dependencies` typo of
`no_dependencies`) ran the unsupported check first.

**Fixture.** The issue's `Flatpak_remote #28.0` task verbatim, with
`delegate_to: target2` / `delegate_facts` dropped (the local inventory host
stands in for target2). Validation fails before the module body, so the case
touches no flatpak installation even without `--check`; `flags.txt` keeps the
round's check mode.

The same kpg playbook was filed as issue #1858, whose case
(`1858-flatpak-remote-required-before-unsupported`) landed with the plugin
fix; this case pins the #1859 issue's own transcript of it.

`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6.
