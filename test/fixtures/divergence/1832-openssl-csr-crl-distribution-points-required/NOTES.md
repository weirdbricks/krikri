# #1832 - kpg openssl_csr (check mode): crl_distribution_points sub-spec error

- Issue: https://github.com/weirdbricks/krikri/issues/1832
- Playbook: `000021-multi-synchronize-chaos` (krikri-playbook-generator)
- Class: output gap (validation error selection, check mode)

**What diverged.** `community.crypto.openssl_csr` declares
`required_one_of: [("full_name", "relative_name", "crl_issuer")]` on the
`crl_distribution_points` option itself, and ansible-core's
`_validate_sub_spec` applies that group to every element dict, so the
generator's `crl_distribution_points: [{}]` is rejected during argument
validation with `one of the following is required: full_name,
relative_name, crl_issuer found in crl_distribution_points`. krikri's
generated argument-spec table (`data/argspecs.json`) captured only the
sub-options and dropped the parent option's own constraint groups, and
`ArgspecValidator.check_sub_spec` only enforced nested `required:`
keys, so validation passed and the module body failed on its own
`privatekey_path` check instead.

**Fixture.** The issue's `Openssl_csr #21.1` task verbatim, with
`delegate_to: target2` dropped (the local inventory host stands in for
it) and the path moved inside the case's scratch tree. The task fails in
check mode before any key or CSR is touched, so the case writes nothing.

`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6.
