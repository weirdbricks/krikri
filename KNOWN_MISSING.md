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

**Currently at `0.9.474`.**

---

## Real gaps (worth revisiting)

- `ansible.builtin.openssl_dhparam` / `ansible.builtin.openssh_keypair` -
  unimplemented (no plugin, no `AVAILABLE_PLUGINS` entry). Found via the
  new `ansible` ad-hoc CLI's first real-host module round (0.9.473) -
  neither had ever been exercised by a benchmarked role before.
- `pamd:`'s `state=updated` (and the related `before`/`after`) modes -
  the plugin explicitly rejects them today ("state must be 'present' or
  'absent' ... state: updated/before/after are not implemented"), but
  `state=updated` (modify an existing PAM stack line in place) is
  arguably the module's most common real-world use, more so than
  `present`/`absent`. Found via the same 0.9.473 ad-hoc round.

## Explicit scope cuts (not gaps to fix - documented so they aren't re-litigated)

- `config`/`inventory_hostnames` lookups - architecturally out of scope
  (would require modeling Ansible's own config-resolution/inventory
  internals, not just a data lookup).
- `win_*` filters - Windows-only, irrelevant to this project's targets.
- `community.crypto.x509_certificate` / real CA issuance - a full,
  correct X.509 CA implementation is out of scope for a single module;
  blocks `robertdebock.ca` specifically.
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
