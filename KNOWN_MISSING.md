# Known Missing / Known Gaps

The goal is 100% behavioral compatibility with `ansible-playbook`,
verified against real runs rather than assumed - not "cover the common
cases." This file tracks what's actually missing **today**. It does
**not** carry implementation history or root-cause narrative for fixed
bugs - that lives in `git log` commit messages; search there (e.g.
`git log --all --grep=auth_socket`) rather than in a second, easily-
stale copy here. When an item below gets fixed, delete its bullet
instead of leaving a "fixed in 0.9.x" note - the commit that fixes it
is the record.

**Currently at `0.9.476`.**

---

## Real gaps (worth revisiting)

- PLAY RECAP has no `ignored=` counter - a task caught by
  `ignore_errors: true` shows up as `failed=0` (correct - the ignore
  itself works, execution continues) but the recap line has no count of
  how many failures were ignored, unlike real Ansible's own
  `ignored=N`. Purely cosmetic (found via `buluma.openssl`, round 150) -
  the actual ignore-and-continue behavior matches exactly, only the
  summary line's field is missing.

Note: 0.9.474's entry here claiming `openssl_dhparam:`/
`openssh_keypair:` had "no plugin, no `AVAILABLE_PLUGINS` entry" was
itself wrong; both had been implemented, if more simply, since
`0.9.121`/`0.9.125`. 0.9.475 upgraded both to more fully match their
real modules regardless - see `git log`.

## Explicit scope cuts (not gaps to fix - documented so they aren't re-litigated)

- `config`/`inventory_hostnames` lookups - architecturally out of scope
  (would require modeling Ansible's own config-resolution/inventory
  internals, not just a data lookup).
- `win_*` filters - Windows-only, irrelevant to this project's targets.
- `community.crypto.x509_certificate` / real CA issuance - a full,
  correct X.509 CA implementation is out of scope for a single module;
  blocks `robertdebock.ca` specifically. Note (0.9.475): the sibling
  `dirless/x509-crystal` shard already does self-signed/CA-signed X.509
  cert generation (ECDSA/RSA) via direct `LibCrypto` bindings - the
  expensive part of this scope cut - so a future attempt at this module
  should start there rather than from scratch, though it's not a
  drop-in (still needs CSR-based issuance from arbitrary subject/SAN
  fields, `state=absent`, revocation, etc. that shard doesn't expose).
- `community.general.vdo` - unimplemented; untestable so far, no real
  role sets a non-empty `vdo_devices`.
- `gluster.gluster.gluster_volume` - unimplemented; causes a cosmetic
  parse-time task-drop vs. real Ansible's "skipping" recap line, not a
  runtime crash.
- `community.general.zypper_repository` - unimplemented; same cosmetic
  parse-time-drop class, no zypper/openSUSE host ever tested.
- `ansible.posix.firewalld` - only `offline: true, permanent: true`
  (`firewall-offline-cmd`, no live daemon needed) is implemented, and
  `zone:` is required rather than defaulting to the system default zone
  - both already documented at length in `plugins/firewalld.cr`'s own
  header comment. Reconfirmed live on Rocky 9.6 (0.9.474): real
  Ansible's own module needs neither `zone:` nor `offline: true` (it
  silently falls back to offline mode when it can't reach a live
  firewalld D-Bus connection, and defaults `zone:` to the system
  default zone), so a bare `port=8080/tcp permanent=yes state=enabled`
  that real Ansible accepts still needs both spelled out for this
  plugin.

---

For the fixed-bug history (150+ rounds of real-host benchmarking against
production Ansible roles), see `git log`.
