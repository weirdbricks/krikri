# #1633 - community.crypto.openssl_publickey: check mode with an unparsable public key

- Issue: https://github.com/weirdbricks/krikri/issues/1633
- Playbook: kpg `000026-multi-openssl_publickey-happy` (generated from seed 1795148473)
- Class: output gap (check mode)

**What diverged.** The generated playbook points `path:` and
`privatekey_path:` at two of the fixture's locked destination files
(`/tmp/kpg-work/dest-0444.txt` and `/tmp/kpg-work/dest-0440.txt`, both plain
text). In check mode real reports `changed:` for that task: `PublicKey.check()`
reads and parses the public key that is already there first, and an
unparsable one is simply "different" - the private key is never loaded, so
the bad passphrase never surfaces. krikri loaded the private key anyway and
failed with `Wrong passphrase provided for private key, ...`. The play after
it also differed (`when: kpg_task_0 is succeeded`).

PublicKey.dump() runs before check() in the module, so the registered
result carries the construction-time empty `fingerprint`/`diff` plus the
current file content (`publickey`), which is what this case pins.

**Fixture.** The two locked destinations are copied verbatim (content and
mode) from `Fixtures::UNUSUAL_FILES`; the task's YAML is the generated
playbook's, changed only to resolve `path`/`privatekey_path` under the
scratch tree via `playbook_dir` and to drop the delegate the fixture's
second host does not have here.
