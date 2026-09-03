# krikri - Ansible-Compatible Automation Tool

**A single-binary automation tool that runs real Ansible playbooks - written in Crystal**

[![Version](https://img.shields.io/badge/version-0.9.721-blue)](https://github.com/weirdbricks/krikri)
[![Compatibility](https://img.shields.io/badge/ansible--compatibility-high-brightgreen)](https://github.com/weirdbricks/krikri)
[![Language](https://img.shields.io/badge/language-Crystal-black)](https://crystal-lang.org)
[![Homebrew](https://img.shields.io/badge/homebrew-tap-blue)](#install-via-homebrew-macoslinux-prebuilt-binaries)

---

## 📋 What this is

krikri parses and runs **standard Ansible playbook YAML directly** -
the same syntax you already write, unmodified. There's no Python, no
`ansible-core`, no `pip`, and no collections directory anywhere in the
picture, on either the controller or the target - it's one compiled binary
(`krikri-playbook`) plus a directory of small compiled module binaries.

It is not a new automation DSL you have to learn, and not a "mostly
compatible" reimplementation verified by eyeballing docs - every plugin's
behavior is checked against real `ansible-playbook` output on real hosts,
across **1,484 real Galaxy roles tested to date** (see
[ROLES_TESTED.md](ROLES_TESTED.md); **Differences** and **What's missing**
below), and a Docker-based compatibility harness (`compat/`) runs the same
playbooks through both engines side by side and diffs the resulting
state. Any observed
divergence from real Ansible's behavior is treated as a bug in this
project, not a documented limitation, unless it's one of the deliberate
structural exclusions called out below.

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

### What's structurally different (by design, not a gap)

No arbitrary Python execution (a role's private `library/*.py` module
can't run - there's no interpreter to run it in), cloud provider modules/
inventory plugins (`amazon.aws`, `azure_rm_*`, ...), and a handful of
narrower cuts (`docker_*`'s `api_version:` pin, a few `meta:` actions).
See **What's missing** below.

---

## ❓ What's missing

Gaps here are found by running real production Ansible roles (from
Galaxy) against both engines on real hosts and diffing the result, not
from a pre-planned feature checklist:

- **[KNOWN_MISSING.md](KNOWN_MISSING.md)** - the current, short,
  up-to-date list of any open real gaps plus the full explicit scope-cut
  list (cloud modules, role-private modules, a handful of untestable/
  narrow module gaps, etc., each with the reasoning behind it).
- **[ROLES_TESTED.md](ROLES_TESTED.md)** - the current status of every
  real Ansible Galaxy role that's been benchmarked against a live host,
  one line each, so you can check whether something resembling your own
  playbooks has already been exercised.

---

## ⚡ Performance

Native compiled modules, one persistent SSH connection per host, and
batched round trips make the biggest difference on **idempotent
re-runs** - the common case for a config-management tool running on a
schedule, where most tasks find nothing to change but Python still pays
a fresh interpreter-and-module cost per task regardless.

A 3-way benchmark against real `ansible-playbook` and `ansible-playbook`
with the Mitogen strategy plugin, across a 100-role random sample, found
61 roles where all three engines produced an identical successful
outcome:

| Phase | real Ansible | Ansible + Mitogen | krikri-playbook | krikri vs Ansible | krikri vs Mitogen |
|---|---|---|---|---|---|
| Cold (total) | 2176.6s | 1246.2s | 920.6s | **2.36x faster** | **1.35x faster** |
| Cold (median/role) | 22.04s | 11.54s | 5.32s | 3.43x faster | 1.82x faster |
| Warm (total) | 1328.0s | 598.2s | 185.3s | **7.17x faster** | **3.23x faster** |
| Warm (median/role) | 14.49s | 6.97s | 2.00s | 7.99x faster | 4.00x faster |

krikri-playbook was the fastest of the three engines in 57 of 61 roles
(93%). Full methodology and the broader 78-role set: see
[ansible-vs-mitogen-vs-krikri.md](ansible-vs-mitogen-vs-krikri.md).

Per-role cold/warm timings: see [ROLES_TESTED.md](ROLES_TESTED.md).

---

## 🚀 Quick Start

### Install via Homebrew (macOS/Linux, prebuilt binaries)

```bash
brew tap weirdbricks/krikri https://github.com/weirdbricks/krikri
brew install weirdbricks/krikri/krikri
```

Covers macOS (arm64/x86_64) and Linux (arm64/x86_64) - no Crystal
toolchain needed. See **Build & Run** below to build from source instead.

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
├── plugins/                     # One binary per Ansible module
├── spec/                        # crystal spec unit + integration tests
├── compat/                      # Docker-based real-ansible-playbook
│                                 # compatibility harness
├── testing/                     # Manual smoke-test fixture playbooks
├── build.sh                     # Build script (all plugins + CLI)
└── shard.yml                    # Dependencies
```

Go to [`plugins/`](plugins) to see the implemented plugins.

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

## 🐐 Why "krikri"?

The kri-kri (κρι-κρι) is the [Cretan wild
goat](https://en.wikipedia.org/wiki/Cretan_goat) - a sturdy, agile animal
native to Crete, found almost nowhere else.

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
