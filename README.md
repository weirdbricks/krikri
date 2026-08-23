# Crystal Ansible - Ansible-Compatible Automation Tool

**A single-binary automation tool that runs real Ansible playbooks - written in Crystal**

[![Version](https://img.shields.io/badge/version-0.9.535-blue)](https://github.com/weirdbricks/crystal-ansible)
[![Compatibility](https://img.shields.io/badge/ansible--compatibility-high-brightgreen)](https://github.com/weirdbricks/crystal-ansible)
[![Language](https://img.shields.io/badge/language-Crystal-black)](https://crystal-lang.org)

---

## 📋 What this is

Crystal Ansible parses and runs **standard Ansible playbook YAML directly** -
the same syntax you already write, unmodified. There's no Python, no
`ansible-core`, no `pip`, and no collections directory anywhere in the
picture, on either the controller or the target - it's one compiled binary
(`crystal-ansible`) plus a directory of small compiled module binaries.

It is not a new automation DSL you have to learn, and not a "mostly
compatible" reimplementation verified by eyeballing docs - every plugin's
behavior is checked against real `ansible-playbook` output on real hosts
(see **Differences** and **What's missing** below), and a Docker-based
compatibility harness (`compat/`) runs the same playbooks through both
engines side by side and diffs the resulting state.

---

## 🔀 How this differs from real (Python) Ansible

If you already know Ansible, here's what actually changes when you swap
`ansible-playbook` for `./bin/crystal-ansible`:

### Architecture: compiled binaries, not a Python interpreter per task

Real Ansible ships a Python module's source, templates it, and starts a
fresh Python interpreter for it on the target host **for every single
task**, every run - even when nothing changes. Crystal Ansible compiles
each module (`apt`, `copy`, `service`, ...) into its own small native
binary once; running a task means uploading that binary (cached after the
first run) and executing it directly - no interpreter startup, no module
templating step, no `AnsiballZ` wrapper. Consecutive tasks bound for the
same host are also batched into a single SSH round trip by default
(`--no-batching` to disable) instead of one round trip per task.

This is the single biggest practical difference, and it shows up directly
in wall-clock time - see **Performance** below.

### What's the same

Playbook syntax, inventory format, `roles/` layout, Jinja2 templating
(filters, tests, block tags), `become:`, Vault, `--check`/`--diff`,
`--tags`/`--limit`, handlers, loops, `block:`/`rescue:`/`always:` - all
parsed and executed the same way, from the same YAML files you already
have. See **Features** below for the full list of what's implemented.

### What's structurally different (by design, not a gap)

- **No arbitrary Python execution.** A role's own private `library/*.py`
  module (outside the `ansible.builtin`/`community.*` set this project
  ships as native binaries) can't run - there's no Python interpreter to
  run it in. The task is skipped with a warning rather than crashing the
  play, but anything downstream depending on its result sees an undefined
  value.
- **Cloud provider modules and inventory plugins are out of scope for
  now** - `amazon.aws`/`community.aws` (`ec2_instance`, `s3_object`, IAM,
  security groups, ...), `azure_rm_*`, and dynamic cloud inventory
  plugins (`aws_ec2.yml` etc.) aren't implemented. These are a
  fundamentally different kind of module (HTTP calls to a cloud API from
  the controller, not shell commands run on a managed target) and would
  need a real API client built from scratch - a much bigger undertaking
  than adding another module that shells out to a CLI tool. Not planned
  unless a specific real-world need justifies the investment.
- **`docker_*`'s `api_version:` pin isn't supported** - the underlying
  Docker client talks unversioned API endpoints throughout, which
  negotiate fine against current Docker/Podman, but pinning a specific
  API version would mean touching every endpoint individually.
- **`meta:` supports `clear_facts`/`flush_handlers`/`end_host`/
  `end_play`/`clear_host_errors`/`noop`/`refresh_inventory`** -
  `reset_connection`/`end_batch`/`end_role` still act on execution-flow
  machinery this engine models differently (persistent-connection
  control, `serial:` batching, and role-scoped early-return
  respectively), and are rejected at parse time rather than silently
  accepted and ignored.

---

## ❓ What's missing

**Short version: as of this version, there are no known real correctness
gaps left open** - the primary way gaps get found here is running real
production Ansible roles (from Galaxy) against both engines on real
hosts and diffing the result, not a pre-planned feature checklist, and
every gap found that way has been fixed. The structural differences
above are the only *deliberate* exclusions.

That status changes as new roles get tested, so it's tracked in one place
rather than duplicated here:

- **[KNOWN_MISSING.md](KNOWN_MISSING.md)** - the current, short,
  up-to-date list of any open real gaps plus the full explicit scope-cut
  list (cloud modules, role-private modules, a handful of untestable/
  narrow module gaps, etc., each with the reasoning behind it).
- **[ROLES_TESTED.md](ROLES_TESTED.md)** - the current status of every
  real Ansible Galaxy role that's been benchmarked against a live host,
  one line each, so you can check whether something resembling your own
  playbooks has already been exercised.

Both files describe **current state only** - the fix history for
everything already resolved lives in `git log`, not duplicated in either
file (searchable, e.g. `git log --all --grep=auth_socket`).

---

## ⚡ Performance

Native compiled modules, one persistent SSH connection per host, and
batched round trips make the biggest difference on **idempotent
re-runs** - the common case for a config-management tool running on a
schedule, where most tasks find nothing to change but Python still pays
a fresh interpreter-and-module cost per task regardless.

Measured against real `ansible-playbook` (`ansible-core` 2.19.4): 10
real Galaxy roles drawn at random from the project's verified-clean
list, each on its own **fresh** Atlantic.net `G3.2GB` Ubuntu-22.04 host
pair (one host per engine, never reused, destroyed immediately after),
cold (first touch) and warm (idempotent re-run) on both engines,
`--forks 1` on both sides. crystal-ansible was built `--release` and
stripped, and ran with `--persistent-daemon --no-batching` (one
long-lived `ssh ... -- <plugin binary> --daemon` connection per host
instead of a fresh `ssh`+`bash`+exec per task; batching is disabled
during measurement because it routes around that path). `PLAY RECAP`
parity with real Ansible (`ok=`/`changed=`/`failed=`/`skipped=`) was
checked per role, cold AND warm, and matched exactly on all 10:

| Role (author) | Python cold | Crystal cold | Cold speedup | Python warm | Crystal warm | Warm speedup |
|---|---|---|---|---|---|---|
| `robertdebock.remi` | 4.39s | 3.55s | 1.2x | 2.82s | **0.72s** | **3.9x** |
| `geerlingguy.helm` | 27.28s | **9.74s** | **2.8x** | 5.81s | **1.66s** | **3.5x** |
| `geerlingguy.clamav` | 74.15s | **52.19s** | 1.4x | 29.53s | **2.49s** | **11.9x** |
| `geerlingguy.node_exporter` | 54.64s | **8.16s** | **6.7x** | 19.56s | **2.32s** | **8.4x** |
| `robertdebock.types` | 5.34s | 3.34s | 1.6x | 3.15s | **0.65s** | **4.8x** |
| `robertdebock.docker_ce` | 81.13s | **50.45s** | 1.6x | 15.56s | **2.54s** | **6.1x** |
| `robertdebock.digitalocean_agent` | 37.22s | **23.29s** | 1.6x | 17.60s | **2.37s** | **7.4x** |
| `geerlingguy.adminer` | 15.79s | **9.50s** | 1.7x | 9.00s | **2.01s** | **4.5x** |
| `robertdebock.upgrade` | 9.24s | **4.84s** | 1.9x | 6.90s | **1.59s** | **4.3x** |
| `robertdebock.fail2ban` | 39.62s | **21.63s** | 1.8x | 22.33s | **2.65s** | **8.4x** |

Cold runs are dominated by real apt/download time (both engines wait on
the same mirrors), so the trustworthy signal is the warm column:
crystal warm runs are **3.5x-11.9x faster (mean ~6.3x)**, cold runs
1.2x-6.7x faster (mean ~2.2x). Real Ansible pays a fresh Python-
interpreter-and-module cost per task on every run regardless of whether
anything changes; crystal-ansible's compiled-binary-plus-persistent-
connection model is why its warm numbers drop so far below its own
cold.

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
  per task, on by default (`--no-batching` to disable)

### Plugins (87 total)

**Files & templates:** `copy`, `template`, `file`, `lineinfile`,
`blockinfile`, `replace`, `ini_file`, `stat`, `find`, `archive`,
`unarchive`, `fetch`, `get_url`, `slurp`

**Execution:** `command`, `shell`, `async_status`, `debug`, `assert`,
`fail`, `set_fact`, `pause`, `wait_for`, `wait_for_connection`, `uri`,
`ping`, `capabilities`

**Packages:** `apt`, `apt_key`, `apt_repository`, `deb822_repository`,
`dnf`, `yum`, `yum_repository`, `rpm_key`, `package`, `package_facts`,
`pip`, `gem`, `npm`, `alternatives`, `make`

**Users, groups & access:** `user`, `group`, `authorized_key`, `cron`,
`getent`, `openssh_keypair`, `htpasswd`

**Services & system:** `service`, `systemd`, `service_facts`, `sysctl`,
`mount`, `modprobe`, `firewalld`, `ufw`, `facts`, `setup`, `filesystem`,
`timezone`, `hostname`

**Security:** `selinux`, `seboolean`, `pamd`, `pam_limits`,
`openssl_dhparam`

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
├── plugins/                     # One binary per Ansible module (87 total)
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

# Disable task batching (on by default - see Performance above)
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

### Ad-hoc commands (`ansible`)

A separate binary, matching real Ansible's own `ansible`/`ansible-playbook`
split - runs exactly one module against a pattern of inventory hosts,
reusing the same connection/become/check-mode/forks engine as the
playbook runner:

```bash
./bin/ansible all -m ping
./bin/ansible webservers -a 'uptime'
./bin/ansible all -m command -a 'systemctl status nginx'
./bin/ansible all -m copy -a 'src=foo.conf dest=/etc/foo.conf' -b
./bin/ansible db -i inventory.ini -m service -a 'name=postgresql state=restarted' -b
```

Supports `-i`, `-m`, `-a`, `-u`, `-b`/`--become`, `--become-user`, `-C`/`--check`,
`-f`/`--forks`, `-l`/`--limit`, `-v`. Output matches real ansible's own
minimal callback (`host | SUCCESS => {...}` / `host | CHANGED | rc=0 >>`),
not ansible-playbook's `ok: [host]` TASK-recap style.

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

## 🕐 Recent changes

A short rolling summary of the last few versions - see `git log` for the
complete history (150+ rounds of real-host benchmarking) and
[KNOWN_MISSING.md](KNOWN_MISSING.md)/[ROLES_TESTED.md](ROLES_TESTED.md)
for current-state detail.

- **`0.9.533`-`0.9.535`** - 3 real bugs found benchmarking 40 new
  `buluma.*` roles on Ubuntu 22.04 (round 170, full defaults, two
  20-role batches with a fresh host pair per role): the `package:`
  module's own separate `apt-get install/remove/upgrade` call sites
  were never wrapped with the existing dpkg-lock-contention retry
  helper (`apt.cr` already had it since round153/0.9.502) - a fresh
  host's `unattended-upgr` holding the lock made `package:` fail fast
  where real Ansible waits it out (`buluma.aide`); the hand-rolled
  conditional evaluator had NO handling at all for a Python/Jinja
  ternary (`X if COND else Y`) - even the trivial `true if true else
  false` was broken, since an embedded comparison operator in the
  true-branch got misparsed as a top-level comparison spanning the
  whole ternary string (`buluma.auditd`); nested-template re-rendering
  blindly re-parsed EVERY rendered scalar as JSON, not just
  container-shaped (array/dict) results, so a purely numeric-looking
  STRING default silently became a real integer and broke a `== '3'`
  string-literal comparison two levels of indirection later
  (`buluma.bind`). All three fixed and live-reverified. Also confirmed
  (not new bugs): `buluma.ca` blocked by the pre-existing `community.
  crypto.openssl_csr` gap (round138 precedent); `buluma.fail2ban` hit
  a one-host dpkg-lock timing flake past the 60s retry budget;
  `buluma.collectd` exposed the same Crinja explicit-dash whitespace-
  control gap first found (and left unfixed) in round85 - see
  `KNOWN_MISSING.md` for current status. `crystal spec`: 1601
  examples, 0 failures.
- **`0.9.530`-`0.9.532`** - 3 real bugs found benchmarking 20 new
  `geerlingguy.*` roles on Ubuntu 22.04 (round 168, full defaults again -
  batching stayed clean a fourth consecutive round): `ansible_ssh_user`
  (real Ansible's deprecated-but-still-honored alias of `ansible_user`)
  was never populated as a template variable, only the canonical
  spelling was - fixed generically by synthesizing `ansible_ssh_user`/
  `ansible_ssh_host`/`ansible_ssh_port` as bidirectional aliases of
  `ansible_user`/`ansible_host`/`ansible_port` (`phergie`); `include_
  vars:` paired with `with_fileglob:` (not `with_first_found:`/`loop:`)
  was never recognized by the dedicated include_vars: parser, unlike the
  generic task parser which already handles `with_fileglob:` for every
  other module - `item` stayed unbound, failing with "file not found:
  undefined" instead of globbing the vars/ directory (`php_versions`); a
  LOOPED handler's own `when:` (referencing `item`) was evaluated ONCE,
  before the loop even resolved - with no `item` bound, a condition like
  `item.l2chroot is not defined or item.l2chroot` was trivially true
  regardless of any individual item's real value, so every item ran
  unconditionally (`ssh-chroot-jail`). All three fixed and live-
  verified. `crystal spec`: 1594 examples, 0 failures.
- **`0.9.528`/`0.9.529`** - 2 real bugs found benchmarking 20 new
  `buluma.*` roles on Ubuntu 22.04 (round 167, full defaults again -
  batching stayed clean a third consecutive round): `ansible.builtin.
  apt_key`'s idempotency check ran `apt-key --keyring X list` against a
  keyring file that didn't exist yet, which as an undocumented side
  effect creates it in GnuPG's modern "keybox" format instead of the
  classic OpenPGP binary format apt's own `trusted.gpg.d` reader
  requires - the later `apt-key add` inherited that wrong format,
  producing a keyring apt rejected outright (`buluma.gitlab_ce`); `user:`
  with `groups:` (not `group:`) on a brand-new user, where a group of
  the same name as the user already exists, needed `useradd`'s `-N` flag
  to stop its own default private-group-creation from colliding with
  that group (`buluma.zeppelin`). Both fixed and live-verified against
  real hosts. Also fixed a benchmark-harness false positive (not a
  crystal-ansible bug): the env-fail detector's "Failed to fetch"
  pattern matched a stale apt-mirror 404 and aborted the rest of the
  round - narrowed to genuine connectivity-failure patterns only.
  `crystal spec`: 1591 examples, 0 failures.
- **`0.9.527`** - 2 real bugs found benchmarking 20 new `buluma.*` roles
  on Rocky 9.6 (round 166, the first round run with FULL defaults - no
  `--no-batching` flag at all - now that round 165 confirmed batching
  itself is clean): `include_tasks: loop: query('first_found', ...)`
  with a `vars:` block on the SAME include statement never saw those
  vars when resolving its own `loop:` - only `task.include_vars`
  (propagated to the *included* file's tasks) was populated, while
  `task.vars` (read by the include's own loop resolution) stayed empty,
  so the whole include silently skipped instead of running
  (`bitbucket`); `ansible.builtin.yum`/`dnf` with `enablerepo:` naming a
  repo that isn't configured on the host (e.g. `enablerepo: epel` with
  no EPEL installed) hard-failed the task via the underlying `dnf`/`yum`
  CLI's strict "Unknown repo" error, where real Ansible's module (via
  dnf's Python API) just warns and continues with whatever repos ARE
  available (`elasticsearch_curator`). Both fixed and live-reverified
  against a real Rocky 9.6 host. Batching remained clean again - neither
  bug was batching-specific. 11 of the 20 roles clean, 7 hit external/
  environmental blockers identical on both engines (missing repo
  packages, a Debian-only role picked in error, a role precondition
  never met on a fresh host), not engine bugs. `crystal spec`: 1591
  examples, 0 failures.
- **`0.9.523`-`0.9.526`** - 3 real bugs found benchmarking 20 new
  `buluma.*` roles on Ubuntu 22.04 (round 165, run WITH task batching
  enabled - the default - specifically to close a coverage gap: every
  round since 160 had run with `--no-batching` to isolate the
  persistent-daemon path's own timing, leaving batching itself
  unexercised against real roles for a long time): `query('first_found',
  ...)` (real Ansible's list-forcing `lookup(..., wantlist=True)`
  shorthand) as an `include_vars:` loop source was entirely broken -
  three compounding gaps (the function itself unrecognized,
  `include_vars:`'s own dedicated parser never handling a templated
  `loop:`, and never parsing `loop_control:` either); a `loop:` item
  needing TWO levels of variable indirection (the common `release ->
  version -> download-dict` pattern) lost its native Hash type in a
  2+-element loop, extensively live-bisected and confirmed NOT
  batching-specific; `template:`/`copy:` `src:` doubled the subdir when
  a role baked the `files`/`templates` prefix into `src:` itself. All
  found via `buluma.confluence`, whose whole role now runs to
  completion after all three fixes. Also: `file:` `owner:`/`group:`
  didn't accept a raw numeric uid/gid string, only a name (`buluma.
  maven`'s own `group: "0"`). Task batching itself checked out clean -
  none of the bugs found were batching-specific; two (confluence's
  item-typing bug, and a benchmark-harness gap fixed the same session)
  were independently confirmed to reproduce identically with
  `--no-batching` too. `crystal spec`: 1590 examples, 0 failures.
- **`0.9.522`** - fixed another missing magic var found benchmarking 20
  new `geerlingguy.*` roles on Ubuntu 22.04 (round 164): `ansible_check_
  mode` (true under `--check`, false on a real run) was entirely
  unimplemented - same class as `ansible_version` below. Also fixed a
  benchmark-harness gap (not a crystal bug): real ansible-core 2.19's
  own stricter `when:` conditional enforcement (rejects any non-boolean
  result, even a common bare-truthy-variable check) needed its
  documented `ANSIBLE_ALLOW_BROKEN_CONDITIONALS=true` escape hatch,
  which this round's harness had omitted - a "divergence" that turned
  out to be a missing env var, not an engine bug (and retroactively
  explains round 163's own `geerlingguy.jenkins` finding the same way).
  `crystal spec`: 1581 examples, 0 failures.
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
