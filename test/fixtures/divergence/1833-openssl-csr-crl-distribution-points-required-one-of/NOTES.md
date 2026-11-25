# #1833 - openssl_csr's crl_distribution_points element must satisfy its own required_one_of

- Issue: https://github.com/weirdbricks/krikri/issues/1833
- Playbook: krikri-playbook-generator `000021-multi-synchronize-chaos.yml`
  ("Openssl_csr #21.1"), kpg class `openssl_csr: check mode, chaos`
  (`Hallucinate on t0:copy_links`, `Hallucinate on t0:dest`,
  `Hallucinate on t0:perms`, ...)
- Class: output text - the task fails on both engines, but with a
  different message

**What diverged.** The generated task passes `crl_distribution_points:
[{}]` (an empty distribution point) alongside `privatekey_content:` and a
pile of invented values. Real ansible prints

```
[ERROR]: Task failed: Module failed: one of the following is required: full_name, relative_name, crl_issuer found in crl_distribution_points
```

while krikri printed

```
[ERROR]: Task failed: Module failed: state is present but all of the following are missing: privatekey_path
```

and both failed results' `...ignoring` kept the rest of the play identical.

**Why krikri had it wrong.** community.crypto's openssl_csr declares
`required_one_of: [full_name, relative_name, crl_issuer]` and
`mutually_exclusive: [full_name, relative_name]` INSIDE the
`crl_distribution_points` option spec. Ansible's `_validate_sub_spec` reads
those group checks off the parent option spec
(`value.get('required_one_of')`) and runs them over each dict element
before the module body - so the empty element is the first error, ahead of
openssl_csr's own `required_if`/private-key handling. `gen_argspecs.py`
captured only `options`/`types` out of an option spec, so the checks never
reached `data/argspecs.json` and the validator had nothing to apply;
validation passed and krikri fell through to the plugin, which requires
`privatekey_path` and ignores `privatekey_content`.

**Fix.** `gen_argspecs.py` now carries an option spec's `mutually_exclusive`
and `required_one_of` into its entry, and `ArgspecValidator`'s sub-spec walk
applies them per element in Ansible's order (mutually_exclusive, required,
required_one_of, then nested specs), suffixing `found in
crl_distribution_points` like every other nested-spec error. The baked
entry for community.crypto.openssl_csr was updated by hand to match what
the generator now emits (this box cannot regenerate the whole table: it
lacks modules the pinned capture environment had). That change landed on
main under issue #1832 (same generator divergence, different generated
playbook), together with its own corpus case; this directory keeps the
issue #1833 playbook pinned as the case for this report.

**Fixture.** The failing task is copied verbatim except that `path:`
points at the case's own file (a case may not touch the machine),
`kpg_owner`/`kpg_group` are pinned in the play's vars instead of `-e`,
`delegate_to` is dropped so it runs on localhost, and the round's
`when: kpg_task_0 is not skipped` gate goes with the synchronize task it
referred to. `expected.out` was captured with `bin/krikri-capture-case`
from real ansible-core 2.21.6 + community.crypto 3.1.1.
