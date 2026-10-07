# krikri - Ansible-Compatible Automation Tool

**A single-binary automation tool that runs Ansible playbooks - written in Crystal**

[![Version](https://img.shields.io/badge/version-0.9.1533-blue)](https://github.com/weirdbricks/krikri)
[![Compatibility](https://img.shields.io/badge/ansible--core-2.19.11-brightgreen)](#-what-is-krikri)
[![Language](https://img.shields.io/badge/language-Crystal-black)](https://crystal-lang.org)
[![Homebrew](https://img.shields.io/badge/homebrew-tap-blue)](#install-via-homebrew-macoslinux-prebuilt-binaries)

---

## 📋 What is krikri?

krikri parses and runs **standard Ansible playbook YAML directly** -
the same syntax you already write, unmodified. There's no Python, no
`ansible-core`, no `pip`, and no collections directory anywhere in the
picture, on either the controller or the target - it's one compiled binary
(`krikri-playbook`) plus a directory of small compiled module binaries.

Three binaries ship: `krikri-playbook` (runs playbooks, the
`ansible-playbook` equivalent), `krikri` (ad-hoc commands, the `ansible`
equivalent) and `krikri-lint` (the `ansible-lint` equivalent).

| By the numbers | |
|---|---|
| Compatibility target | ansible-core 2.19.11 (byte-for-byte console output) |
| Real Galaxy roles tested on real hosts | 6,680 ([status per role](ROLES_TESTED.md)) |
| Open gaps and deliberate scope cuts | [KNOWN_MISSING.md](KNOWN_MISSING.md) |
| Third-party collection modules natively ported | 62 |
| Automated tests | 6,408 passing, 0 failures |
| Cold run vs. `ansible-playbook` | 2.36x faster |
| Warm run vs. `ansible-playbook` | 7.17x faster |
| Fastest of the three benchmarked engines | 57 of 61 roles (93%) |

---

## 🔀 How krikri differs from Ansible

What changes when you swap `ansible-playbook` for `krikri-playbook`:

| Area | Difference |
|---|---|
| Module execution | Each module is a small native binary, uploaded once and cached - no per-task Python interpreter startup or module templating. The biggest source of the speedup (see **Performance**). |
| SSH round trips | Consecutive tasks for the same host are batched into one round trip (`--no-batching` to disable). |
| Third-party collection modules | Not vendored wholesale: a `community.*` module runs only once ported to a native plugin (list: `AVAILABLE_PLUGINS` in `src/krikri/playbook_parser.cr`); anything else fails with `krikri does not yet have module 'x.y.z' implemented`. A role's own `library/*.py` modules work as usual. |
| Cloud provider modules | Out of scope, except AWS/EC2 (`ec2_instance` and its supporting modules, `aws_ec2` inventory). |

---

## ⚡ Performance

Native compiled modules, one persistent SSH connection per host, and
batched round trips make the biggest difference on **idempotent
re-runs** - the common case for a config-management tool running on a
schedule, where most tasks find nothing to change.

A 3-way benchmark against `ansible-playbook` and `ansible-playbook`
with the Mitogen strategy plugin, across a 100-role random sample, found
61 roles where all three engines produced an identical successful
outcome:

| Phase | Ansible | Ansible + Mitogen | krikri-playbook | krikri vs Ansible | krikri vs Mitogen |
|---|---|---|---|---|---|
| Cold (total) | 2176.6s | 1246.2s | 920.6s | **2.36x faster** | **1.35x faster** |
| Cold (median/role) | 22.04s | 11.54s | 5.32s | 3.43x faster | 1.82x faster |
| Warm (total) | 1328.0s | 598.2s | 185.3s | **7.17x faster** | **3.23x faster** |
| Warm (median/role) | 14.49s | 6.97s | 2.00s | 7.99x faster | 4.00x faster |

krikri-playbook was the fastest of the three engines in 57 of 61 roles
(93%, see the table at the top). Full methodology and the broader
78-role set: see
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
toolchain needed. See **Build from source** below instead.

### Build from source

Crystal is only needed to *build* from source (the Homebrew tap above ships
prebuilt binaries). The `ssh` CLI on `PATH` is needed for remote targets -
SSH goes through native `ssh`/`ControlMaster`, not a bundled library.

```bash
# Install dependencies
shards install

# Build (all plugins + the CLI)
./build.sh
```

The binaries are written to `./bin/` - add that directory to your `PATH` (or
prefix the commands below with `./bin/`).

### Example playbook

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
```

Run it against an inventory:

```bash
krikri-playbook -i inventory.ini playbook.yml
```

Playbook syntax is standard Ansible's - see the
[Ansible documentation](https://docs.ansible.com/) for the full reference.

---

## 🎯 Command Reference

```bash
krikri-playbook playbook.yml                          # basic run
krikri-playbook -i inventory.ini playbook.yml         # inventory
krikri-playbook --check playbook.yml                  # dry-run
krikri-playbook --diff playbook.yml                   # show file diffs
krikri-playbook -v playbook.yml                       # verbose
krikri-playbook -l webservers -t deploy playbook.yml  # host limit / tag filter
krikri-playbook --ask-vault-pass playbook.yml         # vault-encrypted playbooks/vars
krikri-playbook --no-batching playbook.yml            # one SSH round trip per task
krikri-playbook --forks 10 playbook.yml               # host concurrency (default: 5)
krikri-playbook --gathering smart playbook.yml        # fact gathering policy
```

`--forks` defaults to 5, like ansible-playbook. A fork here is a cheap
fiber, not a forked Python interpreter, so larger values (e.g. `--forks 25`)
are safe and faster on big inventories; `--forks 1` runs one host at a time. `--gathering` takes
`implicit` (the default, every play re-gathers), `explicit` (only plays
with `gather_facts: true`) or `smart`.

Everything else - `--syntax-check`, `--list-hosts`, `-e`, `--start-at-task`,
vault subcommands and the rest - is documented in
`krikri-playbook --help`.

### Ad-hoc commands (`krikri`)

```bash
krikri all -m ping
krikri webservers -a 'uptime'
krikri all -m command -a 'systemctl status nginx'
krikri all -m copy -a 'src=foo.conf dest=/etc/foo.conf' -b
krikri db -i inventory.ini -m service -a 'name=postgresql state=restarted' -b
```

The `krikri` binary is the ad-hoc counterpart of `krikri-playbook` (Ansible's own `ansible`/`ansible-playbook` split): one module, one run,
against a pattern of inventory hosts. It supports
`-i`, `-m`, `-a`, `-u`, `-b`/`--become`, `--become-user`, `-C`/`--check`,
`-f`/`--forks`, `-l`/`--limit`, `-v`, and its output matches Ansible's
own minimal callback style (`host | SUCCESS => {...}` /
`host | CHANGED | rc=0 >>`), not ansible-playbook's `ok: [host]` TASK-recap.

---

## 🔍 Linting (`krikri-lint`)

`krikri-lint` is a from-scratch reimplementation of `ansible-lint` - same
rules, same output format, same exit codes, verified against ansible-lint itself
rather than against its documentation. It's static analysis only: no host
connection, no execution, no SSH.

```bash
krikri-lint playbook.yml
krikri-lint -p roles/                # parseable output
krikri-lint --fix playbook.yml       # autofix the mechanically-fixable rules
krikri-lint --list-rules
```

See [KNOWN_MISSING.md](KNOWN_MISSING.md) for the rules it deliberately
diverges on.

---

## ✅ Testing

```bash
# Full minitest suite (test/ - unit, integration, lint)
scripts/minitest.sh

# Same suite on 4 parallel worker fibers (faster; tests are parallel-safe)
scripts/minitest.sh -- -p 4

# Ansible compatibility harness - runs the same playbooks through
# ansible-playbook and krikri-playbook side by side and diffs the result
crystal run compat/run.cr
```

See [compat/README.md](compat/README.md) for what the compatibility
harness covers and how it works.

For output parity specifically, `scripts/output_parity.sh OUTDIR
playbook.yml...` runs a playbook under `ansible-playbook` and
`krikri-playbook` and diffs stdout, stderr and the exit code byte for byte
(it needs a `ansible-playbook` installed). The separate
[krikri-playbook-generator](https://github.com/weirdbricks/krikri-playbook-generator)
repo goes wider: it generates valid and deliberately mutated playbooks per
module and compares both engines on them in fresh containers.

---

## 🤝 Contributing

Contributions welcome! Please:

1. Review the existing code structure and [KNOWN_MISSING.md](KNOWN_MISSING.md)
2. Verify any Ansible-compatibility claims against `ansible-playbook`
   output, not just documentation
3. Test your changes thoroughly (`scripts/minitest.sh`, and `compat/run.cr` for
   plugin behavior changes)
4. Submit a pull request with a clear description

---

## 📄 License

GNU General Public License v3.0 or later (GPL-3.0-or-later) - see [LICENSE](LICENSE) and
[NOTICE](NOTICE) for details. krikri-playbook targets compatibility with Ansible, which is
also GPLv3+.

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
admire it enough to have rebuilt its behavior, byte for byte where it
shows, in another language.

Where krikri-playbook is faster, that's simply a different execution model
(compiled binaries vs. a Python interpreter per task) - not a knock on
Ansible, which made the choices it made for good reasons of its own.
`ansible-core` is, and remains, the reference implementation this project
is measured against and tries to be worthy of.

This project was built with the help of AI coding assistants (Claude Code)
and other AI models: MiniMax, DeepSeek Flash, GLM 5.3 Express.

Thanks also to:

- [Crystal](https://crystal-lang.org/), the language this is built with
- [crinja](https://github.com/straight-shoota/crinja), which krikri used
  for Jinja2 templating before its own
  [krikri-jinja](https://github.com/weirdbricks/krikri-jinja) engine, and
  the other Crystal shards in `shard.yml`

**Ansible** and the Ansible logo are trademarks of Red Hat, Inc., registered
in the United States and other countries. This project is not affiliated
with, sponsored by, or endorsed by Red Hat, Inc. or the Ansible project.
