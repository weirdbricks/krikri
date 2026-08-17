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

**Currently at `0.9.470`.**

---

## Real gaps (worth revisiting)

- **`expect:` plugin limitations**: no session leader (`setsid`), so
  some interactive programs that check for a controlling TTY behave
  differently than under real `pexpect`; no `echo: false` (response
  values are not masked in any logging/output); only the first
  response in a `responses:` list is ever sent (real Ansible sends each
  response in sequence as the corresponding pattern matches again).
- **`mount_options`'s `first` filter on an empty sequence** produces a
  real, confirmed divergence from real Ansible's own error/behavior.
  Tied to a broader deferred design question (a proper strict-undefined
  mode) rather than a one-line filter fix - see git log around
  `mount_options` for the repro.
- **`to_datetime()`/timedelta arithmetic** only supports subtraction.
  Deliberately narrow - no real role has needed addition/multiplication
  yet.

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

---

For the fixed-bug history (150+ rounds of real-host benchmarking against
production Ansible roles), see `git log`.
