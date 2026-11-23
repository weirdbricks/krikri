# krikri - Ansible-Compatible Automation Tool

**A single-binary automation tool that runs Ansible playbooks - written in Crystal**

[![Version](https://img.shields.io/badge/version-0.9.3056-blue)](https://github.com/weirdbricks/krikri)
[![Compatibility](https://img.shields.io/badge/ansible--core-2.21.6-brightgreen)](#-what-is-krikri)
[![Language](https://img.shields.io/badge/language-Crystal-black)](https://crystal-lang.org)
[![Homebrew](https://img.shields.io/badge/homebrew-tap-blue)](#install-via-homebrew-macoslinux-prebuilt-binaries)

---

## 📋 What is krikri?

krikri parses and runs **standard Ansible playbook YAML directly** -
the same syntax you already write, unmodified. There's no Python, no
`ansible-core`, no `pip`, and no collections install required, on either
the controller or the target - it's one compiled binary
(`krikri-playbook`) plus a directory of small compiled module binaries.
It never needs, reads or depends on an Ansible installation: module-name
resolution, collection-releases gating and the deprecation text it
counterfeits all come from krikri's own baked tables (captured at build
time from the pinned ansible-core release and a pinned collection set),
so the same playbook behaves identically on a controller with ansible-core
and collections installed and on one that has never seen them. A role's or
playbook's own `library/*.py` Python modules still run, through the
target's `python3`, imports and all; no collection module is ever run in
place of a native plugin.

Three binaries ship: `krikri-playbook` (runs playbooks, the
`ansible-playbook` equivalent), `krikri` (ad-hoc commands, the `ansible`
equivalent) and `krikri-lint` (the `ansible-lint` equivalent).

| By the numbers | |
|---|---|
| Compatibility target | ansible-core 2.21.6 (byte-for-byte console output) |
| Real Galaxy roles tested on real hosts | 12,000+ ([status per role](ROLES_TESTED.md)) |
| Open gaps | [GitHub issues](https://github.com/weirdbricks/krikri/issues) |
| Deliberate scope cuts | [KNOWN_MISSING.md](KNOWN_MISSING.md) |
| Third-party collection modules natively ported | 92 |
| Automated tests | 10,800+ passing |
| Cold run vs. `ansible-playbook` | 2.36x faster |
| Warm run vs. `ansible-playbook` | 7.17x faster |
| Fastest of the three benchmarked engines | 57 of 61 roles (93%) |

---

## 🔀 How krikri differs from Ansible

What changes when you swap `ansible-playbook` for `krikri-playbook`:

| Area | Difference |
|---|---|
| Module execution | Each module is a small native binary, uploaded once and cached - no per-task Python interpreter startup or module templating. The biggest source of the speedup (see **Performance**). |
| Target architecture | Module binaries are compiled for the controller's CPU architecture (real Ansible ships Python modules, so it has no such constraint). A different-arch target (an x86_64 controller managing a Raspberry Pi, say) gets binaries from a `plugins-<arch>/` directory next to the `krikri-playbook` executable when one was built there - run `./build.sh` on a machine of that architecture and copy the resulting `bin/plugins/` directory across as `plugins-<arch>/`. Without one, the run fails immediately with those instructions, before uploading anything the target could not execute. |
| SSH round trips | Consecutive tasks for the same host are batched into one round trip (`--no-batching` to disable). |
| Third-party collection modules | Not vendored wholesale: a `community.*` module runs only once ported to a native plugin (list: `AVAILABLE_PLUGINS` in `src/krikri/module_registry.cr`); anything else fails with `krikri does not yet have module 'x.y.z' implemented`. A role's own `library/*.py` modules work as usual. |
| Cloud provider modules | Out of scope, except AWS/EC2 (`ec2_instance` and its supporting modules, `aws_ec2` inventory). |

---

## 🔌 AWS SSM Session Manager

Set `ansible_connection=aws_ssm` (also accepted: `amazon.aws.aws_ssm`,
`community.aws.aws_ssm`) to run a play over a Systems Manager session instead of
ssh. krikri speaks the SSM data-channel protocol itself: the controller needs
**no AWS CLI and no `session-manager-plugin`**, and **no S3 bucket** - plugins,
files and command output all travel over the session.

```ini
[targets]
web1 ansible_connection=aws_ssm ansible_aws_ssm_instance_id=i-0123456789abcdef0 ansible_aws_ssm_region=us-east-1
```

Requirements:

- the SSM agent running on the target, with an instance profile carrying
  `AmazonSSMManagedInstanceCore` or equivalent;
- controller permissions for `ssm:StartSession`, `ssm:ResumeSession` and
  `ssm:TerminateSession`, plus `kms:GenerateDataKey` when the account's Session
  Manager preferences require KMS encryption;
- egress to `ssm.<region>.amazonaws.com` and the session messages gateway;
- Linux targets only, and AWS credentials from the standard chain (environment,
  shared profiles including `role_arn`/`source_profile`, SSO cache,
  `credential_process`, web identity, ECS, IMDSv2).

Supported options use Ansible's names and precedence: the target comes from
`ansible_aws_ssm_instance_id`, else `ansible_host`, else the host name;
`ansible_aws_ssm_region`, `_profile`, `_document`, `_timeout`, `_retries`,
`_endpoint_url`, `_access_key_id`, `_secret_access_key`, `_session_token`, and
`ansible_shell_type` (Linux shells only). `ansible_aws_ssm_bucket_name`,
`ansible_aws_ssm_plugin` and the S3 addressing options are accepted and ignored
with a one-time warning.

`ansible_user`/`remote_user` are not login identities over SSM: the session runs
as the document's user (`ssm-user` by default), so use `become`/`become_user` to
switch privileges. Deliberate v1 limits (no Windows - not planned, no port
forwarding) are in
[KNOWN_MISSING.md](KNOWN_MISSING.md#aws-ssm-connections-deliberate-v1-limits).
`async:` works over SSM: a detached worker outlives its session (verified on a
real target), so `poll:` and a later `async_status:` behave as they do over SSH.
`synchronize:` works over SSM too: push and pull with real rsync on both ends
(verified on a real target), as long as the target has `bash` and a writable,
exec-capable `/var/tmp` for a small uploaded bridge.

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

That default macOS install carries only macOS plugin binaries; a Mac
controller managing **Linux** hosts fails on the first task with "no
linux-x86_64 plugin binaries available". For that use the opt-in
multi-arch formula, which additionally installs both Linux plugin sets
(~79 MB vs ~27 MB):

```bash
brew install weirdbricks/krikri/krikri-multiarch
```

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

### Callback plugins

Two callback shapes are emulated, byte-matched against ansible-core
2.21.6; anything else is a hard startup error rather than a silent
divergence:

- `ANSIBLE_CALLBACKS_ENABLED=ansible.posix.profile_tasks` (or the legacy
  short form `profile_tasks`, comma-separated list like Ansible's) prints
  a wall-clock timestamp line under every TASK/RUNNING HANDLER banner and
  a TASKS RECAP block after PLAY RECAP ranking tasks by duration.
  `--krikri-profile-tasks` is the same switch as a flag.
- `ANSIBLE_STDOUT_CALLBACK=oneline` (or `ansible.builtin.oneline`) replaces
  the whole default output surface with one line per host result
  (`localhost | CHANGED | rc=0 | (stdout) hi` for command-family results,
  `localhost | SUCCESS => {compact json}` for the rest), no banners and no
  PLAY RECAP - plus the deprecated callback's own `[DEPRECATION WARNING]`
  (2.21.6 shape: `Origin: <Config env: ANSIBLE_STDOUT_CALLBACK>` and the
  configured spelling repeated under it). `default` is accepted as a
  no-op; every other stdout callback value (`minimal`, `dense`, ...)
  errors.

The `-o` / `--one-line` / `--krikri-oneline` flag turns the oneline
display on without the env var. **This is a krikri extension, not
parity**: real `ansible-playbook` rejects `-o` (it is adhoc-only there,
verified against 2.21.6), so accepting it cannot break an upstream
playbook command line. All krikri-only convenience switches use the
`--krikri-` prefix and are grouped under "Krikri-specific options:" in
`--help`.

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

`testing/lint/parity.py` is the parity harness: it runs both linters with
parseable output over the same targets, diffs their (file, line, column, rule)
triples, prints a `PARITY| matched=... krikri_only=... upstream_only=...
unimplemented=...` line and, with `--json PATH`, the triples as records.
`krikri-role-tester`'s loop runs it every cycle (step 0c) and files one issue
per rule that goes one way, so a parity gap is worked like any other
divergence instead of waiting for someone to read the weekly report.

---

## ✅ Testing

```bash
# Full minitest suite (test/ - unit, integration, lint; time-sharded onto
# 6 worker processes by measured test weight)
scripts/minitest.sh

# Same suite on 4 worker fibers per shard (default is 8)
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
