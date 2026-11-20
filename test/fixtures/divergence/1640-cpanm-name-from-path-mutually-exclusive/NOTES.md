# #1640 - kpg cpanm (happy path): mode=new argument conflict reported as a cpanm run

- Issue: https://github.com/weirdbricks/krikri/issues/1640
- Playbook: `000016-multi-cpanm-happy` (krikri-playbook-generator)
- Class: behaviour (the module ran at all where real refuses to)

**What diverged.** The task passes both `name: nsreaz` and a `from_path`.
Real ansible fails immediately with `Parameters 'name' and 'from_path' are
mutually exclusive when 'mode=new'`; krikri ran cpanm against the
`from_path` file and failed with cpanm's own unpack error instead.

**Why.** community.general 9.0.0 made `mode=new` the default and gave it
its own argument validation: `name` and `from_path` are alternatives
there, and the check sits at the top of `__init_module__`, before cpanm
is even looked up. krikri implemented only the deprecated
`mode=compatibility` behaviour, so it had no `mode` parameter, no
mutual-exclusion check, and treated `from_path` as a fallback for `name`.

**Fixture.** The issue's `Cpanm #16.0` task verbatim, with the
generator's `/tmp/kpg-work` paths moved under `playbook_dir` (nothing is
read there: the argument check fails before any path or cpanm access) and
`delegate_to` dropped so it runs on the local host.

`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6 + community.general 12.5.0.
