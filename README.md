# Crystal Ansible - Ansible-Compatible Automation Tool

**A single-binary automation tool that runs real Ansible playbooks - written in Crystal**

[![Version](https://img.shields.io/badge/version-0.9.358-blue)](https://github.com/weirdbricks/crystal-ansible)
[![Compatibility](https://img.shields.io/badge/ansible--compatibility-high-brightgreen)](https://github.com/weirdbricks/crystal-ansible)
[![Language](https://img.shields.io/badge/language-Crystal-black)](https://crystal-lang.org)

---

## 📋 Project Overview

Crystal Ansible parses and executes standard Ansible playbook YAML directly,
without Python or the real `ansible-core` installed anywhere - it's a single
compiled binary plus a directory of plugin binaries. It supports:

- **Ansible-syntax playbooks** - roles, imports/includes, blocks, loops,
  handlers, vault, `become:`, Jinja2 templating - not just a handful of
  modules bolted onto a task runner
- **66 built-in plugins** covering package/service/file management, users
  and groups, Docker, MySQL/MariaDB, PostgreSQL, firewalls, archives,
  SELinux/PAM, hostname management and more (see below)
- **Single binary deployment** - no dependencies, no Python required on
  either the controller or the target
- **Verified compatibility, not assumed compatibility** - every plugin's
  behavior is checked against real `ansible-playbook` output, and a
  Docker-based compatibility harness (`compat/`) runs the same playbooks
  through both engines side by side and diffs the resulting state

See [KNOWN_MISSING.md](KNOWN_MISSING.md) for what's still missing, and
`git log` for implementation history.

---

## ✨ Features

### Core Engine
- ✅ YAML playbook parser (Ansible syntax): plays, tasks, handlers, `vars:`
- ✅ Inventory: static INI + YAML, and dynamic (script-based) inventory
- ✅ SSH connection pooling, plus local (`ansible_connection: local`) execution
- ✅ Variable substitution `{{ vars }}` with a Jinja2 filter pipeline
  (chained filters, e.g. `{{ x | sort | join(',') }}`)
- ✅ Conditionals `when:` (`==`, `!=`, `<`, `>`, `and`, `or`, `not`, `in`,
  dotted attribute access), including magic variables such as
  `inventory_hostname` in *bare* (non-`{{ }}`) conditions
- ✅ Facts gathering (90+ `ansible_*` variables), with
  `--gathering implicit|explicit|smart` and `meta: clear_facts`
- ✅ Roles (`roles/<name>/{tasks,handlers,vars,files,templates,defaults}`)
- ✅ `import_playbook` / `import_tasks` / `include_tasks` / `include_role`
- ✅ `block:` / `rescue:` / `always:` error handling
- ✅ Loops: `loop`/`with_items`, `with_dict`, `with_nested`,
  `with_sequence`, `with_indexed_items`, `with_fileglob`
- ✅ `until:` / `retries:` / `delay:` retry loops
- ✅ `async:` / `poll:` fire-and-forget/background task execution
- ✅ Handlers (`notify:`/`listen:`)
- ✅ `become:` / `become_user:` privilege escalation
- ✅ Ansible Vault: AES256 encrypt/decrypt, `--ask-vault-pass`,
  `--vault-password-file`
- ✅ `--check` (dry-run) and `--diff` (show file changes) modes
- ✅ `--tags` and `--limit` host/task filtering
- ✅ Task batching - consecutive independent tasks bound for the same
  remote host run in a single SSH round trip instead of one round trip
  per task, on by default (`--no-batching` to disable; see the
  Performance section below and `git log`'s `0.9.61`-`0.9.63` commits)

### Plugins (66 total)

**Files & templates:** `copy`, `template`, `file`, `lineinfile`,
`blockinfile`, `replace`, `stat`, `find`, `archive`, `unarchive`, `fetch`,
`get_url`

**Execution:** `command`, `shell`, `async_status`, `debug`, `assert`,
`fail`, `set_fact`, `pause`, `wait_for`, `uri`

**Packages:** `apt`, `apt_key`, `apt_repository`, `deb822_repository`,
`dnf`, `yum_repository`, `package`, `package_facts`, `pip`, `gem`

**Users, groups & access:** `user`, `group`, `authorized_key`, `cron`,
`getent`, `openssh_keypair`, `htpasswd`

**Services & system:** `service`, `systemd`, `service_facts`, `sysctl`,
`mount`, `modprobe`, `firewalld`, `ufw`, `facts`, `setup`

**Security:** `selinux`, `pamd`, `pam_limits`, `openssl_dhparam`

**Source control:** `git`

**Docker:** `docker_container`, `docker_image`, `docker_network`
(including `networks:`/`connected:` attachment and TLS-secured remote
daemon support)

**Databases:** `mysql_db`, `mysql_user`, `mysql_info`, `mysql_query`,
`postgresql_db`, `postgresql_user`, `postgresql_privs` (every `type:`
real Ansible supports, including `function`/`procedure` signatures and
`default_privs`)

---

## 🚀 Quick Start

### Prerequisites
- Crystal (tested with 1.20.x - see `shard.yml` for the declared minimum)
  ([install guide](https://crystal-lang.org/install/))
- The `ssh` CLI on `PATH` for remote targets (SSH connections use native
  `ssh`/`ControlMaster` under the hood, not a bundled library)

### Build & Run

```bash
# Install dependencies
shards install

# Build (all plugins + the CLI)
./build.sh

# Run a playbook
./bin/crystal-ansible playbook.yml

# With options
./bin/crystal-ansible --check --diff -i inventory.ini playbook.yml
```

---

## 📁 Project Structure

```
crystal-ansible/
├── crystal-play.cr              # CLI entry point
├── src/crystal_play/            # Engine: parser, task executor, SSH,
│                                 # inventory, roles, loops, vault, facts
├── plugins/                     # One binary per Ansible module (66 total)
├── spec/                        # crystal spec unit + integration tests
├── compat/                      # Docker-based real-ansible-playbook
│                                 # compatibility harness
├── testing/                     # Manual smoke-test fixture playbooks
├── build.sh                     # Build script (all plugins + CLI)
└── shard.yml                    # Dependencies
```

---

## 💡 Usage Example

```yaml
- name: Deploy app
  hosts: webservers
  become: true
  tasks:
    - name: install nginx
      package:
        name: nginx
        state: present
    - name: start nginx
      service:
        name: nginx
        state: started
      notify: reload nginx

  handlers:
    - name: reload nginx
      service:
        name: nginx
        state: reloaded
```

Supports standard Ansible playbook syntax. See the
[Ansible documentation](https://docs.ansible.com/) for playbook reference.

---

## 🎯 Command Reference

```bash
# Basic usage
./bin/crystal-ansible playbook.yml

# With inventory
./bin/crystal-ansible -i inventory.ini playbook.yml

# Dry-run (check mode)
./bin/crystal-ansible --check playbook.yml

# Show changes
./bin/crystal-ansible --diff playbook.yml

# Verbose output
./bin/crystal-ansible -v playbook.yml

# Limit to a host group/pattern, run only tagged tasks
./bin/crystal-ansible -l webservers -t deploy playbook.yml

# Vault-encrypted playbook/vars
./bin/crystal-ansible --ask-vault-pass playbook.yml
./bin/crystal-ansible --vault-password-file pass.txt playbook.yml

# Disable task batching (on by default - see Performance below)
./bin/crystal-ansible --no-batching -i inventory.ini playbook.yml

# Run each task against up to 10 hosts concurrently (default: 5, matching
# ansible-playbook; --forks 1 restores one-host-at-a-time)
./bin/crystal-ansible --forks 10 -i inventory.ini playbook.yml

# Fact gathering policy (default: implicit, matching ansible-playbook):
#   implicit - every play re-gathers
#   explicit - only plays that set gather_facts: true
#   smart    - each host gathered at most once per run
# Under smart, add `meta: clear_facts` to a play (e.g. after a reboot or a
# package install) to force the next play to gather again.
./bin/crystal-ansible --gathering smart -i inventory.ini playbook.yml

# Multiple options
./bin/crystal-ansible --check --diff -i production.ini playbook.yml
```

---

## ⚡ Performance

Measured against real `ansible-playbook`, not assumed - see `git log`
for the full methodology and results behind each number.

### vs. real Ansible, end to end

3 fresh Atlantic.net instances per row (Ubuntu 22.04, all destroyed
immediately after each run), the same 12-task mixed playbook (`file`,
`copy`+loop x10, `lineinfile`+loop x10, `shell`+`register`,
`command`+`register`, `changed_when`/`failed_when`, `stat`, `assert`,
`find`, `set_fact`, `debug`) run against both tools:

| | Fresh run | Idempotent re-run (median of 3) |
|---|---|---|
| Python `ansible-core` 2.19.4 (`forks=5` default) | 39.6s | 32.5s |
| `crystal-ansible` `--forks 1` (one-host-at-a-time) | 25.8s (1.54x) | 8.6s (3.8x) |
| `crystal-ansible` `--forks 3` | 14.4s (2.76x) | **3.5s (9.3x)** |

> Re-measured `0.9.171` (2026-08-10), replacing the `0.9.77`/`0.9.78`
> numbers this table carried for a long time - see `git log` for the
> engine-level performance work done in between. Same methodology (3
> fresh Atlantic.net `G3.1GB` instances per row, interleaved-by-row on
> this dev box against the same 3-node inventory), but the fresh-run
> gap between `--forks 1` and `--forks 3` is now much larger than the
> earlier snapshot showed (1.54x/2.76x here vs. 1.26x/1.22x before) -
> plausibly explained by this benchmark environment's own
> network latency/jitter mattering more now that only 3 target hosts are
> in play, letting higher forks overlap their SSH round trips more
> visibly. Treat the ratios as directionally solid, not as tightly
> reproducible absolute numbers.

The idempotent case is where native compiled modules plus batched,
forked SSH round trips show through cleanly: Python ships and starts a
fresh interpreter per task per host even when nothing needs to change,
while `crystal-ansible` finishes in single-digit seconds. Idempotent
reruns are also the more common real-world case for a config-management
tool.

`--forks` defaults to `5` since `0.9.78`, matching real
`ansible-playbook`'s own default - the two rows above measured `--forks 1`
and `--forks 3` explicitly, before that default flip. Pass `--forks 1` to
restore the original one-host-at-a-time behavior.

---

## ✅ Testing

```bash
# Unit + integration specs (crystal spec's own test runner)
crystal spec

# Ansible compatibility harness - runs the same playbooks through real
# ansible-playbook and crystal-ansible side by side and diffs the result
crystal run compat/run.cr
```

See [compat/README.md](compat/README.md) for what the compatibility
harness covers and how it works.

---

## 🚧 Limitations

See [KNOWN_MISSING.md](KNOWN_MISSING.md) for the live, per-round narrative
of what's still being found and fixed. `ROLES_TESTED.md` tracks the
current status of every Ansible Galaxy role that has been benchmarked
against a real host. The historical per-round detail (anything before
0.9.327) lives in `git log` - the project deliberately does not duplicate
it in this README.

### Recent rounds (rolling summary)

The last few benchmark rounds on real Atlantic.net host pairs vs. real
`ansible-playbook`. Each entry is one round, newest first; the bug list
is the headline only, see `KNOWN_MISSING.md` for full reproduction
context.

- **`0.9.358` (round 30) - `prometheus.prometheus.prometheus`, first
  new role tested since round 28's pushgateway follow-up.** Two real
  bugs found and fixed live: `fileglob`/`realpath` Jinja filters
  entirely missing from both evaluators (broke the role's own
  alert-rules-file-copy loop), and a Crinja fork parser bug where
  multi-arg parenthesized `is name(a, b)` TEST calls never split their
  arguments - broke the role's own `is version('2.7.0', '>=')`
  flag-selection guard, causing real prometheus to crash-loop on a
  deprecated CLI flag. Fixed upstream in the `weirdbricks/crinja` fork
  itself (tag `crystal-play-0.9.7`), the first fork-level parser fix
  this project has needed. Idempotent, service verified live.
- **`0.9.352` (round 27) - `prometheus.prometheus.blackbox_exporter`,
  first new role tested since round 26.** Two real gaps found and
  fixed live: `package.cr`'s `name:` parsing had the same Python-repr
  single-quoted-list JSON gap already fixed in `apt.cr` this round -
  an independent copy, and the one this role's own dependency-install
  task actually hits (`ansible.builtin.package:`, not `apt:`
  directly). Also `community.general.capabilities` had no plugin
  implementation at all - added a new `capabilities.cr`, ported from
  the real Python module's `getcap`/`setcap` parsing, needed by the
  role's own `cap_net_raw` grant for ICMP probing. Cold pass
  `failed=0` on both engines, service verified `active` and answering
  on its HTTP port.
- **`0.9.351` (round 26) - `prometheus.prometheus.alertmanager`, first
  new role tested since round 25.** 7 real engine bugs found and fixed
  live on a fresh `G3.2GB` Atlantic.net pair: a dict-literal `== {}`
  comparison always evaluating false, `include_role: vars:` not
  re-rendering the loaded role's task names (which also caused a real
  functional skip, not just a cosmetic display issue), and - the most
  severe - `check_mode:`/`diff:` crashing on a templated value and
  silently dropping an entire task file (lost the task that writes
  alertmanager's own config). Also added 4 missing Jinja
  tests/filters real role templates hit (`version_compare`, `any`/
  `all`, the `eq`/`lt`/`le`/`gt`/`ge` comparison-test aliases, and
  Ansible's `quote` filter). Cold pass `failed=0` on both engines,
  every expected task succeeded on crystal. One cosmetic-only gap
  (role-vars-sourced task names in banners) and one confirmed
  non-engine issue (the role's own systemd unit crash-loops real
  alertmanager 0.33.1 - reproduced independent of Ansible) both left
  documented, not fixed.
- **`0.9.350` (round 25) - live re-verification of 0.9.349 on a fresh
  Atlantic.net `G3.2GB` pair.** Confirmed all three bugs deferred in
  `0.9.348` and fixed in `0.9.349` hold up end-to-end: `Protect
  my.cnf` and `Ensure that the root password is present` both report
  `ok` on warm rerun, matching real `ansible-playbook`. Found and
  fixed one more live: `mysql_query` reported `changed`
  unconditionally for any DML statement, even a 0-row `DELETE` -
  real `community.mysql.mysql_query` only reports `changed` when
  `cursor.rowcount > 0`. Warm rerun now `ok=22 changed=0 skipped=6`
  vs python's `ok=21 changed=0 skipped=6` - `changed`/`skipped`
  counts match exactly.
- **`0.9.349` - follow-up on 0.9.348's three deferred warm-idempotency
  bugs.** `file` plugin's `follow:` param now flows through to both
  the chown write path (`follow_symlinks:`) and the attribute-read
  comparison path (a new `stat_follow` vs `lstat`), fixing the
  `Protect my.cnf` always-`changed` divergence; `mysql_user`'s
  `host_all: true` expansion now checks
  `password_already_matches?`/`plugin_matches?` before altering,
  matching the per-host path's idempotency. Also caught and fixed a
  real regression surfaced while doing this work: 0.9.348's own
  `with_community.general.flattened` no-value-sentinel fix had a
  missing `else`, so literal (non-templated) loop sources silently
  produced zero items again - the same class of bug 0.9.250/0.9.251
  fixed originally. Not yet live-reverified against a real host warm
  rerun; full `crystal spec` suite (1117 examples) passes.
- **`0.9.348` (round 24 role 2) - `devsec.hardening.mysql_hardening`
  collection form.** `ansible-galaxy collection install
  devsec.hardening` (the modern FQCN-shipped form of the
  standalone `os_hardening` role that round 24 role 1's
  standalone-form investigation revealed) ran cleanly end-to-end
  on a fresh 2-node `G3.2GB` Atlantic.net Ubuntu 22.04 pair
  (crystal `ok=22 changed=3 failed=0 skipped=6` vs real
  `ansible-playbook` `ok=22 changed=8 failed=0 skipped=6`; the
  ok/skipped counts are identical, the changed count differs
  because of three deferred warm-idempotency bugs). Two real
  engine bugs fixed in the process: a `role_loader.cr` tilde
  expansion bug (`File.expand_path("~/.ansible/collections")`
  didn't expand `~`, masking the whole default collections
  lookup for any CWD other than `$HOME` - same bug class
  already fixed for `~/.my.cnf` in 0.9.346 and for plugin
  path args in `BasePlugin#expand_tilde`), and a
  `with_community.general.flattened` literal-source-branch
  bug that pushed the engine's "no value" sentinels (`"undefined"`,
  `""`, `"[]"`, `"{}"`) as one loop item, crashing the
  downstream task that ran with `item = "undefined"` (the
  role's "Ensure that there are no users without password"
  task tried `DROP USER undefined@%`). Three more engine bugs
  found live (file-plugin chown-doesn't-follow-symlinks,
  mysql_user password-already-set-not-detected, and the chmod
  side of the same symlink-following issue) are deferred to a
  future round. The role exercises `dict2items` and
  `items2dict` filters from 0.9.347 end-to-end for the first
  time on a real role, via the role's own
  `mysql_hardening_options | dict2items | rejectattr(...) |
  items2dict` chain - the filter works correctly in this
  live context.
- **`0.9.347` (doc-only round 24 cleanup + filter implementation)** -
  two unrelated things landed in this release: a small follow-up to
  the round-24 `konstruktoid.hardening` investigation (replacing the
  vague "⚠️ ... not chased further" entry in `ROLES_TESTED.md` with
  a precise "❌ Not testable — role-side UFW lockout, reproduced in
  round 24" + the full root-cause analysis, including the fact that
  both engines hit the role's own UFW activation-order bug
  identically), and the `dict2items`/`items2dict` filter pair
  (Ansible-specific extensions, NOT standard Jinja2 - the Crinja
  corpus confirms Python/Jinja2 reject them as "No filter named ...").
  Implemented on both sides per the project's established
  dual-evaluator pattern: `FilterEngine` for plain `{{ }}` chains
  (dev-sec os_hardening's `loop: "{{ os_vars | dict2items }}"` shape,
  the regression spec for the related mode bug is rewritten to use
  the real role shape now that the loop actually runs) and
  `jinja_filters.cr` for `.j2` template `{% for %}` block-tag
  chains. Closes one of the three narrow open scope cuts the round-24
  status report flagged. No new live-host bugs found in this commit -
  it's a filter addition, not a bug fix.
- **`0.9.346` (round 23) - `geerlingguy.phpmyadmin`** went from
  ❌ `Not testable` to ✅ **clean** (its `include:` -> `include_tasks:`
  patch synced to the baseline host so both engines ran the same role).
  Two real engine bugs found live: `MysqlConnection.build_uri` now parses
  the `[client]` section of `~/.my.cnf` for `user`/`password`/`socket`
  when the task itself passes no `login_*` params (community.mysql
  modules get this from their `config_file: ~/.my.cnf` argument-spec
  default; crystal-ansible's shared helper had to learn the same
  fallback), and `lineinfile` (state=present) now uses `rindex` instead
  of `index` - real Ansible replaces the **last** regexp match, which
  is the only way the role's `$cfg['Servers'][$i]['host'] = $dbserver;`
  template (an active line plus a commented copy near EOF) converges.
  Cold: crystal ok=80/changed=31/failed=0 vs baseline
  ok=96/changed=30/failed=0; warm `changed=1` on **both** (the same
  `mysql_user` `update_password: always` re-assert, role-side not
  engine); byte-identical `config.inc.php`; both serving phpmyadmin HTTP
  200 on port 8080.
- **`0.9.345`** - `hostname` module completed, `http_download` refactored,
  `mysql_user` auth hardening. Independent follow-up commits
  completing things 0.9.346's mysql work depended on.
- **`0.9.339` - `dev-sec.os_hardening` re-verified clean as the
  live-host host for CRINJA.md step-5's full `#evaluate_expr` dispatch
  convergence.** Found two real mode-octal-integrity bugs the spec suite
  had never surfaced: `set_fact:` decimal-parsed the leading-zero
  octal-style *string* `"0755"` into int `755`, and `TaskExecutor`
  re-expressed an int whose decimal digits already looked like a valid
  octal mode (`"1777"` -> `"3361"`), corrupting `/dev/shm`/`/tmp`/
  `/var/tmp` to mode `3361` on a live host. Both fixed with regression
  specs. Clean fresh-host re-verify on a new 2-node pair: cold crystal
  ok=101/changed=35/failed=0 vs python ok=102/changed=36/failed=0,
  crystal warm `changed=0` (fully idempotent), config/service parity
  byte-identical; every residual cold diff traced to documented
  non-engine causes (the `/var/log` systemd-tmpfiles 755<->775
  environmental flake plus the loop-hash iteration-order display
  artifact). **`ExpressionEvaluator`'s step-5 convergence is now
  live-verified end to end.**- **`0.9.327`–`0.9.338` - CRINJA.md step-5 dual-evaluator convergence.**
  `ExpressionEvaluator`'s `#evaluate_expr` dispatch went from 3
  converged constructs to essentially the entire surface: bare
  literals, the `~` operator, `*`/`/`/`//` arithmetic, literal
  array/dict expressions, `range()`, dotted/simple/indexed variable
  lookups, Python slicing, `|`-filter chains, and the leading-paren
  wrapper all now try Crinja first, falling back to the original
  hand-rolled code on any failure. The key enabler was solving an
  architectural blocker: `CrinjaRenderer#evaluate_value!` extracts
  Crinja's raw evaluated result directly (bypassing its own Python-repr
  `Finalizer` stringification) so it can be fed through this codebase's
  own JSON-compact `format_value` instead. Found and fixed along the
  way: two real bugs in the `weirdbricks/crinja` fork itself (`Hash`
  finalization using Crystal's `{'a' => 1}` separator instead of
  Python's `{'a': 1}`; `~`/`+`'s string-fallback bypassing `Finalizer`
  entirely), a process-crashing `OverflowError` on `10 // 0`, a
  slicing dispatch bug where `items[1:3]` never worked through the
  plain `evaluate()` entry point, and a missing `round` filter in
  `FilterEngine`. Only `lookup()` bare-calls (no Crinja equivalent)
  and `dict()`'s positional-iterable form (Crinja's own `dict()`
  silently mishandles it) remain intentionally unconverged. See
  `CRINJA.md` and `KNOWN_MISSING.md`'s `0.9.333`–`0.9.338` entries
  for full detail.

### Current open scope cuts

These are the only explicit, deliberate open items. Everything else is
found and fixed through benchmark rounds rather than tracked from a
static pre-planned list (see `KNOWN_MISSING.md`'s own intro).

- **`meta:`** supports only `clear_facts`. `end_play` / `flush_handlers` /
  `refresh_inventory` and friends act on execution-flow machinery this
  engine models differently, and are rejected at parse time rather than
  silently ignored.
- **Crinja's `namespace()` builtin** is unimplemented - the Jinja2
  mutable-state-across-`{% for %}`-iterations construct. Hit
  benchmarking `prometheus.prometheus.node_exporter`'s systemd
  `ProtectHome=` template (computes the value from whether any mount
  is under `/home`); not investigated further this round.
- **`docker_*` `api_version:`** is deliberately not planned - the
  underlying `docr` client uses unversioned endpoint URLs throughout,
  so pinning a version means touching every endpoint in a separate
  shard. The unversioned URLs negotiate fine against current Docker
  and Podman. Revisit only if a real playbook actually needs the pin.
- **Cloud plugins** (`ec2`, `s3_bucket`, `azure_rm_*`) and inventory
  *plugins* (`aws_ec2.yml` et al.) remain explicitly lowest-ROI and
  are not planned.
- **Role-private custom modules** (a role's own `library/*.py`, outside
  the `ansible.builtin`/`community.*`/etc. plugin set this engine
  ships) aren't executed - there's no generic arbitrary-Python-module
  runner. A task using one is skipped with a "Plugin not available"
  warning rather than crashing the run, but anything downstream that
  depends on its result sees that value as undefined, which can cascade
  into broader task-status divergence from real Ansible for roles that
  lean on this (seen repeatedly benchmarking `linux-system-roles`:
  `sr_fingerprint`, `timesync_provider`, `kernel_settings_get_config`,
  `blivet`).

### Recently closed scope cuts

- **`crystal-mysql` `auth_socket` / `unix_socket` auth** - added in the
  `weirdbricks/crystal-mysql` fork (tag `crystal-ansible-0.9.340`,
  commit `a91a592`): `CLIENT_PLUGIN_AUTH` advertised unconditionally,
  auth plugin name written even without a password, and `Auth.scramble`
  returns an empty response for `auth_socket`/`unix_socket`/
  `mysql_clear_password` plugin names. A role connecting via
  `login_unix_socket:` with no password can now authenticate using
  socket peer-credential auth. `mysql_user.cr` also now implements the
  `plugin:`/`plugin_hash_string:`/`plugin_auth_string:` params for
  *creating/updating* accounts with non-password auth (`IDENTIFIED
  WITH <p> [AS <hash> | BY <auth>]`, matching real Ansible's
  `module_utils/user.py` precedence). Verified end-to-end by
  `testing/test-mysql-auth-socket.sh` against a throwaway MariaDB
  container.
- **`ansible.builtin.deb822_repository`** supports the full four-way
  `signed_by:` branching (local path / URL / inline ASCII-armored key
  text / key fingerprint) matching real Ansible's own module
  (`0.9.229`/`0.9.232`/`0.9.343`).
- **`postgresql_privs`** is complete as of `0.9.84` - every `type:`
  real Ansible's module supports is implemented, including
  `function`/`procedure` signatures and `default_privs`.
- **`dict2items` / `items2dict` filters** - real Ansible's own
  filters (NOT standard Jinja2; the Crinja corpus confirms
  Python/Jinja2 reject them as "No filter named ..."), now
  implemented on both sides: `FilterEngine` for the plain `{{ }}`
  filter chain (dev-sec os_hardening's `loop: "{{ os_vars |
  dict2items }}"` shape - the regression spec for the related mode
  bug is rewritten to use the real os_hardening shape now that
  the filter actually runs the loop), and `jinja_filters.cr` for
  the Crinja pipeline so `.j2` template `{% for %}` block-tag
  chains can use them too. Both accept the
  `key_name=`/`value_name=` kwargs and default to `key`/`value`
  matching real Ansible. Unit specs in
  `spec/unit/filter_engine_spec.cr` (8 new), Crinja canary in
  `spec/unit/crinja_direct_spec.cr` (4 new), and the
  `spec/integration/mode_octal_via_variable_spec.cr` regression
  spec is back to its real os_hardening shape.
---

## 🤝 Contributing

Contributions welcome! Please:

1. Review the existing code structure and [KNOWN_MISSING.md](KNOWN_MISSING.md)
2. Verify any Ansible-compatibility claims against real `ansible-playbook`
   output, not just documentation
3. Test your changes thoroughly (`crystal spec`, and `compat/run.cr` for
   plugin behavior changes)
4. Submit a pull request with a clear description

---

## 📄 License

MIT License - see [LICENSE](LICENSE) file for details.

---

## 🙏 Acknowledgments

- Inspired by [Ansible](https://www.ansible.com/)
- Built with [Crystal](https://crystal-lang.org/)
- Uses [crinja](https://github.com/straight-shoota/crinja) for Jinja2
  templating, among other Crystal shards - see `shard.yml`

---

**Crystal Ansible - Ansible-compatible automation in Crystal** 🚀
