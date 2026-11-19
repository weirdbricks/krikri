# #1572 - ucr.mailman3 prints loop items real ansible censors

- Issue: https://github.com/weirdbricks/krikri/issues/1572
- Role: `ucr.mailman3` (ubuntu host, round `logs___1795043292`)
- Class: output gap (and a `no_log` leak: structured output, tier 2)

**What diverged.** The role's `set mailman3 debconf options` loops over
`mailman3_debconf` with `no_log: "{{ this_no_log }}"`, where `this_no_log` is
`true if item.vtype == 'password'`. Real resolves `no_log` per loop ITEM, so
the four password iterations print `ok: [testhost] => (item=(censored due to
no_log))`; krikri resolved it once against a context with no `item` bound,
printed every dict in full and leaked the passwords.

**Fixture.** The task is the role's `tasks/debconf.yml` third task verbatim
(loop, `vars:`, `no_log:`, item list) and `defaults/main.yml` carries the
role's real `mailman3_debconf` list. Two adaptations:

- the module is `ansible.builtin.debug` instead of `debconf`: `debconf` is not
  installed for ansible-core 2.21.6 here and writing dpkg debconf selections
  would mutate the machine, which a corpus case must never do;
- `changed_when:`/`register:` are dropped with it (the register feeds the
  role's next `changed_when`, and the transcript already pins the censoring).

The password values are the literals the issue body shows for the leaked
items; the role's own `{{ mailman3_*_pass }}` variables are spelled out so the
case needs no vault.
