# #1660 - deprecation_warnings = False did not silence deprecations

- Issue: https://github.com/weirdbricks/krikri/issues/1660
- Class: output (deprecation blocks printed where real prints none; the task
  results themselves are identical)

**What diverged.** krikri neither read `[defaults] deprecation_warnings` nor
`ANSIBLE_DEPRECATION_WARNINGS`, so every deprecation block printed no matter
what the project configured - including the one-time
`Deprecation warnings can be disabled by setting deprecation_warnings=False in
ansible.cfg` hint, which named a setting krikri ignored. The issue's evidence
was a module deprecation (`Importing 'to_text' from
'ansible.module_utils._text' is deprecated`, from
`amazon.aws.ec2_metadata_facts`), unreachable in a corpus case because that
collection is not installed for real ansible on this box.

**Fixture.** The same class of deprecation, expressible in both engines: a
local module (`library/deprecation_probe.py`) that imports two of the
deprecated `ansible.module_utils._text` names, plus the playbook-load
deprecation for a mapping-form `action:` keyword. `env.txt` sets
`ANSIBLE_DEPRECATION_WARNINGS=False`, the form both engines read ahead of the
ini. Real 2.21.6 then prints no hint and no block while the two tasks still
return `ok:`; before the fix krikri printed the hint plus three deprecation
blocks here.

The ini spelling (`[defaults] deprecation_warnings = False`) and its
env-over-ini precedence are pinned by `test/unit/ansible_config_test.cr`; this
case covers the console wiring.

`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6.
