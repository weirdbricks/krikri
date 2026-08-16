# Crystal Ansible - Ansible-Compatible Automation Tool

**A single-binary automation tool that runs real Ansible playbooks - written in Crystal**

[![Version](https://img.shields.io/badge/version-0.9.424-blue)](https://github.com/weirdbricks/crystal-ansible)
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

- **`0.9.424` - round 117, `robertdebock.maintenance`**: `apt.cr`'s
  `autoclean:`/`autoremove:`/`clean:` changed-detection used an
  empty-vs-non-empty-stdout heuristic, but `apt-get autoclean` always
  prints boilerplate stdout regardless of whether anything was
  removed - `autoclean: true` on an already-clean cache always
  reported `changed: true`. Fixed to match real Ansible's own
  per-operation marker-string check. Live-reverified byte-identical
  on both a clean and a dirty cache.
- **`0.9.423` - round 116, `robertdebock.functions`**: 2 bugs -
  `format_value` unconditionally stripped every rendered value's
  leading/trailing whitespace (a real Jinja2 never does this,
  affecting every string variable, not just this test data), and the
  vendored Crinja fork's `wordwrap` filter did fixed-width character
  chunking instead of real Python `textwrap.wrap`'s whole-word
  packing (fixed upstream, `crystal-play-0.9.12`). Also fixed
  `build.sh`'s staleness check never looking at `lib/` mtimes,
  silently no-opping a `shards update`-driven rebuild.
  Live-reverified byte-identical to real Ansible's own output.
- **round 115, `robertdebock.umask`** (no version bump): zero bugs
  found, byte-identical on both engines cold and warm, `.bashrc`
  content verified live.
- **round 114, `robertdebock.types`** (no version bump): zero bugs
  found, byte-identical type-test recap on both engines cold and
  warm; noted a cosmetic-only dict/list `debug:` formatting
  difference (Python repr vs compact JSON) with no behavioral effect.
- **`0.9.422` - round 113, `robertdebock.test_connection`**: 2 bugs -
  `ansible.builtin.ping` and `ansible.builtin.wait_for_connection`
  were both entirely unimplemented, silently dropped. New
  `plugins/ping.cr` and `plugins/wait_for_connection.cr`.
  Live-reverified byte-identical recap and result files on both.
- **round 112, `robertdebock.tlp`** (no version bump): zero bugs
  found, byte-identical on both engines cold and warm, `tlp` service
  verified active/enabled live.
- **`0.9.421` - round 111, `robertdebock.unowned_files`**: 2 bugs -
  `find.cr`'s `paths:`/`patterns:`/`excludes:` never handled a `{{
  }}`-templated list variable rendering to its own bracketed text
  form (same "Python-repr-list JSON" class as apt.cr/package.cr/
  dnf.cr), and `pw_name`/`gr_name` fell back to the stringified
  uid/gid instead of an empty string for an orphaned owner, breaking
  the role's own unowned-file detection entirely. Live-reverified
  byte-identical recap and per-item loop results on both engines.
- **`0.9.420` - round 110, `robertdebock.ulimit`**: 2 format bugs in
  `pam_limits.cr` - a `comment:` was written as its own preceding
  line instead of a trailing inline `\t#comment`, and a new entry was
  inserted before a `# End of file` marker instead of always appended
  at the true end (neither matches the real module's own source).
  Also preserves an existing entry's own comment on a value-only
  update. Live-reverified byte-identical written entries on both.
- **`0.9.419` - round 109, `robertdebock.kubectl`**: `lookup('url',
  ...)` always returned a JSON-array string regardless of whether
  `wantlist=True` was actually passed, so a call with no
  `wantlist=True` (the role's own version-file fetch) spliced a
  literal `["v1.31.0"]` into a download URL instead of the plain
  string, a 404. Fixed to match real Ansible's `lookup()` semantics
  exactly. Live-reverified byte-identical to real Ansible's own recap.
- **round 108, `robertdebock.packer`** (no version bump): zero bugs
  found, byte-identical on both engines cold and warm, `packer
  version` verified live.
- **`0.9.417`-`0.9.418` - round 107, `robertdebock.hashicorp`**: 2
  bugs - `assert.cr`'s own standalone plugin binary never required
  `jinja_filters.cr`, so an `is regex(...)`/`is version(...)`/etc test
  inside `that:` silently failed even when the identical condition
  worked via `when:` (Crinja's custom test library wasn't linked into
  that binary); and `apt_repository.cr`'s cache-update validation
  trusted `apt-get update`'s own exit code (stays 0 for a GPG
  signature failure), so a broken signed-by= line survived instead of
  being rolled back and then got duplicated by a rescue: retry. Fixed
  by requiring `jinja_filters.cr` in `assert.cr`, and scanning both
  `apt-get update` output streams for apt's own GPG-failure wording.
  Live-reverified byte-identical to real Ansible's own recap.
- **round 106, `robertdebock.openbao`** (no version bump, documented
  not fixed): `ansible.builtin.rpm_key` remains unimplemented (same
  cosmetic-scope gap class as `seboolean`/`seport`), zero runtime
  impact on Ubuntu. `openbao 2.5.0` byte-identical on both, verified
  live.
- **round 105, `robertdebock.docker_compose`** (no version bump):
  zero bugs found, byte-identical on both engines cold and warm,
  `docker-compose --version` verified live.
- **`0.9.416` - round 104, `robertdebock.docker`**:
  `CrinjaRenderer#prepare_crinja_vars` re-rendered a nested-template
  variable but never re-parsed the result back to its real type, so a
  variable that itself evaluates to a real array (`docker_pip_
  packages: "{{ ... }}"`) silently became String-typed forever after -
  `| length` measured the string's character count instead of the
  list's element count, breaking a `when:` guard. Live-reverified:
  warm-rerun recap identical on both engines, `docker` service
  healthy on both.
- **`0.9.415` - round 103, `robertdebock.alternatives`**:
  `community.general.alternatives` entirely unimplemented (new
  `plugins/alternatives.cr`) plus a self-inflicted regex idempotency
  bug found before shipping (Crystal's `/m` flag = multiline anchors
  + dot-matches-newline combined, unlike Python's `re.MULTILINE`).
  Live-reverified byte-identical `update-alternatives --display`
  output and matching recap counts both cold and warm.
- **round 102, `robertdebock.aide`** (no version bump): zero bugs
  found, byte-identical on both engines cold and warm, `aide.db` +
  cron job verified live.
- **round 101, `robertdebock.clamav`** (no version bump, documented not
  fixed): role's own bug (`freshclam_private_mirrors` used without a
  default) fails identically on both engines; re-confirms
  `ansible.posix.seboolean` remains unimplemented (untestable without
  an SELinux host).
- **round 100, `robertdebock.cargo`** (no version bump): zero bugs
  found, byte-identical on both engines cold and warm, `cargo`/`rustc`
  1.97.1 verified live via rustup.
- **`0.9.414` - round 99, `robertdebock.irslackd`**: `npm.cr`'s own
  `state: present` idempotency check was gated on a truthy
  `name_version`, which is nil whenever `name:` is omitted (a
  `path:`-only "install everything from package.json" task) - always
  reported `changed: true`, never converging. Fixed to match real
  `community.general.npm`'s own `if missing:` check exactly.
  Live-reverified to match real Ansible's warm-rerun recap.
- **`0.9.412`-`0.9.413` - round 98, `robertdebock.earlyoom`**: 2 bugs -
  `community.general.make` entirely unimplemented (new `plugins/
  make.cr`, ported from real Ansible's own module source); and
  `git.cr`'s `resolve_ref` returning an ANNOTATED tag's own object SHA
  instead of the commit it points to, breaking idempotency for any
  `version:` pinned to an annotated tag - fixed by peeling through
  `^{commit}`, matching real `ansible.builtin.git`'s own approach.
  Live-reverified to match real Ansible's recap exactly, both cold and
  warm.
- **`0.9.410`-`0.9.411` - round 96, `robertdebock.tailscale`**: 3 bugs -
  a parse-time crash on a dict keyed by a bare YAML boolean (a real
  Ansible/Jinja2 idiom); a real Crystal 1.20.3 stdlib `HTTP::Client`
  bug silently truncating a chunked HTTPS body (worked around by
  shelling out to curl); and `apt_key.cr`'s `keyring:` parameter being
  entirely unimplemented. Live-reverified: `tailscaled` active and
  functional on both engines.
- **`0.9.409` - round 95, `robertdebock.openvpn`**: a non-looped
  `include_tasks:` never credited itself as an `ok` in the recap tally
  (two independent copies of the gap - the single-host and multi-host
  batched execution paths). Cosmetic only, the actual work was already
  byte-identical; live-reverified to match real Ansible's recap count
  exactly.
- **`0.9.408` - round 89, `robertdebock.systemd`**: `ini_file.cr` never
  implemented real Ansible's `modify_inactive_option: true` default - a
  commented-out `#option=value` line should count as a match and get
  uncommented in place, not treated as absent; crystal-ansible always
  appended a duplicate active line instead. Live-reverified to uncomment
  in place identically to real Ansible.
- **`0.9.407` - round 83, `robertdebock.keepalived`**: a handler notified
  by an earlier task still ran at the implicit end-of-play flush even
  after a LATER task failed and halted the host - `HandlerRunner#run`
  had no way to know about halted hosts. Fixed by threading
  `@halted_hosts` through as a new parameter. Live-reverified to match
  real Ansible's single-failure recap exactly.
- **`0.9.406` - round 79, `robertdebock.auditd`**: a handler notifying
  ANOTHER handler was entirely unhandled - only a regular task's own
  `notify:` was ever forwarded to `HandlerRunner`. The role's "Run
  augenrules" handler notifies "Load rules", which real Ansible runs
  within the same flush_handlers pass; crystal-ansible silently dropped
  it. Live-reverified identical to real Ansible's cold-run recap.
- **`0.9.405` - round 78, `robertdebock.unbound`**: a failed handler never
  halted the rest of the play for that host - the one execution path in
  `executor.cr` missing a `halt_if_failed` call. The role's own
  `./configure --enable-systemd` handler genuinely fails on stock Ubuntu
  22.04 (missing pkg-config), reproducing identically on real
  `ansible-playbook`, which correctly halts there; crystal-ansible instead
  kept running every subsequent task. Live-reverified to halt at the same
  point as real Ansible now.
- **`0.9.403`-`0.9.404` - round 75, `robertdebock.node_red`**: new
  `community.general.npm` plugin (entirely unimplemented before);
  `import_role:` entirely unhandled by the parser (silently dropped the
  whole task, no error surfaced); `include_role:`/`import_role:` `vars:`
  never recursed into Array/Hash-shaped values (a list-of-dicts
  `service_list:` landed with every `{{ }}` field unrendered). Live-
  reverified identical both engines; node-red's own systemd service
  fails identically on both (stock Ubuntu 22.04 nodejs too old), a real
  external gap, not a crystal-ansible divergence.
- **`0.9.402` - round 71, `robertdebock.git`**: `getent:`'s single-key
  lookup returned a bare field-list instead of a dict keyed by the
  looked-up username (real Ansible's own `getent_passwd` is always a
  dict, even for one key) - broke `getent_passwd[user] != none`
  existence checks, silently skipping every downstream task gated on
  it. Live-reverified byte-identical, idempotent.
- **`0.9.399`-`0.9.401` - round 70, `robertdebock.diskspace`**: 3
  chained bugs - a looped include_tasks:'s propagated "item" clobbered
  a nested loop's own item every iteration; `ansible_facts['mounts']`
  was missing size/inode stats entirely; two independent Int32-
  narrowing overflow bugs silently produced wrong results for real
  byte-scale numbers. Live-reverified identical, idempotent.
- **`0.9.397`-`0.9.398` - round 66, `robertdebock.mount`**: the
  "undefined" sentinel string wasn't treated as falsy in a bare filter-
  chain `when:` condition, firing a handler unconditionally; and
  `loop_control.index_var` was entirely unimplemented, breaking a
  registered-loop-result re-creation guard on every warm rerun.
  Live-reverified byte-identical, idempotent.
- **`0.9.396` - round 65, `robertdebock.locale`**: `community.general.
  timezone` was entirely unimplemented - new `timezone.cr` plugin
  (systemd/`timedatectl` backend, matching every target this repo
  benchmarks against). Live-reverified byte-identical, idempotent.
- **`0.9.395` - round 64, `robertdebock.spamassassin`**: dotted-access
  dispatch only fell back from Crinja to the hand-rolled evaluator (with
  its correct re-templating fix) on an actual Crinja exception - a
  quiet Crinja `nil` (attribute access on a still-templated raw string)
  fell through to literal `"undefined"` instead. Another "recursive
  re-templating" instance. Live-reverified byte-identical, idempotent.
- **`0.9.394` - round 60, `robertdebock.dovecot`**: `find:` only ever
  recognized the plural `paths:` param, failing outright on the
  singular `path:` alias - a real, documented alias of Ansible's own
  `find` module and the far more common single-directory spelling.
  Live-reverified byte-identical, idempotent.
- **`0.9.393` - round 59, `robertdebock.vsftpd`**: a filter/test
  referenced by its fully-qualified collection name (`|
  ansible.builtin.ternary(...)`, valid real-Ansible syntax) crashed the
  whole template render in the vendored Crinja fork's own grammar
  ("Unexpected POINT") - fixed to resolve to the same bare-name filter
  (fork tag `crystal-play-0.9.9`). Live-reverified byte-identical,
  idempotent.
- **`0.9.392` - round 58, `robertdebock.python_pip`**: `ini_file:`
  started from an empty line array for a brand-new destination file;
  real Ansible's own module force-seeds a single leading blank line
  before the first `[section]` header whenever the file starts empty -
  a silent content divergence in every fresh `ini_file`-managed config.
  Live-reverified byte-identical, idempotent.
- **`0.9.391` - round 54, `robertdebock.php`**: the `comment` Jinja filter
  silently ignored the `style` argument (`'c'`/`'cblock'`/`'xml'`/
  `'erlang'`), always producing the `'plain'` `#`-commented shape
  regardless - `php.ini.j2`'s own `comment('c')` header needed `//`, got
  `#` instead. Ported real Ansible's full style-selection algorithm.
  Live-reverified byte-identical templated output, idempotent.
- **`0.9.390` - round 51, `robertdebock.httpd`**: `RoleLoader#resolve_role_dir`
  never searched `~/.ansible/roles`/`ANSIBLE_ROLES_PATH` - the default
  install location for a plain `ansible-galaxy role install`, breaking
  any bare Galaxy-role reference outside a cwd with a local `roles/`
  checkout ("Role not found"). Fixed with a search-path list mirroring
  the existing collections-path handling. Live-reverified identical to
  real Ansible (`skipped` count diff is a pre-existing documented
  cosmetic gap), idempotent, `apache2` serving HTTP 200 on both.
- **`0.9.389` - round 48, `robertdebock.squid`**: `squid_cache_dir.split(
  " ")[0] in [...]` (a Python-style `.split(...)` method call, not a `|
  split` filter) - same class as round 45's bug: works fine inside
  `{{ }}`, breaks in a bare `assert:`/`when:` condition, this time
  because the expression-routing guard only recognized a *leading* `(`,
  not one anywhere in the string. Widened to any `(`. Live-reverified
  identical to real Ansible, byte-identical config, idempotent.
- **`0.9.388` - round 45, `robertdebock.java`/`robertdebock.jenkins`**:
  `assert.yml`'s own `java_version | int is number`/`in [...]` - a
  filter-chain type test - was treated as a literal (never-matching)
  variable name by `ConditionalEvaluator`, always failing regardless of
  the real value. Generic fix, any `X | filter is <type>` pattern was
  affected. Jenkins itself stayed blocked on both engines either way -
  its own apt repo's GPG key has expired.
- **`0.9.387` - round 43, `robertdebock.postgres`**: 4 chained bugs -
  `postgresql_db`/`postgresql_user`/`mysql_db`/`mysql_user` never
  recognized real Ansible's deprecated `name:` aliases (`db:`/`user:`);
  the postgres connection helper always forced TCP to "localhost"
  instead of defaulting to a Unix socket like real libpq (failed the
  `ident` TCP gate this host's `pg_hba.conf` uses, while a socket
  connection's `peer` auth succeeds); `login_host:`/`login_port:`/
  `login_user:`/`login_unix_socket:` didn't recognize their own aliases
  either (`host:`/`port:`/`login:`/`unix_socket:`); and role creation
  used `CREATE ROLE` (implies `NOLOGIN`) instead of real Ansible's
  `CREATE USER` (implies `LOGIN`), leaving created users unable to log
  in. Live-reverified `\du`-identical and `rolcanlogin=t` on both
  engines.
- **`0.9.386` - round 41, `robertdebock.haproxy`**: its `haproxy.cfg.j2`
  template's `server.address | default(hostvars[server.name][...])`
  idiom crashed the whole render whenever the unused `default()`
  fallback branch chained through a non-inventory host name - fixed in
  the vendored `weirdbricks/crinja` fork itself (tag
  `crystal-play-0.9.8`): chained access on an undefined base now
  self-propagates instead of raising, matching real Ansible's own
  `Marker` class. Live-reverified byte-identical config + idempotent on
  both engines.
- **`0.9.385` - round 40, `robertdebock.redis`**: `mode: "{{ redis_mode
  }}"` rendered to a templated digit string ("640") with no leading
  zero - `template.cr`/`copy.cr`/`ini_file.cr` all mis-parsed that as
  decimal instead of octal, corrupting `redis.conf`'s permissions
  enough that `redis-server` couldn't read its own config and
  crash-looped, while real Ansible (which always treats an all-digit
  mode string as octal) came up clean. Fixed to match `file.cr`'s
  already-correct parsing; live-reverified `PONG`/idempotent on both
  engines.
- **`0.9.384`**: closed the one gap round 37 left open - a *looped*
  top-level `include_tasks:` (`loop:`/`with_items:` on the include
  statement itself, e.g. `robertdebock.users`' "Loop over
  users_groups") still ran each host's whole loop to completion before
  the next host started. `task_forkable?` now allows this narrower case
  through the same fiber-pool parallelism plain tasks use - correctness
  (per-item `loop_var` binding, `when:` gating) unchanged, only
  host-to-host overlap. New regression spec added; not yet benchmarked
  live (no role tested so far happens to hit a looped top-level
  `include_tasks:`).
- **Round 38 (no version bump - pure verification)**: a follow-up
  timing pass on round 37's fix, using finer-grained `pexpect` timing on
  a fresh 2-node `geerlingguy.kubernetes` pair. Crystal-ansible is now
  *faster* than real `ansible-playbook` on both cold (128.6s vs 196.7s)
  and warm (15.5s vs 45.1s) runs - round 37's own "~30% faster, roughly
  halves the gap" estimate undersold the fix; the gap is fully closed
  and inverted. No new bugs, correctness unchanged (`failed=0`/idempotent
  warm rerun on both).
- **`0.9.383` - round 37, a real performance bug**: a head-to-head cold-
  run timing comparison against real `ansible-playbook` on the real
  2-node `geerlingguy.kubernetes` cluster playbook (verified clean in
  round 36) showed crystal-ansible a reproducible ~1.8x *slower*
  (247-252s across two fresh host pairs vs. a stable ~136s for python),
  even though the idempotent warm rerun was faster as expected - a red
  flag. Root cause: `include_tasks:`/`block:` ran every nested task one
  whole host at a time, fully serially, never getting the `--forks`
  multi-host parallelism regular top-level tasks get - and
  `include_tasks:` for OS-family branching is an extremely common
  Ansible idiom, not specific to this role. Fixed by unifying the
  top-level play loop and any nested `include_tasks:`/`block:` list onto
  one shared batch-dispatch engine. Live-verified on a third independent
  host pair: cold run dropped to 175.7s (~30% faster, cutting the gap to
  real Ansible roughly in half), resulting cluster identically healthy.
- **`0.9.382` - round 35, `robertdebock.vault` + `geerlingguy.kubernetes`**
  (first new roles since round 33's nomad), real 2-vCPU/4GB Atlantic.net
  pair. 3 real bugs, all surfaced by kubernetes' own "Set the kubeadm
  join command globally." task (`loop: "{{ groups['all'] }}", delegate_to:
  "{{ item }}", delegate_facts: true`): the `groups` magic variable was
  entirely unpopulated (`groups['all']` always "undefined"); a templated
  `delegate_to:` on a loop was resolved once before the loop ever bound
  `item`, crashing outright trying to SSH to a host literally named
  "undefined"; and `delegate_facts:` was entirely unimplemented, so a
  delegated `set_fact:` silently stayed on the executing host instead of
  the real target. Also added the previously-missing `ansible_apparmor`
  fact (found via vault's own `aa-enforce` hardening task, silently
  skipped on every run regardless of the host's real AppArmor state).
  Final: real Kubernetes control-plane node `Ready`, every system pod
  `Running`, Vault `active`, idempotent warm rerun matching task-for-task
  on both engines identically.
- **`0.9.381` - proactive audit: `~`-expansion for path-type params
  across 21 plugins**, not tied to a real host round. Real Ansible's
  `AnsibleModule` expands a leading `~`/`~user` for every `type: path`
  argument (matching Python's `os.path.expanduser`) before the module
  ever sees it; the same gap had already been found and fixed 3
  separate times in narrower spots (`~/.my.cnf` in
  `MysqlConnection.build_uri`, `~/.ansible/collections` in
  `role_loader.cr`, `unarchive:`'s `creates=`), so this pass swept
  every plugin's own `path:`/`dest:`/`src:`/`chdir:`-style param for
  the same missing call. Found and fixed 21 more instances (`file:`,
  `copy:`, `template:`, `stat:`, `archive:`/`unarchive:`, `git:`,
  `get_url:`, `htpasswd:`, `ini_file:`, `lineinfile:`, `blockinfile:`,
  `replace:`, `mount:`, `openssh_keypair:`, `openssl_dhparam:`,
  `pamd:`, `pam_limits:`, `pip:`'s `chdir:`, `wait_for:`,
  `capabilities:`, `uri:`'s `dest:`, `authorized_key:`'s `path:`).
  Also found a real bug in `BasePlugin#expand_tilde` itself while
  writing a regression spec for it: for the bare `~` case it checked
  the passwd-entry home directory *before* `$HOME`, backwards from
  Python's own `os.path.expanduser` (which checks `$HOME` first,
  passwd only as a fallback) - `plugin_helpers/mysql_connection.cr`'s
  separate copy already had the priority right. `fetch:`'s `src:`
  deliberately left unexpanded - it names a path on the *remote*
  target while `fetch:` itself runs on the controller, so a local
  `expand_tilde` there would resolve against the wrong host's home
  directory; a correct fix needs remote-side expansion, out of scope
  for this pass.
- **`0.9.380` - `docker_container:`'s resource-limit params** -
  `memory:`/`memory_reservation:`/`memory_swap:`/`memory_swappiness:`/
  `cpus:`/`cpu_shares:`/`cpuset_cpus:`/`cpuset_mems:`/`oom_kill_disable:`/
  `oom_score_adj:`/`pids_limit:`, built and compared for idempotency.
  Required adding 10 new fields to the `docr` fork's `HostConfig` type
  first. All fields now live-verified end to end against a real Docker
  Engine 29.1.3 (root, full cgroups, throwaway Atlantic.net host) - a
  same-day follow-up after the rootless Podman dev machine used
  initially couldn't exercise `cpuset_cpus:`/`oom_score_adj:`/
  `memory_swap: "unlimited"` properly (no `cpuset` delegation, and
  unexplained value transformations that turned out to be
  rootless-Podman-only artifacts, not bugs). `oom_kill_disable: true` is
  sent correctly but silently discarded by a real kernel limitation on
  this specific host - confirmed identical via the native `docker` CLI
  itself, so not an engine issue.
- **`0.9.379` - `firewalld:`'s `state: present`/`absent` leniency gap**,
  noticed incidentally during the round-34 host round. Real
  `ansible.posix.firewalld` only accepts `present`/`absent` for
  `target:`; every other thing needs `enabled`/`disabled` and fails
  otherwise. This plugin previously accepted them as silent synonyms
  everywhere - fixed to match real Ansible's own validation exactly,
  live-verified against a real `firewall-offline-cmd`.
- **`0.9.378` - real 2-node host round verifying `0.9.375`-`0.9.377`
  end to end** (firewalld `port_forward:` + docker_container
  `ports:`/`healthcheck:`/comparison defaults), real `ansible-playbook`
  vs `crystal-ansible` on a genuine Docker Engine 29.1.3 daemon (not
  just the Podman used to build the feature). Found and fixed 3 real
  bugs only reachable against a real Docker Engine: two more `docr`
  fork nullability crashes (`Image#graph_driver`, alongside the
  container one found moments earlier) and a real daemon-version-
  dependent `HostIp` difference (`""` under this plugin's unversioned/
  latest-API client vs `"0.0.0.0"` under real Ansible's own older
  pinned-API client) that was falsely recreating containers with
  `ports:` set on every single rerun. Final result identical on both
  engines: `ok=20 changed=5 failed=0`, every assertion passed.
- **`0.9.377` - `docker_container:`'s `ports:`/`healthcheck:`, plus a
  real comparison-default correction.** `healthcheck:` was entirely
  unimplemented before this (new `PluginHelpers::DockerHealthcheck`
  helper, ported from real Ansible's own duration-parsing/test-
  normalization logic); `ports:` now participates in idempotency
  comparison too. Found and fixed a real bug in this project's own
  `docr` fork along the way (`Health#log` crashing JSON parsing on a
  real `null` from Docker/Podman) and, more importantly, a real
  correctness bug in `0.9.376`'s own comparison logic: it assumed every
  field defaulted to `strict`, but real Ansible's actual default for
  every set/dict-typed field (`env`/`labels`/`volumes`/`ports`/
  `healthcheck`) is `allow_more_present` (a subset match) - the wrong
  assumption made a minimal `healthcheck:` recreate the container on
  every single rerun forever, caught live before it could ship
  uncorrected. `comparisons:` now takes each field's own real default
  and accepts explicit `strict`/`allow_more_present` overrides in either
  direction. Live-verified end to end against a real Docker-API-
  compatible daemon (Podman 5.4.2).
- **`0.9.376` - broadened `docker_container:`'s `comparisons:` system**
  from just `networks` to every field the plugin actually manages
  (`entrypoint`/`env`/`labels`/`volumes`/`restart_policy`/
  `network_mode`/`privileged`/`auto_remove`) - closing a real, previously
  unbounded idempotency gap where drift on any of these went undetected
  forever without `recreate: true`. `env:` also ports real Ansible's own
  image-`Env`-merge algorithm so a base image's own baked-in env vars
  don't cause a false mismatch on every run. Live-verified against a real
  Docker-API-compatible daemon (Podman 5.4.2); `ports:`/healthcheck/
  resource limits remain a deliberate scope cut. `yum_repository:`'s
  `proxy_password:` no_log redaction, investigated in the same pass,
  turned out to be a non-issue: no plugin or verbose mode in this
  codebase ever echoes raw task params anywhere, so there is currently no
  actual leak surface for it to redact.
- **`0.9.375` - `firewalld:`'s `port_forward:`**, the one gap explicitly
  left out of the `0.9.374` scope-cut pass below (a compound
  `port=X:proto=Y:toport=Z[:toaddr=W]` value using its own distinct
  `--add-forward-port=`/`--remove-forward-port=`/`--query-forward-port=`
  flags). Matches real Ansible's own `ForwardPortTransaction` exactly
  (single-entry-only, required-key check order, `toaddr` omitted not
  defaulted). Live-verified against a real `firewall-offline-cmd`
  (firewalld 1.3.3, throwaway Debian container).
- **`0.9.369`-`0.9.374` - closed every remaining "narrow scope cut"**
  identified across the plugin set, on direct request: `modprobe:`'s
  `params:`; `find:`'s `mode:`/`exact_mode:`/`limit:`; `wait_for:`'s
  `search_regex` against an open socket (plus a message-format fix);
  `apt_key:`'s `keyserver:`; `deb822_repository:`'s remaining DEB822
  keys (and a real pre-existing field-ORDER bug found and fixed along
  the way - real Ansible sorts fields alphabetically by param name, not
  a fixed order); `archive:`'s `attributes:`/SELinux context params;
  `gem:`'s `repository:`/`include_dependencies:`/`norc:`; `pip:`'s
  `editable:`/`umask:`; `user:`'s `expires:`; the full Docker trio
  (`docker_network:`'s `force:`, `docker_image:`'s `force_source:` -
  including a real digest-comparison detail only caught by comparing
  live output against real ansible-playbook, `docker_container:`'s
  `comparisons: {networks: strict}`); and `firewalld:`'s
  `interface`/`icmp_block`/`protocol`/`icmp_block_inversion`/`forward`/
  `target`. Nearly every one live-verified against the real tool/daemon
  (a throwaway Docker container standing in for firewalld/pip/user,
  since none were installed on the dev machine) rather than assumed from
  documentation. Two items were explicitly re-classified as out of scope
  instead of force-fit: `yum_repository:`'s `proxy_password:` no_log
  redaction and `docker_container:`'s broader `comparisons:` system are
  both cross-cutting framework features spanning ~40 fields, not single-
  plugin gaps. Full detail per item in `KNOWN_MISSING.md`.
- **`0.9.368` - closes `mount.cr`'s last remaining gap** on direct
  request: `state: remounted`'s `opts:`-absent fallback (a bare `mount
  -o remount` failing right after a fstab entry was just added is the
  common case here) now falls back to a real `umount` + `mount <path>`
  cycle via fstab, matching real `ansible.posix.mount`'s own verified
  behavior, instead of reporting `changed: true` regardless. No
  exit-code-blind path left in this plugin at all.
- **`0.9.367` - follow-up to the audit pass below**, on direct request:
  `mount.cr`'s own `ensure_mounted`/`ensure_unmounted`/`ensure_ephemeral`
  helpers had the identical "real command failure silently discarded"
  gap - previously flagged rather than fixed since it looked like a
  deliberate scope cut. All four now propagate a genuine `mount`/`umount`
  failure as a real task failure, matching real `ansible.posix.mount`'s
  verified behavior. Regression specs added using a real (sandbox-
  guaranteed-to-fail, no privilege escalation) mount/umount attempt.
- **`0.9.366` - proactive audit pass** (not a live round), prompted
  directly by round 33's `apt_repository.cr` finding: searched the rest
  of the plugin set for the same "a real command's failure silently
  swallowed instead of failing the task" shape. Found and fixed the same
  bug in `sysctl.cr` (`sysctl -w` failures ignored) and in `unarchive.cr`'s
  own round-32 `chown -R`/`chgrp -R`/`chmod -R` fix (which had the exact
  same gap one layer down). Also ported the round-32 virtual/Provides-
  satisfied-package idempotency fix to `dnf.cr` (not live-verified - no
  RPM host available this pass). `mount.cr`'s own identical gap is left
  as-is - already an explicitly documented, deliberate scope cut, not an
  oversight this audit needed to re-litigate.
- **`0.9.363`-`0.9.365` (round 33) - `robertdebock.nomad` +
  `robertdebock.hashicorp`, first new role tested since round 32's
  nextcloud.** Three real bugs found and fixed live: `conditional_
  evaluator.cr` had no fallback for ANY unimplemented Jinja2 `is [not]
  <test>` (divisibleby, even, odd, equalto, sameas...) - always
  evaluated false regardless of the real outcome, fixed with a generic
  Crinja-delegation fallback; `apt_repository:`'s post-add `apt-get
  update` failure was silently swallowed instead of failing the task
  (breaking a role's own `block:`/`rescue:` GPG-key recovery), then a
  second fix to roll back the just-written repo line on that failure
  too, matching real Ansible and avoiding a conflicting-duplicate-line
  apt error from the rescue's own retry. The role/Nomad-v2.0.5 combo
  itself can't fully succeed on this specific cloud host regardless of
  engine (a chain of real external issues: a stale `ansible_default_
  ipv4` fact, Nomad v2.0.5 needing an explicit bind address, and the
  role's own CLI defaulting to `127.0.0.1` once bind_addr isn't
  `0.0.0.0`) - verified identical on both engines, not an engine issue.
- **`0.9.360`-`0.9.362` (round 32) - `robertdebock.nextcloud`, first
  new role tested since round 31's ssh_hardening.** Three real bugs
  found and fixed live: `command:`'s `chdir:` crashed an otherwise-
  successful task under `become_user:` (tried to restore the process's
  original cwd afterward - `/root` on a fresh SSH connection,
  inaccessible to an unprivileged become_user - fixed by dropping the
  pointless restore entirely); `unarchive:`'s `owner:`/`group:`/`mode:`
  only applied to the destination directory itself instead of
  recursively to every extracted file (broke the role's own downstream
  `occ` commands needing the whole tree web-server-owned); `package:`'s
  virtual/Provides:-satisfied package names never converged to
  `changed: false` on a warm rerun (the same bug class already fixed in
  `apt.cr` for the ruby round, ported to this separate code path).
  Idempotent on both engines after the fixes, nextcloud verified
  reachable and functional.
- **`0.9.359` (round 31) - `devsec.hardening.ssh_hardening`, first new
  role tested since round 30's prometheus.** One real bug found and
  fixed live: `regex_replace`'s `\1`/`\2` backreference translation
  was backwards - it rewrote Python-style backreferences to `$1`/`$2`
  assuming Crystal's `gsub(Regex, String)` needed Ruby-style
  `$`-backreferences, when Crystal actually already matches Python's
  `\1` syntax directly, so the "translated" replacement string leaked
  through completely literally. Broke the role's own `ssh -V`-output
  version parsing, cascading into 3 undefined openssh-version-gated
  `set_fact:` variables. Both hosts locked out of root SSH identically
  post-play - the role's own `ssh_permit_root_login: "no"` default
  correctly taking effect (expected, not an engine bug).
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
