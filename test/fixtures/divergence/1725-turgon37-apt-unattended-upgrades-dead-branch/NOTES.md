# 1725 - Turgon37.apt: the PLAY RECAP tail loses an INJECT_FACTS_AS_VARS block

- Issue: https://github.com/weirdbricks/krikri/issues/1725
- Role: `Turgon37.apt` (ubuntu), round `logs___1795423891`
- Evidence: `logs___1795423891/Turgon37_apt/compare_cold.diff` (block 59)

## What diverged

Real ansible ends the run with one more deprecation block than krikri: the
`INJECT_FACTS_AS_VARS` warning Origin'd at the role's own
`defaults/main.yml:377` (`apt__unattended_upgrades_mail_sender: 'root@{{ ansible_fqdn }}'`).

The role's `apt__configurations` default renders every setting's `content`,
and the `50unattended-upgrades` entry keeps

```jinja
{% if apt__unattended_upgrades_mail is defined %}
Unattended-Upgrade::Mail "{{ apt__unattended_upgrades_mail }}";
Unattended-Upgrade::Sender "{{ apt__unattended_upgrades_mail_sender }}";
{% endif %}
```

`apt__unattended_upgrades_mail` is unset (the default is commented out), so
the branch never renders and the Sender line never reaches the file. jinja2
still reads `apt__unattended_upgrades_mail_sender` there: its compiler hoists
one `resolve()` per name a frame loads to the frame's entry, and `{% if %}`
shares the root frame - the read renders that default's own
`root@{{ ansible_fqdn }}`, which trips the deprecation at the default's
declaration. krikri resolves names lazily, so the discarded branch made no
read and printed no block.

The round's other reported block (13, "Remove unknown installed apt confs"
item order) is not a krikri gap: the items are `find:` results in readdir
order, which differs between the two hosts' filesystems (ext4's directory
hash seed); both engines reproduce identical order on one host.

## Case

`roles/Turgon37.apt/` carries the real role's `defaults/main.yml`,
`tasks/configure-settings.yml`, `tasks/types/setting.yml` and
`templates/setting.conf.j2` verbatim. `playbook.yml` runs
`configure-settings.yml` with `apt__configuration_include_directory` pointed
at a scratch directory inside the case and captured in `--check` mode, so the
setting templates never touch `/etc/apt/apt.conf.d` (the role's
`owner: root` would fail as a normal user). `expected.out` is
`bin/krikri-capture-case`'s capture from ansible-core 2.21.6.
