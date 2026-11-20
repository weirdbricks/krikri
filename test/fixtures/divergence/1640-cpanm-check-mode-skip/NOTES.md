# #1640 - kpg cpanm (happy path): the module ran in check mode where real skips it

- Issue: https://github.com/weirdbricks/krikri/issues/1640
- Playbook: `000016-multi-cpanm-happy` (krikri-playbook-generator)
- Class: behaviour (--check ran a module that declares no check-mode support)

**What diverged.** Under `--check` real ansible skips every
`community.general.cpanm` task; krikri executed the module. Because the
generator playbook registers the task and gates the next one on
`kpg_task_0 is succeeded` (true for a skipped task), the skip cascade
changed the rest of the play too.

**Why.** cpanm declares `check_mode: support: none`, so its
`AnsibleModule` exits skipped (`remote module (community.general.cpanm)
does not support check mode`) after argument-spec validation but before
the module body. krikri's plugin had no such gate, so it ran cpanm in
check mode. The same gate must also run BEFORE the module body's
`mode=new` argument check: this fixture keeps the `name`+`from_path`
pair that check rejects, so getting the order wrong surfaces as that
argument error instead of the skip.

**Fixture.** The issue's `Cpanm #16.0` task verbatim, with the
generator's `/tmp/kpg-work` paths moved under `playbook_dir`, on
`--check` (`flags.txt`), with `delegate_to` dropped so it runs on the
local host.

`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6 + community.general 12.5.0.
