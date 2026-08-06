# Crystal Ansible - Ansible-Compatible Automation Tool

**A single-binary automation tool that runs real Ansible playbooks - written in Crystal**

[![Version](https://img.shields.io/badge/version-0.9.65-blue)](https://github.com/weirdbricks/crystal-ansible)
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
| Parallel fact gathering across hosts (`0.9.75`, 5 real hosts) | **1.41x faster** |
| `--forks N` (`0.9.77`, 4 real hosts, mixed 6-task playbook; `0.9.78` made `--forks 5` the default) | **~1.28x faster** |
| Parallel plugin pre-upload + per-run MD5 memoization (`0.9.79`, 3 real hosts, cold run) | **1.62x faster** |
| The same, warm run (plugins already on the target) | **1.26x faster** |
| `--gathering smart` (`0.9.79`, 3 real hosts, 4-play playbook) | **1.36x faster** |

The batching, multi-host and startup rows are recent, ongoing
engine-level work (task batching is
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

### Startup and fact gathering (`0.9.79`)

Measured on 3 fresh Atlantic.net instances (Ubuntu 22.04, G3.1GB,
`USEAST2`, destroyed immediately after), running `0.9.78` and `0.9.79`
interleaved to cancel out network jitter, median of 5, `--forks 3`:

| Scenario | `0.9.78` | `0.9.79` | |
|---|---|---|---|
| Cold run (plugins re-uploaded to every host) | 16.39s | **10.13s** | 1.62x |
| Warm run (plugins already present) | 3.09s | **2.45s** | 1.26x |
| 4-play playbook, `--gathering smart` vs `implicit` | 2.10s | **1.54s** | 1.36x |

The cold/warm wins are entirely in the *pre-execution* phase, which the
`0.9.75`/`0.9.77` parallelism work never touched: plugin pre-upload was
still serial across hosts, and each plugin binary was MD5'd once per
host rather than once per run (digesting the 44 binaries costs ~127ms,
so 20 hosts burned ~2.5s of pure duplication before the first task ran).

`--gathering smart` removes `(N_plays - 1) x N_hosts` fact round trips,
so it scales with play count - the same 3 hosts on an 8-play playbook go
2.75s -> 1.56s (**1.76x**).

Two honest caveats:

- **`--forks 1` got slower**, 8.29s -> 9.92s on 3 hosts. Fact gathering
  used to ignore `--forks` entirely and run 10-way concurrent no matter
  what; it now respects the flag, so `--forks 1` finally means one host
  at a time end to end. That is the flag working correctly, but it is a
  real wall-clock regression if you were using `--forks 1` for anything
  other than debugging.
- The per-task CPU work also landed (single-serialization of the remote
  config, a shared Crinja environment, lazily-built substitutors - see
  `ROADMAP.md`), but it is invisible end to end on these runs: a local
  playbook spends ~40ms per task spawning the plugin process, which
  dwarfs the microseconds saved. It shows up in microbenchmarks
  (config build 32.26us -> 7.90us and 45.7kB -> 15.8kB per task per
  host; `{% %}` rendering 21.08us -> 9.28us) and matters most for
  very large inventories, not for a 12-task playbook.

### vs. real Ansible, end to end

The isolated wins above compound into a real difference against actual
`ansible-core` on actual cloud hosts - measured with 3 fresh Atlantic.net
instances per row (Ubuntu 22.04, all destroyed immediately after each
run), the same 12-task mixed playbook (`file`, `copy`+loop x10,
`lineinfile`+loop x10, `shell`+`register`, `changed_when`/`failed_when`,
`stat`, `assert`, `find`, `debug`) run against both tools:

| | Fresh run | Idempotent re-run (median of 3) |
|---|---|---|
| Python `ansible-core` 2.19.4 (`forks=5` default) | 33.5s | 30.3s |
| `crystal-ansible` `--forks 1` (one-host-at-a-time) | 26.6s (1.26x) | 5.4s (5.6x) |
| `crystal-ansible` `--forks 3` | 27.5s (1.22x) | **2.9s (10.4x)** |

> These two rows were measured at `0.9.77`/`0.9.78` and have **not** been
> re-run since. The `0.9.79` startup work above would improve them
> further (its cold-run saving lands squarely in the fresh-run column),
> and `--forks 1` would lose a little - but rather than scale the old
> numbers by the new ratios, they are left exactly as measured until the
> whole comparison is re-run against both tools on the same hosts.

Fresh-run time stays close across all three rows - that time is
dominated by the actual work (writing files, running commands), which
is identical regardless of orchestrator or fork count. The idempotent
case is where native compiled modules plus batched, forked SSH round
trips show through cleanly: Python ships and starts a fresh interpreter
per task per host even when nothing needs to change, while
`crystal-ansible` finishes in under 3 seconds. Idempotent reruns are
also the more common real-world case for a config-management tool.

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

See [ROADMAP.md](ROADMAP.md) for the live, detailed tracking of what is
implemented, what is not, and what is planned next. As of this writing,
the remaining open items are narrow, documented scope cuts (a handful of
`postgresql_privs` privilege types that need a different underlying
mechanism, Docker API version negotiation, and `meta:`, which supports
only `clear_facts` - `end_play`/`flush_handlers`/`refresh_inventory` and
friends act on execution-flow machinery this engine models differently
and are rejected at parse time rather than silently ignored) plus one known
cross-cutting engine gap: bare `when:`/`assert: that:`/`until:`/
`changed_when:`/`failed_when:` conditions don't see magic variables like
`inventory_hostname` (task-level and play-level `vars:`, and registered
results, all work fine) - everything else tracked in the roadmap has
shipped, including three other engine gaps fixed in `0.9.64`-`0.9.65`:
filters in bare conditionals, a failed host now being excluded from
every remaining play in the run (not just the rest of the one it failed
in), and task-level `vars:` itself, which previously did nothing at all
for a plain task.

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
