# Crystal Ansible - Ansible-Compatible Automation Tool

**A single-binary automation tool that runs real Ansible playbooks - written in Crystal**

[![Version](https://img.shields.io/badge/version-0.9.64-blue)](https://github.com/weirdbricks/crystal-ansible)
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
- **44 built-in plugins** covering package/service/file management, users
  and groups, Docker, MySQL/MariaDB, PostgreSQL, firewalls, archives, and
  more (see below)
- **Single binary deployment** - no dependencies, no Python required on
  either the controller or the target
- **Verified compatibility, not assumed compatibility** - every plugin's
  behavior is checked against real `ansible-playbook` output, and a
  Docker-based compatibility harness (`compat/`) runs the same playbooks
  through both engines side by side and diffs the resulting state

See [ROADMAP.md](ROADMAP.md) for the full, continuously-updated tracking of
what's implemented, what's a documented scope cut, and why.

---

## ✨ Features

### Core Engine
- ✅ YAML playbook parser (Ansible syntax): plays, tasks, handlers, `vars:`
- ✅ Inventory: static INI + YAML, and dynamic (script-based) inventory
- ✅ SSH connection pooling, plus local (`ansible_connection: local`) execution
- ✅ Variable substitution `{{ vars }}` with a Jinja2 filter pipeline
  (chained filters, e.g. `{{ x | sort | join(',') }}`)
- ✅ Conditionals `when:` (`==`, `!=`, `<`, `>`, `and`, `or`, `not`, `in`,
  dotted attribute access)
- ✅ Facts gathering (90+ `ansible_*` variables)
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
  Performance section below and `ROADMAP.md`'s `0.9.61`-`0.9.63` entries)

### Plugins (44 total)

**Files & templates:** `copy`, `template`, `file`, `lineinfile`,
`blockinfile`, `stat`, `find`, `archive`, `unarchive`, `fetch`, `get_url`

**Execution:** `command`, `shell`, `async_status`, `debug`, `assert`,
`set_fact`, `pause`, `wait_for`, `uri`

**Packages:** `apt`, `apt_repository`, `dnf`, `yum_repository`, `package`

**Users, groups & access:** `user`, `group`, `authorized_key`, `cron`

**Services & system:** `service`, `sysctl`, `mount`, `firewalld`, `ufw`,
`facts`

**Source control:** `git`

**Docker:** `docker_container`, `docker_image`, `docker_network`
(including `networks:`/`connected:` attachment and TLS-secured remote
daemon support)

**Databases:** `mysql_db`, `mysql_user`, `postgresql_db`,
`postgresql_user`, `postgresql_privs`

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
├── plugins/                     # One binary per Ansible module (44 total)
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

# Multiple options
./bin/crystal-ansible --check --diff -i production.ini playbook.yml
```

---

## ⚡ Performance

Every number below was measured against the previous shell/subprocess
implementation or against real `ansible-playbook`, not assumed - see
`ROADMAP.md` for the full, continuously-updated methodology and results
behind each one.

| What | Result |
|---|---|
| `find` (checksums enabled, native vs. shelling to `find`/`md5sum`/etc.) | **~150x faster** |
| `stat` (native `stat()`/hashlib vs. 5 subprocess spawns per call) | **~28x faster** |
| `file` (state changes, native vs. shelled-out checks) | **2.5x-4.9x faster** |
| Facts gathering (`0.9.61`, subprocess forks collapsed to syscalls) | **~2x faster** per run |
| Task batching, best case (30 fully-independent tasks, fresh+idempotency) | **2.82x faster**, 64.5% less wall time |
| Task batching, realistic mixed playbook - fresh run | ~1.0x (no measurable win) |
| Task batching, realistic mixed playbook - idempotency rerun | **1.31x faster** |

The last three are recent, ongoing engine-level work (task batching is
on by default since `0.9.63`; `--no-batching` disables it) - see
`ROADMAP.md`'s `0.9.59`-`0.9.63` entries for the isolated per-fork
measurements, the real-SSH correctness verification (12 runs, 3 fresh-
state cycles x 2 directions x fresh-run/idempotency-rerun, every one
producing byte-identical per-task output between batched and
`--no-batching`), and the honest caveats:

- Batching only saves SSH round trips, not the real work a task does.
  A fresh-provisioning run spends much of its time on actual file/user
  work, which dilutes the relative win; an idempotency rerun is mostly
  fast no-ops, where round-trip overhead dominates and the saving shows
  through cleanly - idempotency reruns are also the more common
  real-world case for a config-management tool.
- All of the above was measured on one unusually high-latency,
  high-jitter network path (the only one available in the environment
  this work was done in - confirmed not fixable by provider/region
  choice, see `ROADMAP.md`). The win scales with round-trip cost to your
  actual targets, so expect less on a fast, low-latency link and more on
  a slow one; a genuinely low-latency measurement is still an open item.

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

See [ROADMAP.md](ROADMAP.md) for the live, detailed tracking of what is
implemented, what is not, and what is planned next. As of this writing,
the remaining open items are narrow, documented scope cuts (a handful of
`postgresql_privs` privilege types that need a different underlying
mechanism, and Docker API version negotiation) plus one known
cross-cutting engine gap: bare `when:`/`assert: that:`/`until:`/
`changed_when:`/`failed_when:` conditions don't see task-level `vars:`
or magic variables like `inventory_hostname` (play-level `vars:` and
registered results work fine) - everything else tracked in the roadmap
has shipped, including two other engine gaps fixed in `0.9.64`: filters
in bare conditionals, and a failed host now being excluded from every
remaining play in the run, not just the rest of the one it failed in.

---

## 🤝 Contributing

Contributions welcome! Please:

1. Review the existing code structure and [ROADMAP.md](ROADMAP.md)
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
