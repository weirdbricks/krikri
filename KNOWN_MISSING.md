# Known Missing / Known Gaps

The goal is 100% behavioral compatibility with `ansible-playbook`,
verified against real runs rather than assumed - not "cover the common
cases." This file tracks what's actually missing today. It intentionally
does **not** carry implementation history or root-cause narrative for
fixed bugs - that detail lives in `git log` commit messages, written at
the same level of detail per commit; search there (e.g. `git log --all
--grep=auth_socket`) rather than in a second, easily-stale copy here.

**Currently at `0.9.171`.**

---

**No known cross-cutting engine gap is open right now** - but that status
is continuously re-earned, not permanent. Each real-host benchmark round
against a new production Ansible role tends to find more (most recently
15 in the `linux-system-roles` round, `0.9.158`-`0.9.171`: depth-unaware
operator parsing that could stack-overflow, block-level `vars:` never
parsed, a missing `d()` filter alias, dict/array literals unsupported
outside a `+` operand, among others - `git log --oneline --grep=
"0\.9\.1[5-7][0-9]" -E` for the full list). Treat "no gap remains open"
as "none is known right now," not as a claim the search is finished.

Narrow, deliberately-scoped items:

- **`meta:`** supports only `clear_facts`. `end_play`/`flush_handlers`/
  `refresh_inventory`/`clear_host_errors` act on execution-flow machinery
  this engine models differently, and are rejected at parse time rather
  than silently ignored.
- **`docker_*` `api_version:`** is deliberately not planned - the
  underlying `docr` client uses unversioned endpoint URLs throughout, so
  pinning a version means touching every endpoint in a separate shard.
  The unversioned URLs negotiate fine against current Docker and Podman.
  Revisit only if a real playbook actually needs the pin.
- **Cloud plugins** (`ec2`, `s3_bucket`, `azure_rm_*`) and inventory
  *plugins* (`aws_ec2.yml` et al.) remain explicitly lowest-ROI and are
  not planned.
- **Role-private custom modules** (a role's own `library/*.py`, outside
  the `ansible.builtin`/`community.*`/etc. plugin set this engine ships)
  aren't executed - there's no generic arbitrary-Python-module runner. A
  task using one is skipped with "Plugin not available" rather than
  crashing the run, but anything downstream that depends on its result
  sees that value as undefined, which can cascade into broader task-
  status divergence from real Ansible. Seen repeatedly benchmarking
  `linux-system-roles`: `sr_fingerprint`, `timesync_provider`,
  `kernel_settings_get_config`, `blivet`.
- **`crystal-mysql`'s wire-protocol driver has no `unix_socket`/
  `auth_socket` auth support** - only `mysql_native_password`/
  `caching_sha2_password`. A role connecting via `login_unix_socket:`
  with no password (a common, real MariaDB/Debian-packaging pattern)
  fails every `mysql_*` plugin call. Real low-level driver work (raw
  socket fd access, plugin negotiation) - not fixed; see `git log --all
  --grep=auth_socket` for the investigation.
- **`to_datetime()`/timedelta arithmetic beyond subtraction** stayed
  narrowly scoped to what real roles have needed so far - revisit if a
  role needs more.

`postgresql_privs` is the one per-plugin scope-cut list this project
originally tracked that reached **zero open items** (`0.9.84`) - every
`type:` real Ansible's module supports is implemented, including
`function`/`procedure` signatures and `default_privs`. New scope cuts get
found continuously through real-host benchmark rounds against production
Ansible roles instead of from a static pre-planned list; `git log` for
each round's own commits for what it left open, if anything.
