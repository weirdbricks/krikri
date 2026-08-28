# Crystal Ansible - Ansible-Compatible Automation Tool

**A single-binary automation tool that runs real Ansible playbooks - written in Crystal**

[![Version](https://img.shields.io/badge/version-0.9.630-blue)](https://github.com/weirdbricks/crystal-ansible)
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

**Short version: as of this version, there is one known real correctness
gap left open** (a Crystal/OpenSSL TLS-compatibility limitation talking
to a server running very old TLS - see KNOWN_MISSING.md) - the primary
way gaps get found here is running real production Ansible roles (from
Galaxy) against both engines on real hosts and diffing the result, not
a pre-planned feature checklist, and every OTHER gap found that way has
been fixed. The structural differences above are the only *deliberate*
exclusions.

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

- **`0.9.630`** - round 194 (30 untested roles, fresh server pair per
  role, cold+warm both engines): the three remaining engine divergences
  closed. `include_tasks:`/`include_role:` now reject `become:`/
  `become_user:` like real ansible-core's strict TaskInclude/IncludeRole
  allowlist (rc=4, whole-playbook abort) - the java-oracle dependency
  case; `dict[var]["key"]` chained-subscript `is defined` now reports
  undefined when the inner lookup misses (pkg-upgrade on Rocky 9.6) so
  the task is correctly skipped; and a strict `{% if undefined_var %}`
  block-tag render now raises like real ansible's strict Jinja2
  (openjdk's stat-arg finalization) instead of silently treating
  `undefined == "jre"` as falsy.
- **`0.9.630`** - round 193: legacy `action: <module> [k=v]` /
  `{module:, args:}` directive now rewritten to the target module
  (stefangweichinger.ansible_rclone handler no longer crashes the whole
  binary with "Plugin binary not found: action").
- **`0.9.629`** - round 192: recursive re-templating of task args now
  scoped to variable-origin leftovers (real ansible's single-pass
  semantics); literal brace text in command args passes through verbatim.
  Fixed `gantsign.helm` - both engines rc=0 cold+warm on a fresh pair.
- **`0.9.628`** - round 192: `ansible.builtin.git_config` FQCN now resolves
  to the existing git_config plugin (was only registered as
  community.general.*); `gantsign.git_credential_manager` clean both
  engines on a fresh pair.
- **`0.9.627`** - round 191 (60 new roles, fresh server pair per role,
  each run twice per engine): `apt state: latest` now fails when apt-get
  can't locate a package instead of reporting "already at latest" with
  rc=0; verified against `buluma.sensu-install`. Full per-role timings in
  `ROLES_TESTED.md`.
- **`0.9.626`** - round 191: new `ansible_userspace_bits` fact;
  `gantsign.ansible-role-golang`'s include-vars chain now resolves
  identically to real ansible.
- **`0.9.625`** - six round-190 fixes from a 60-role marathon (55 same-rc,
  11 divergences, 6 real engine bugs): `.yaml` main-file roles loaded an
  EMPTY defaults/vars/tasks set (ara_api/handbrake); `command:` +
  `environment: PATH:` could not find venv binaries (execvp used the
  parent PATH); nested task-vars kept bare-mustache values as unevaluated
  strings; `set_fact` containers rendered as Python-repr text instead of
  native dicts (Django: `float + str`); `apt_key: file:` and
  `lookup('config', ..., wantlist=True)` were unimplemented. Plus facts
  now derive user_id/dir/shell from getpwuid instead of ENV (unset in
  non-login SSH shells).
- **`0.9.624`** - three round-189 fixes, all live-verified on fresh hosts:
  YAML folded-scalar `when:` conditions (more-indented continuation lines
  embed real newlines) silently evaluated FALSE - every loop item skipped;
  `regex_search` with no match returned the `"undefined"` sentinel string
  instead of Python None, so a list-form `failed_when: (... ) is not none`
  FAILED a succeeding task; and `async:`/`poll: 0` over SSH was refused
  outright, so fire-and-forget reboot idioms never actually rebooted -
  remote async now mirrors real Ansible's `~/.ansible_async`.
- **`0.9.623` (continued)** - after the vsftpd re-verify landed,
  ran the rest of the original round 188 shortlist (9 new roles:
  `andrewrothstein.{calicoctl,cfssl,coder,bazel}`,
  `mrlesmithjr.{nfs-server,ansible_apt_sources}`,
  `geerlingguy.{sonar-runner,ssh-chroot-jail}`, `buluma.forensics`,
  fresh Atlantic.net pair per role, cold + warm both engines). 8/9
  clean, 1/9 environmental both-fail (`geerlingguy.ssh-chroot-jail` -
  role tries to copy `/usr/bin/vim` into the chroot; `vim` isn't
  installed on a fresh Rocky 9.6 image, both engines hit the same
  `"/usr/bin/vim not found"` and fail the task the same way per the
  rule "if they fail the same way that's fine"), 1/9 a NEW real
  engine bug: `buluma.forensics` (Rocky 9.6, crystal rc=2 / real
  ansible rc=0) - the role's `command_collector | Save output` task
  uses `delegate_to: localhost` for an `ansible.builtin.copy` module,
  and crystal-ansible tries to scp the plugin binary to `localhost:22`
  ("Connection refused" on a cloud VPS whose controller has no sshd
  running); real ansible-core runs the plugin via `connection: local`
  and never ssh's to itself. Fix is in `task_executor.cr`
  `delegate_to:` resolution: short-circuit to `connection: local` when
  the delegate target is the controller (localhost / 127.0.0.1 /
  controller hostname). The bug is structural and likely affects
  every role that uses `delegate_to: localhost` for an SSH-uploading
  module on a controller without sshd. See
  [[round188-delegate-to-localhost-ssh-reupload]]. Performance
  observations across the 9 new roles: crystal 1.3x-15x faster than
  python on every role, both phases - the persistent-daemon + batched
  task model compounds across role complexity (nfs-server: 77s->28s
  cold, 32s->2s warm; forensics: 154s->56s cold, 149s->62s warm; cfssl:
  51s->16s cold, 40s->11s warm).

- **`0.9.623`** - two fixes from a `weareinteractive.vsftpd` re-verify
  (Ubuntu 22.04, fresh Atlantic.net pair, byte-identical to real
  ansible-core 2.19.4 once both were in). The 0.9.608 community.crypto
  additions had marked the role "unblocked" but the engine was still
  broken on it: `import_tasks: ... when: <gate>` was combining the
  parent's `when:` as `"#{child} and #{parent}"` (child operand first),
  so when the parent gate was `false` the child operand was still
  evaluated, hitting strict-undefined on a `register:` reference from
  a prior inner task that the gate would have skipped, and aborting
  the whole play with `'item_stat.stat.exists' is undefined` - real
  Ansible would have skipped the whole file at the parent's
  `when: false` decision. One-line fix in `playbook_parser.cr:1469`:
  parent `when:` prepended, not appended, so `and` can short-circuit
  left-to-right. And `MODULE_SEARCH_COLLECTIONS` was missing
  `"community.crypto"`, so bare short names (`openssl_privatekey:`,
  `openssl_csr:`, `x509_certificate:`, `openssl_pkcs12:`,
  `openssh_keypair:` - the community-collection idiom) had no
  FQCN-prefix to try against `AVAILABLE_PLUGINS`, the resolver
  returned `nil`, and the task was silently dropped with a
  "uses unimplemented plugin" warning despite the plugin source AND
  compiled binary both existing - the 0.9.608 unblock arguably got
  the engine past `rc=4` errors but didn't actually run the work in
  roles that use the bare short names. One-line fix in
  `playbook_parser.cr:932-935`: added `"community.crypto"` to the list.
  After both fixes, the re-verify is byte-identical (real 63.91s/40.89s
  vs crystal 20.73s/3.84s; same recap both phases) and 5 new unit +
  integration specs pin the fix.

- **`0.9.616`-`0.9.622`** - seven fixes from a 60-role marathon (40
  andrewrothstein.\*/mrlesmithjr.\*/etc. on Ubuntu 22.04, 20 more on
  Rocky 9.6, fresh host pair per distro, every role run twice for
  idempotency). A multi-package `pip: name:` list containing a shell
  metacharacter (`urllib3<2`) broke the `bash -c` invocation it reached
  unescaped, and its own idempotency check surfaced once fixed
  (`0.9.616`); `lookup('file', ...)` on a missing file silently returned
  "undefined" instead of raising like real Ansible, and that sentinel
  then got written straight into `~/.ssh/authorized_keys` as if it were
  a real key (`0.9.616`); `user:`'s registered result never carried
  home/uid/group/shell/name at all (`0.9.617`); a nonexistent command's
  exec failure never populated rc/stdout the way real Ansible's own
  ENOENT handling does, leaving a `failed_when: false`-guarded probe's
  later `.stdout` reference genuinely undefined (`0.9.618`); three
  stacked fixes chasing the SAME motivating role -
  `systemd_service`'s `scope: user` was completely unhandled
  (`0.9.619`), fixing that exposed real Ansible's own auto-set
  `XDG_RUNTIME_DIR` for scope:user having no equivalent here
  (`0.9.620`), and fixing THAT exposed the actual root cause: block-
  level `become:`/`become_user:` was never inherited by child tasks at
  all, so an entire block silently ran as root (`0.9.621`); and a
  `meta/main.yml` dependency written with `src:` (real Ansible's own
  `RoleRequirement` key) aborted parsing the WHOLE PLAYBOOK (`0.9.622`).

- **`0.9.613`-`0.9.615`** - three fixes from a 60-role marathon (40
  andrewrothstein.\*/buluma.\*/etc. on Ubuntu 22.04, 20 more on Rocky
  9.6, fresh host pair per distro, every role run twice for
  idempotency). A list-form `when:` made of `x | bool` filter chains
  hard-failed under 0.9.612's new strict-boolean check: each chain's own
  render path produces Python-repr text ("True"/"False"), and
  `JSON.parse("True")` isn't valid JSON, so the fallback wrapped the
  literal text in a String instead of a real Bool (found via
  `andrewrothstein.docker_engine`'s reconfigure handler). A plain
  `{{ expr -}}`/`{{- expr }}` whitespace-trim marker had its CHARACTER
  stripped but never its WHITESPACE-TRIMMING EFFECT applied, so a
  multi-line YAML `|-` block built from one such span per line kept
  every line break in its rendered output (found via
  `andrewrothstein.temurin`'s own filename/URL construction, breaking
  the download outright). And a bare FLOAT literal (`5.1`) in a
  comparison had no case at all in the strict-undefined evaluator - only
  bare INTs did - so `when: zsh_version.stdout | float < 5.1` raised
  "'5.1' is undefined"; fixing that also exposed the comparison itself
  had no float-numeric fallback, only int, which would have compared
  "10.2" < "5.1" lexicographically wrong.

- **`0.9.605`-`0.9.606`** - two fixes from a 60-role marathon (40
  buluma.\* on Ubuntu 22.04, 20 andrewrothstein.\* on Rocky 9.6, fresh
  host pair per distro, every role run twice for idempotency). A dynamic
  `include_role:` naming a role that fails to load (found via
  `andrewrothstein.libvirt`'s own dependency on the since-removed
  `andrewrothstein.qemu`) was double-counted in the recap - both the
  eager `ok` increment added for a *successful* include and
  `fail_include`'s own `failed` increment fired for the same task, so a
  fatal `ok=0 failed=1` on real Ansible showed as `ok=1 failed=1` here;
  the `ok` increment now only fires once the role actually loads.
  Separately, `ansible.builtin.user`'s `groups:` argument passed a
  literal `"[]"` straight to `useradd -G` when `groups: "{{ x |
  default([]) }}"` rendered from an undefined `x` (found via
  `andrewrothstein.gitlab_runner`'s own "Add the gitlab-runner user to
  other groups" task) - real Ansible's `list`-typed argspec recognizes
  a `[...]`-shaped string and parses it back into a real (here, empty)
  list before it ever reaches `useradd`; this engine now special-cases
  the empty-list text the same way.

- **`0.9.612`** - three parity fixes the previous one exposed. A
  conditional must now end in a real boolean, as ansible-core 2.19
  requires: `when: some_string` / `some_int` / `some_list` fail with
  real Ansible's own message instead of silently taking a branch it
  refuses to take - and `ANSIBLE_ALLOW_BROKEN_CONDITIONALS` relaxes it
  here exactly as it does there. Containers render in Python's `repr`
  form (`['a', 'b']`, `{'k': 'v'}`) in final output, where they had
  rendered as JSON; internal rendering deliberately stays JSON, since
  this engine renders sub-expressions to text and parses them back.
  And INI host lines are shlex-split, so an inline var may contain
  quoted spaces and its quotes are consumed by the splitter.

- **`0.9.611`** - INI inventory values are now typed the way real
  Ansible types them: by Python's `literal_eval`, where `True`/`False`
  are booleans, `None` is null, `[1, 2]` and `{'k': 'v'}` are real
  containers - and `true`, `false`, `yes`, `no`, `null` and `~` are all
  plain strings. This engine had been booleanizing the lowercase forms
  and leaving containers as text, so a list-valued inventory var could
  not be looped over, and `[all:vars] enabled=false` quietly took the
  false branch where real Ansible sees a (truthy) string. Verified
  value-by-value against ansible-core 2.19.4 over 27 shapes; five unit
  specs that had asserted the old behavior were rewritten against the
  differential.

- **`0.9.610`** - inventory sources. `ansible-playbook play.yml` with no
  `-i` (or with an unreadable one) stopped here with "Error loading
  inventory" where real Ansible warns and carries on with the implicit
  localhost - the common CI shape for a `hosts: localhost` playbook.
  `-i <directory>` (several inventory files merged, ignoring backup and
  hidden files) and `-i "host1,host2,"` were both unsupported. Fixing
  the directory case surfaced a bigger one underneath: an `[all:vars]`
  block applied to **nobody**, in single-file inventories too, because
  the INI parser files hosts under their own group and never under
  `all` - one of the most common things an inventory contains, silently
  ignored in its entirety. A regression sweep alongside it caught
  `group_names` omitting `ungrouped`, so a host listed above any
  `[section]` header reported belonging to no groups at all.

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
