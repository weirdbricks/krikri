# Crystal Ansible - Ansible-Compatible Automation Tool

**A single-binary automation tool that runs real Ansible playbooks - written in Crystal**

[![Version](https://img.shields.io/badge/version-0.9.501-blue)](https://github.com/weirdbricks/crystal-ansible)
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

- **`0.9.501`** - `--persistent-daemon` is now the default (was opt-in
  behind a flag since `0.9.496`). New `--no-persistent-daemon` flag
  restores the old per-task ssh-fork path. Promotion is based on the
  `0.9.496` 10-role real-host benchmark (`--persistent-daemon` vs
  ansible-core 2.19.4, ~6.3× mean warm speedup) and the absence of
  regressions across the per-role rounds since. The per-task path is
  still in place as the fallback for `become:`, `gather_facts:`,
  batched task groups, remote `async:`, and any daemon-connection
  failure - so dropping the flag never reduces functionality, only
  throughput. The doc's "what would re-open #19 (libssh2)" question
  is also closed for the same reason: with daemon mode default,
  ssh-process overhead is amortized to ~once per play per host, and
  re-measurement would need to happen against a real `--forks 50`
  inventory on `0.9.501`, not the pre-`0.9.496` per-task fork+exec
  cycle the original 3-10× estimate was based on.
- **`0.9.500`** - `TaskExecutor` runs persistent host worker fibers:
  one fiber per host for the executor's lifetime (vs the old
  spawn-per-(task, host) pattern). Per-task dispatch overhead: 88.6%
  wall-clock reduction + ~60× allocation reduction (microbench;
  real-task wall-clock is smaller since SSH round trips dominate).
  `gather_facts_for_all_hosts` left as-is (one-shot per-play, no
  churn issue). 1501 specs, 0 failures.
- **`0.9.499`** - `VarSubstitutor.new`'s `vars.dup` is now lazy:
  triggered only on first mutation (magic-var insertion or
  `set_variable`), not eagerly at construction. Per-call bytes in the
  templated substitute path drops 26%, in the no-placeholder
  early-exit path drops 99.7%. For a 300-task hardening role against
  1 host with ~6 plain-string params per task, this saves ~48 MB of
  allocation per run. Aliasing-safety contract from `0.9.494`/`0.9.485`
  preserved (writes still trigger a private copy). 1501 specs, 0
  failures.
- **`0.9.498`** - narrow sub-scope of `0.9.494` (#20): `substitute()`
  skips its `.strip` allocation when `{{ ... }}` has no leading or
  trailing whitespace, and `MustacheScanState` (the brace/quote
  tracker inside `expand_mustache_spans`) is now a struct, so it lives
  on the worker's stack frame instead of being a per-call heap object.
  Per-task bytes in the templated substitute path drop 2.5-9%
  depending on template shape (whitespace templates get only the
  struct saving; no-whitespace templates get both). 1501 specs, 0
  failures.
- **`0.9.496`** - new experimental `--persistent-daemon` flag: for
  solo (non-batched, non-`become:`) remote tasks, keeps one long-lived
  `ssh ... -- <plugin binary> --daemon` connection per host instead of
  forking a fresh `ssh`+`bash`+`exec` per task, speaking a small
  length-prefixed JSON protocol over that session's stdin/stdout. Off
  by default - `become:` tasks, batched task groups, and remote fact-
  gathering always use the existing per-task path regardless of the
  flag. Live-verified on a real host, not just spec-tested: a real
  `ansible.builtin.reboot` mid-play correctly invalidates the stale
  daemon connection and falls back to the proven per-task path for the
  very next task, re-establishing a fresh daemon afterward, with no
  explicit reboot-handling code anywhere in the new daemon logic -
  that's the entire reconnect story. `become: true` and `gather_facts:
  true` were both confirmed to correctly bypass the daemon path
  end-to-end. New automated coverage
  (`spec/unit/plugin_daemon_spec.cr`) drives the real compiled daemon
  binary as a local subprocess. `crystal spec`: 1501 examples, 0
  failures. A 10-role live benchmark (fresh host pair per role,
  `--persistent-daemon --no-batching` vs `ansible-core` 2.19.4)
  measured warm idempotent replays 3.5x-11.9x faster with the daemon
  on - see **Performance** for the full table.
- **`0.9.495`** - `ExpressionEvaluator#evaluate`'s dispatch re-scanned
  every `{{ }}` body's text from scratch on every call (up to 6 full
  character-by-character passes before ever reaching the real
  evaluation) to classify which of 4 shapes it has (ternary-with-else,
  ternary-no-else, boolean-logic, or plain) - now memoized by literal
  text in a process-wide cache, since the classification is a pure
  function of the string. Deliberately narrower than this item's
  original proposal: a prior pass (`0.9.485`) found that caching WHICH
  BRANCH ultimately handles an expression is unsafe (Crinja's
  success/failure can depend on a variable's runtime value, not just
  the expression's static text), so only the shape classification is
  cached - the actual render/fallback still runs fresh every time.
  Differential-tested against 3080 real `{{ }}` expressions scraped
  from `testing/roles` + 21 benchmarked Galaxy roles: 3079/3080
  byte-identical output before/after, the 1 divergence being
  `password_hash(...)`'s own random salt. 2000 tasks repeating the same
  ternary/filter text: 0.19s -> 0.16s (~1.2x). `crystal spec`: 1498
  examples, 0 failures.
- **`0.9.494`** - `build_vars_context` (rebuilt from scratch on every
  single (task, host) pair) now caches its per-host-invariant inputs
  behind the same generation counter `0.9.491`'s `hostvars`/`groups`
  caching introduced: `base_context_a` (play_vars/host.vars/
  registered_vars, itself now built via a bulk `Hash#dup` - measured
  ~3.4x faster than an `.each` rebuild for a same-sized hash) and
  `base_context_b` (included_vars/facts). 1 host/1000 tasks/500 play
  vars after `package_facts:`: 0.33s -> 0.23s (~30%); 30 hosts/100
  tasks/100 inventory vars each: 0.52s -> 0.48s (~8%) - both within the
  original 20-40% estimate's range. Not a single cache: the real
  precedence order interleaves per-task tiers (role_vars/task.vars)
  between the two per-host groups, so preserving it needed 2 caches, not
  1. One real precedence bug found by the existing spec suite before it
  shipped: an early version cached the `ansible_host ||= ...` fallback
  inside the wrong (empty) hash, which couldn't see that an inventory
  line's real `ansible_host=` (already merged in from `host.vars`) should
  win - fixed by leaving those 3 magic keys uncached, applied directly
  against the real context where the old code always evaluated them. New
  regression spec exercises every real invalidation path in one
  sequence - `register:`/`set_fact:`/`include_vars:` each visible on the
  very next task, a role's own `role_defaults` visible during that role
  and gone again immediately after. `crystal spec`: 1494 examples, 0
  failures (run 3 times - spec order is randomized by default - to rule
  out order-dependent staleness).
- **`0.9.493`** - `VarSubstitutor` gained a second, more specific
  constructor overload for the (extremely common) case where the
  caller already has a `Hash(String, JSON::Any)` vars_context - a bulk
  `Hash#dup` instead of the general overload's per-key type-coercion
  copy. `TaskExecutor` builds a fresh `VarSubstitutor` from
  `vars_context` at 28+ call sites (`when:`, param substitution,
  `changed_when:`/`failed_when:`, delegate_to: resolution, and once per
  loop iteration), all already declared as exactly that type, so
  Crystal's own overload resolution routes every one onto the fast path
  with no call-site changes. A 200-item loop against a 1000-var context
  measured 0.10s -> 0.02s (~5x, ~24.5x combined with `0.9.492`'s own win
  on the same benchmark); a non-loop 300-task/2000-var play (this
  change isn't loop-specific) dropped from 0.44s to 0.17s on top of
  `0.9.492`'s own result. Still a real `.dup`, not a bare reference -
  `#add_magic_variables` mutates `@vars` in place, and aliasing the
  caller's own hash would leak that mutation back into it, this
  project's single most-repeated bug class - covered by a new
  regression spec asserting the caller's hash is untouched. `crystal
  spec`: 1492 examples, 0 failures.
- **`0.9.492`** - the Crinja variable context is now lazy: a bare `{{
  var }}` used to convert the ENTIRE variable context (`JSON::Any` ->
  `Crinja::Value`, plus a full re-templating pass and a second full copy
  for the `vars` magic dict) regardless of how many variables the
  template actually read. A new `LazyCrinjaContext` converts one entry
  on first access, memoizing into the same `Crinja::Context` scope
  `lib/crinja` already provides - 300 tasks x 2000 play vars reading one
  var each measured at 1.22s before, 0.44s after (~2.75x). Each render
  still gets a fresh child context (parented to the shared lazy one) so
  a template's own `{% set %}` bindings can't leak into a later render
  off the same renderer - verified directly, not just by spec. Found and
  fixed one real gap in the design along the way: `lookup('varnames',
  pattern)` needs every variable NAME in scope, not just the ones
  already accessed - missed by the original investigation's `lib/
  crinja`-only grep for `context.keys` callers, since the actual caller
  lives in this codebase's own `jinja_filters.cr`; fixed with a cheap
  `#keys` override (names only, no value conversion) that the full
  `crystal spec` suite's 2 `varnames`-dependent specs caught immediately
  (masked in the file's own isolated run by the project's pre-existing,
  documented require-ordering artifact). `crystal spec`: 1490 examples,
  0 failures.
- **`0.9.491`** - `build_hostvars`/`build_groups` (the `hostvars[...]`/
  `groups[...]` magic vars) memoized per `TaskExecutor`, closing a
  quadratic-in-host-count gap: both were previously rebuilt from scratch
  on EVERY (task, host) pair, each rebuild walking the whole inventory -
  30 hosts x 100 tasks measured at 2.92s before, 0.20s after (~14.5x,
  matching `SUGGESTED_PERFORMANCE_IMPROVEMENTS.md` item #16's estimate
  exactly). Cached behind a single generation counter bumped at every
  real mutation site of the 3 inputs that can change it mid-play -
  `@facts` (gather_facts/set_fact/package_facts, meta: clear_facts),
  `@registered_vars` (register:, incl. the run_once: copy-forward path),
  and `meta: refresh_inventory`'s in-place reload - so a later task on
  one host still sees an earlier task's register:/set_fact:/clear_facts
  on a DIFFERENT host via `hostvars[...]`, not a stale pre-mutation
  snapshot. Regression spec added exercising exactly that cross-host
  staleness risk, not just the existing single-shot hostvars/groups
  reads. `crystal spec`: 1490 examples, 0 failures.
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
