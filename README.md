# Crystal Ansible - Ansible-Compatible Automation Tool

**A single-binary automation tool that runs real Ansible playbooks - written in Crystal**

[![Version](https://img.shields.io/badge/version-0.9.603-blue)](https://github.com/weirdbricks/crystal-ansible)
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

- **`0.9.603`** - a role can now see every other role's `vars/main.yml`
  and `defaults/main.yml`, including roles that run LATER in the play -
  real Ansible loads them all into the variable manager at play setup,
  where this engine scoped them to the owning role. That is what made
  `geerlingguy.php`'s own `when: php_packages is not defined` run a task
  real Ansible skips, `php_packages` being defined by a role further
  down the same dependency chain. The precedence it introduces was
  mapped against ansible-core 2.19.4 with a three-way matrix rather than
  assumed - all roles' defaults < this role's own defaults < play vars <
  all roles' vars < this role's own vars - and `include_role:` stays
  scoped, since only static `roles:` are loaded at setup.

- **`0.9.602`** - `omit` no longer leaks this engine's internal
  sentinel as literal text. `{{ x | default(omit) }}` used anywhere
  except as a whole module parameter emitted
  `__crystal_ansible_omit__` into logs, config files and command lines
  as if it were real content; a bare `{{ omit }}` failed the task
  outright as an undefined variable. It now renders as nothing
  mid-string, is elided from list and dict literals (in BOTH
  evaluators), and still drops a whole parameter when it is the entire
  value - with genuinely falsy neighbours (`""`, `0`, `false`) kept.

- **`0.9.601`** - closes the last three documented gaps, leaving
  [KNOWN_MISSING.md](KNOWN_MISSING.md)'s "Real gaps" section empty.
  `ansible_distribution` now reports real Ansible's per-distro DISPLAY
  name rather than the capitalized os-release ID - "Linux Mint Debian
  Edition" not "Linuxmint", "Debian" not "Raspbian" - ported branch for
  branch from its own `parse_distribution_file_Debian` and checked
  against that same Python parser over a corpus of real os-release
  files. The `debugger:` prompt gained real Ansible's ASSIGNMENT
  commands (`task.args['x'] = ...`, `task_vars['y'] = ...`) plus
  `u`/`update_task`, including the subtle rule that a `task_vars` edit
  changes nothing until `u` re-templates the task. And
  `--scp-extra-args` now actually extends this engine's `scp` command
  lines - the note claiming it had "nothing to attach to" was wrong
  about the engine's own file transfers. Verifying these turned up
  three NEW divergences, documented rather than fixed - most notably
  that ansible-core 2.19 made Jinja templating native-typed (a
  `{{ }}` over a YAML int yields an int, not the string this engine
  still produces).

- **`0.9.600`** - `notify:` validation moved from parse time to run
  time, where real Ansible does it. An unmatched `notify:` is real
  Ansible's error only when the notifying task actually fires the
  notification: a task that reports `ok` (unchanged) or is skipped by
  its `when:` notifies nothing and the run completes green. This engine
  rejected all three upfront with rc=4 - failing playbooks real Ansible
  runs fine - while simultaneously MISSING a bad notify inside an
  `include_tasks:`-loaded file, which no parse-time sweep can see. It
  now aborts at the notifying task with real Ansible's own message and
  rc=1, and the task batcher ends its SSH batch there so the steps
  after it never run, matching what real Ansible actually executes on
  the target.

- **`0.9.599`** - closes the last "Real gaps" entry in
  [KNOWN_MISSING.md](KNOWN_MISSING.md), plus a second bug the live
  re-verification of it surfaced. A role default computed from another,
  genuinely-never-set variable (`phpmyadmin_mysql_password: "{{
  mysql_root_password }}"`) rendered as the literal seven-character text
  `undefined` and the run continued - writing that string into
  phpMyAdmin's config as the real MySQL password - where real Ansible
  fails the task naming the innermost missing variable. Strict
  module-arg templating now follows the chain instead of stopping at the
  first level, and an unresolvable chain is handed to the template
  engines as a real undefined value, so `| default('x')`, `is defined`
  and `when:` gates over one all answer what real Ansible answers; the
  deliberate leniency everywhere else is unchanged. Underneath it, a
  `meta/main.yml` **dependency's defaults were discarded** once that
  dependency's own tasks were loaded - so the extremely common "role B
  declares role A as a dependency, then references A's defaults" shape
  silently resolved to nothing throughout B.

- **`0.9.593`-`0.9.598`** - six fixes from a 60-role Ubuntu marathon:
  a huge (5934-line) template crashed the whole `template:` task with a
  PCRE2 JIT-stack overflow, from two rewrite regexes whose lazy
  quantifiers could cross newlines and, on a file with sparse/unmatched
  brace/quote characters, backtracked across nearly the whole file
  looking for a match; a dotted-path lookup (`item.1.stdout`, pulling
  the 2nd element out of a `with_indexed_items:` pair) only supported
  Hash key lookup, not numeric indexing into an Array; `with_dict:` over
  an empty list (a common "override me" default shape) returned nil for
  the whole loop instead of treating it as an empty dict, running the
  task once with `item` undefined instead of skipping it like real
  Ansible; the `ansible_lsb` fact (`/etc/lsb-release`) was entirely
  unimplemented, breaking a PPA apt-repo template's codename lookup. The
  "unavailable modules" exit-code check itself was a static whole-
  playbook scan that flagged a module even inside a branch unreachable
  on every host (e.g. an OS-family-gated task) - now only counts a
  module if its task's own `when:` would actually have let it run,
  matching real Ansible's lazy resolution. A task-level `import_role:`
  to a role never installed ran extra tasks before failing instead of
  refusing the whole playbook statically (`rc=1`, zero tasks) the way
  real Ansible does. `pip:` never checked the pip executable actually
  exists before deciding there was nothing to install, silently
  no-op'ing instead of failing on a genuinely pip-less host whose
  package list happened to be empty on that OS.
- **`0.9.592`** - `until:`/`when:`/`failed_when:`-style Jinja "is" tests now
  recognize `successful`/`failure`/`change`/`skip` (real Ansible's own
  aliases for `success`/`failed`/`changed`/`skipped`), in both the
  hand-rolled `ConditionalEvaluator` and Crinja. `until: result is
  successful` - a very common retry idiom - previously matched nothing,
  so the retry loop always ran its full default 3 attempts regardless of
  the first attempt's real success; by the final (now-idempotent) attempt
  the task's own result silently overwrote a genuine `changed: true` with
  `changed: false`. Found benchmarking `mrlesmithjr.motd`'s `apt:` task.
- **`0.9.589`-`0.9.591`** - three fixes from a 60-role RHEL marathon:
  SSH transport now honors `ANSIBLE_HOST_KEY_CHECKING`/
  `ANSIBLE_SSH_HOST_KEY_CHECKING` (previously hardcoded
  `StrictHostKeyChecking=accept-new`, which still refuses a CHANGED
  host key - real Ansible's `host_key_checking=False` accepts one,
  which matters for an ephemeral cloud host whose IP got reused with a
  different key); a missing role (play-level `roles:` or a role's own
  `meta/main.yml` dependency) now exits 1 like real Ansible instead of
  this engine's generic parser-error 4; `ansible_distribution_release`
  is now always a defined fact (falls back to `""` on RHEL-family,
  which has no `VERSION_CODENAME`) instead of fully undefined, fixing
  a `with_first_found:` path template that referenced it.
- **`0.9.588`** - two fixes from a real GPG-check and legacy-`include:`
  divergence: `yum:`/`dnf:`/`package:` now always pass
  `--setopt=localpkg_gpgcheck=1` for a URL/local RPM install unless
  `disable_gpg_check: true` - dnf's own actual default leaves that OFF
  regardless of `dnf.conf`'s repo `gpgcheck=1`, which previously let a
  tampered or unsigned RPM install silently where real ansible correctly
  refuses it. A removed action plugin (bare `include:`, gone from
  ansible-core after 2023-05-16) now exits 1 like real Ansible, not this
  engine's generic parser-error 4.
- **`0.9.587`** - `ansible_connection` is now always resolvable as a
  magic var (defaults to `"local"`/`"ssh"` per host, matching real
  Ansible), instead of undefined unless something explicitly set it.
  Found benchmarking `buluma.selinux`: its own container-guard
  (`when: ansible_connection not in [...]`) hard-failed with
  `'ansible_connection' is undefined` on a plain SSH host.
- **`0.9.585`** - implemented `loop_control:`'s `label:` and
  `extended:`. `label:` was ignored, so a loop over dicts printed the
  whole dict on every line instead of the field the playbook chose;
  `extended:` left `ansible_loop` undefined, which FAILED any task using
  it. `ansible_loop` now carries index/index0/revindex/revindex0/first/
  last/length/allitems, with nextitem and previtem ABSENT at the ends as
  real Ansible leaves them.
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
