# krikri - Ansible-Compatible Automation Tool

**A single-binary automation tool that runs real Ansible playbooks - written in Crystal**

[![Version](https://img.shields.io/badge/version-0.9.646-blue)](https://github.com/weirdbricks/krikri)
[![Compatibility](https://img.shields.io/badge/ansible--compatibility-high-brightgreen)](https://github.com/weirdbricks/krikri)
[![Language](https://img.shields.io/badge/language-Crystal-black)](https://crystal-lang.org)

---

## 📋 What this is

krikri parses and runs **standard Ansible playbook YAML directly** -
the same syntax you already write, unmodified. There's no Python, no
`ansible-core`, no `pip`, and no collections directory anywhere in the
picture, on either the controller or the target - it's one compiled binary
(`krikri-playbook`) plus a directory of small compiled module binaries.

It is not a new automation DSL you have to learn, and not a "mostly
compatible" reimplementation verified by eyeballing docs - every plugin's
behavior is checked against real `ansible-playbook` output on real hosts
(see **Differences** and **What's missing** below), and a Docker-based
compatibility harness (`compat/`) runs the same playbooks through both
engines side by side and diffs the resulting state.

---

## 🔀 How this differs from real (Python) Ansible

If you already know Ansible, here's what actually changes when you swap
`ansible-playbook` for `./bin/krikri-playbook`:

### Architecture: compiled binaries, not a Python interpreter per task

Real Ansible ships a Python module's source, templates it, and starts a
fresh Python interpreter for it on the target host **for every single
task**, every run - even when nothing changes. krikri compiles
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
`--forks 1` on both sides. krikri-playbook was built `--release` and
stripped, and ran with `--persistent-daemon --no-batching` (one
long-lived `ssh ... -- <plugin binary> --daemon` connection per host
instead of a fresh `ssh`+`bash`+exec per task; batching was disabled
during measurement because, at the time, it routed around that path).
**That caveat is now historical** - as of 0.9.635 batched groups go over
the daemon too, so the two features compose and a re-run of this table
would no longer need `--no-batching`. The numbers below predate that and
are not re-measured here. `PLAY RECAP`
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
anything changes; krikri-playbook's compiled-binary-plus-persistent-
connection model is why its warm numbers drop so far below its own
cold.

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
./bin/krikri-playbook playbook.yml

# With options
./bin/krikri-playbook --check --diff -i inventory.ini playbook.yml
```

---

## 📁 Project Structure

```
krikri-playbook/
├── krikri-playbook.cr              # CLI entry point
├── src/krikri/            # Engine: parser, task executor, SSH,
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
./bin/krikri-playbook playbook.yml

# With inventory
./bin/krikri-playbook -i inventory.ini playbook.yml

# Dry-run (check mode)
./bin/krikri-playbook --check playbook.yml

# Show changes
./bin/krikri-playbook --diff playbook.yml

# Verbose output
./bin/krikri-playbook -v playbook.yml

# Limit to a host group/pattern, run only tagged tasks
./bin/krikri-playbook -l webservers -t deploy playbook.yml

# Vault-encrypted playbook/vars
./bin/krikri-playbook --ask-vault-pass playbook.yml
./bin/krikri-playbook --vault-password-file pass.txt playbook.yml

# Disable task batching (on by default - see Performance above)
./bin/krikri-playbook --no-batching -i inventory.ini playbook.yml

# Run each task against up to 10 hosts concurrently (default: 5, matching
# ansible-playbook; --forks 1 restores one-host-at-a-time)
./bin/krikri-playbook --forks 10 -i inventory.ini playbook.yml

# Fact gathering policy (default: implicit, matching ansible-playbook):
#   implicit - every play re-gathers
#   explicit - only plays that set gather_facts: true
#   smart    - each host gathered at most once per run
# Under smart, add `meta: clear_facts` to a play (e.g. after a reboot or a
# package install) to force the next play to gather again.
./bin/krikri-playbook --gathering smart -i inventory.ini playbook.yml

# Multiple options
./bin/krikri-playbook --check --diff -i production.ini playbook.yml
```

### Ad-hoc commands (`krikri`)

A separate binary, matching real Ansible's own `ansible`/`ansible-playbook`
split - runs exactly one module against a pattern of inventory hosts,
reusing the same connection/become/check-mode/forks engine as the
playbook runner:

```bash
./bin/krikri all -m ping
./bin/krikri webservers -a 'uptime'
./bin/krikri all -m command -a 'systemctl status nginx'
./bin/krikri all -m copy -a 'src=foo.conf dest=/etc/foo.conf' -b
./bin/krikri db -i inventory.ini -m service -a 'name=postgresql state=restarted' -b
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
# ansible-playbook and krikri-playbook side by side and diffs the result
crystal run compat/run.cr
```

See [compat/README.md](compat/README.md) for what the compatibility
harness covers and how it works.

## 🕐 Recent changes

A short rolling summary of the last few versions - see `git log` for the
complete history (150+ rounds of real-host benchmarking) and
[KNOWN_MISSING.md](KNOWN_MISSING.md)/[ROLES_TESTED.md](ROLES_TESTED.md)
for current-state detail.

- **`0.9.646`** - round 200 (60 more untested roles, fresh host pair per
  role). Three real engine divergences found and fixed: `assert:` was
  missing `strict: true` on its own `that:` evaluation (the identical
  check for `when:` already had it), so a non-bool result (a real int)
  was silently accepted as truthy instead of failing the task
  (`mrlesmithjr.postgresql`); the vendored Crinja fork's `Value#compare`
  had no case for `Crinja::Tuple`, so sorting a dict's `.items()` (a
  list of 2-tuples) raised "cannot compare Crinja::Tuple with
  Crinja::Tuple" even though `Crinja::Tuple` already implements
  element-wise `<=>` (`Oefenweb.bash`, `Oefenweb.nagios_server`); a
  `vars:`-level ternary selecting between two role-default LISTS as a
  loop source resolved to Crinja's Python-repr display text instead of
  a real array (`Oefenweb.percona_client`). A fourth
  (`andrewrothstein.traefik` - a bare `{% if %}`-block-tag variable
  reached as a sub-expression inside a larger literal+template string)
  was found and investigated, but the obvious fix broke three existing
  strict-undefined specs and was reverted - documented in
  `KNOWN_MISSING.md` for a more careful pass. Full per-role verdicts
  and timings in `ROLES_TESTED.md`'s round-200 rows.
- **`0.9.643`** - round 199 (60 untested roles, fresh Atlantic.net host
  pair per role - a revised CLAUDE.md workflow, replacing the previous
  "reuse a pair for a handful of roles" guidance). Two real engine
  divergences found and fixed: `rerender_if_templated` only re-rendered
  a `vars:` value that was a `{{ }}` span spanning its ENTIRE string - a
  mixed literal+template value (`"{{ x }}/y.conf"`) fell through
  unrendered into a chained `.lstrip()`/method call and collapsed to an
  empty string (`Oefenweb.nginx`); a `when:` list's already-parenthesized
  multi-line OR-clause item was double-wrapped by the AND-join and only
  single-unwrapped, so a block ran when it should have skipped
  (`bodsch.dnsmasq`). A third (`lookup(...).method()` chained with no
  `|` mis-locating the lookup call's own closing paren, and a `vars:`
  filter chain resolving to a real Bool losing its type) is documented
  in `KNOWN_MISSING.md`, not yet fixed. Also confirmed the `bodsch.*`
  author's own `bodsch.core`/`bodsch.systemd` collections' custom
  modules/filters hit the existing no-arbitrary-Python scope cut on 8 of
  15 roles tried from that author - not new bugs, but a pattern worth
  knowing before picking more of that author's roles expecting a
  different outcome. Full per-role verdicts and timings in
  `ROLES_TESTED.md`'s round-199 rows.
- **`0.9.641`** - **removes `krikri-playbook-fast` and the whole
  parity-breaking tier** (`0.9.639`'s minimal fact gathering and
  `0.9.640`'s package coalescing). Benchmarked across ten real roles it
  measured **1.00x cold, 1.03x warm** - inside run-to-run variance, with
  the sign flipping per role. Package coalescing never fired on a single
  real role; fact subsetting engaged on 7 of 10 but saves ~50ms against
  multi-second runs. Against that it produced a silent wrong answer:
  `dev-sec.os-hardening` came out `ok=24` where the parity binary gave
  `ok=25`, because the only hardware-fact reference in the role lives
  inside a `.j2` template the planner never opened. Trading parity - the
  entire point of this engine - for nothing measurable is a bad deal, so
  the tier is gone and there is one binary again. The per-module timings
  that settled it are in `git log`.
- **`0.9.638`** - implements the `vars` magic variable for
  `when:`/`assert:` (a dict of every variable in scope). The Crinja path
  already had one; the hand-rolled conditional evaluator did not, so
  `X in vars` failed with "'vars' is undefined" - which blocked the
  whole `prometheus.prometheus` collection, whose preflight uses exactly
  that. Round 198's 10-role python-vs-crystal sweep otherwise matched
  18/20 cold+warm comparisons: mean **1.41x cold, 10.36x warm**.
- **`0.9.637`** - skips the plugin-verification round trip when a
  previous run already verified the same binaries on that host
  (controller-side record, TTL-bounded, keyed on the current local md5).
  Bootstrap is under 5% of a long run but **59-74% of a sub-second one**,
  so this targets the small roles batching cannot help: measured
  **1.41x** warm on `robertdebock.cron`. Self-heals if the binaries turn
  out to be missing - a host rebuilt behind the same address re-uploads
  rather than failing; `testing/ipreuse/` reproduces that case
  deterministically. `--no-plugin-state-cache` opts out.

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

We love Ansible, and this project wouldn't have been possible without it.

krikri-playbook exists because `ansible-core` is genuinely great software.
The playbook/role/inventory model, the module ecosystem, and the
Jinja2-based templating that this project spends so much effort matching
are Ansible's design - the product of more than a decade of real-world use
and the work of the Ansible community and Red Hat behind it. This project
is a tribute to that design as much as it is a reimplementation of it: we
admire it enough to have rebuilt it, line by line, in another language.

Where krikri-playbook is faster, that's simply a different execution model
(compiled binaries vs. a Python interpreter per task) - not a knock on
Ansible, which made the choices it made for good reasons of its own.
`ansible-core` is, and remains, the reference implementation this project
is measured against and tries to be worthy of.

This project was built with the help of AI coding assistants (Claude Code)
and other AI models: MiniMax, DeepSeek Flash, GLM 5.3 Express.

Thanks also to:

- [Crystal](https://crystal-lang.org/), the language this is built with
- [crinja](https://github.com/straight-shoota/crinja) for Jinja2
  templating, among other Crystal shards - see `shard.yml`

**Ansible** and the Ansible logo are trademarks of Red Hat, Inc., registered
in the United States and other countries. This project is not affiliated
with, sponsored by, or endorsed by Red Hat, Inc. or the Ansible project.

---

**krikri - Ansible-compatible automation in Crystal** 🚀
