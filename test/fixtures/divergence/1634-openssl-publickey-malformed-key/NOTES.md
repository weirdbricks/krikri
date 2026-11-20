# #1634 - kpg openssl_publickey (happy): malformed private key message

- Issue: https://github.com/weirdbricks/krikri/issues/1634
- Playbook: `000026-multi-openssl_publickey-happy` (krikri-playbook-generator)
- Class: output gap (module error message)

**What diverged.** krikri's native key loader reproduced the pre-50
`cryptography` ValueError text (`('Could not deserialize key data...',
[<OpenSSLError...>])`) for an unparsable private key. The pinned
ansible-core 2.21.6 reference hosts install cryptography 50, which parses
the PEM framing in Rust before OpenSSL and raises `ValueError: Unable to
load PEM file. ... MalformedFraming`; the module's `load_privatekey`
prefixes that. The generator's private key fixture is plain text
(`kpg locked dest...`), so no PEM framing is found at all.

**Fixture.** The issue's `Openssl_publickey #26.0` task verbatim, with the
generator's `/tmp/kpg-work/dest-0440.txt` fixture written by a preceding
copy task so the case only writes inside its scratch tree.

`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6 + cryptography 50.0.2 inside the generator's Debian
reference image (the dev host's cryptography is older and records the
stale message).
