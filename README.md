# Crystal Ansible - Ansible-Compatible Automation Tool

**A single-binary automation tool that runs real Ansible playbooks - written in Crystal**

[![Version](https://img.shields.io/badge/version-0.9.266-blue)](https://github.com/weirdbricks/crystal-ansible)
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
- **64 built-in plugins** covering package/service/file management, users
  and groups, Docker, MySQL/MariaDB, PostgreSQL, firewalls, archives,
  SELinux/PAM, and more (see below)
- **Single binary deployment** - no dependencies, no Python required on
  either the controller or the target
- **Verified compatibility, not assumed compatibility** - every plugin's
  behavior is checked against real `ansible-playbook` output, and a
  Docker-based compatibility harness (`compat/`) runs the same playbooks
  through both engines side by side and diffs the resulting state

See [KNOWN_MISSING.md](KNOWN_MISSING.md) for what's still missing, and
`git log` for implementation history.

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
  per task, on by default (`--no-batching` to disable; see the
  Performance section below and `git log`'s `0.9.61`-`0.9.63` commits)

### Plugins (64 total)

**Files & templates:** `copy`, `template`, `file`, `lineinfile`,
`blockinfile`, `replace`, `stat`, `find`, `archive`, `unarchive`, `fetch`,
`get_url`

**Execution:** `command`, `shell`, `async_status`, `debug`, `assert`,
`fail`, `set_fact`, `pause`, `wait_for`, `uri`

**Packages:** `apt`, `apt_key`, `apt_repository`, `deb822_repository`,
`dnf`, `yum_repository`, `package`, `package_facts`, `pip`, `gem`

**Users, groups & access:** `user`, `group`, `authorized_key`, `cron`,
`getent`, `openssh_keypair`, `htpasswd`

**Services & system:** `service`, `systemd`, `service_facts`, `sysctl`,
`mount`, `modprobe`, `firewalld`, `ufw`, `facts`, `setup`

**Security:** `selinux`, `pamd`, `pam_limits`, `openssl_dhparam`

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
├── plugins/                     # One binary per Ansible module (64 total)
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

Measured against real `ansible-playbook`, not assumed - see `git log`
for the full methodology and results behind each number.

### vs. real Ansible, end to end

3 fresh Atlantic.net instances per row (Ubuntu 22.04, all destroyed
immediately after each run), the same 12-task mixed playbook (`file`,
`copy`+loop x10, `lineinfile`+loop x10, `shell`+`register`,
`command`+`register`, `changed_when`/`failed_when`, `stat`, `assert`,
`find`, `set_fact`, `debug`) run against both tools:

| | Fresh run | Idempotent re-run (median of 3) |
|---|---|---|
| Python `ansible-core` 2.19.4 (`forks=5` default) | 39.6s | 32.5s |
| `crystal-ansible` `--forks 1` (one-host-at-a-time) | 25.8s (1.54x) | 8.6s (3.8x) |
| `crystal-ansible` `--forks 3` | 14.4s (2.76x) | **3.5s (9.3x)** |

> Re-measured `0.9.171` (2026-08-10), replacing the `0.9.77`/`0.9.78`
> numbers this table carried for a long time - see `git log` for the
> engine-level performance work done in between. Same methodology (3
> fresh Atlantic.net `G3.1GB` instances per row, interleaved-by-row on
> this dev box against the same 3-node inventory), but the fresh-run
> gap between `--forks 1` and `--forks 3` is now much larger than the
> earlier snapshot showed (1.54x/2.76x here vs. 1.26x/1.22x before) -
> plausibly explained by this benchmark environment's own
> network latency/jitter mattering more now that only 3 target hosts are
> in play, letting higher forks overlap their SSH round trips more
> visibly. Treat the ratios as directionally solid, not as tightly
> reproducible absolute numbers.

The idempotent case is where native compiled modules plus batched,
forked SSH round trips show through cleanly: Python ships and starts a
fresh interpreter per task per host even when nothing needs to change,
while `crystal-ansible` finishes in single-digit seconds. Idempotent
reruns are also the more common real-world case for a config-management
tool.

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

See [KNOWN_MISSING.md](KNOWN_MISSING.md) for the live tracking of what is
not yet implemented.

**No known cross-cutting engine gap is currently open.** These get found
and closed on an ongoing basis via real-host benchmark rounds against
production Ansible roles (dev-sec, konstruktoid, linux-system-roles,
geerlingguy, openstack.ansible-hardening, wireguard, ansible-vault,
cloudalchemy.prometheus, cloudalchemy.grafana, haproxy, certbot) - see
`git log` for the full log of what's been found and fixed. Most
recently, a `geerlingguy.java`/`geerlingguy.containerd`/`geerlingguy.
helm`/`geerlingguy.gogs` round found `java` and `containerd` both
clean on the first try, and one high-value bug in `helm`: the
hand-rolled `when:` evaluator checked a leading `not ` prefix BEFORE
splitting on any top-level `and`/`or` at all, so `not X or Y` negated
the entire remaining string as one unit instead of binding `not` only
to the immediate next term - the opposite of real Python/Jinja2
precedence (`not` binds tightest, `or` loosest), discarding `or`'s
short-circuiting and silently skipping tasks gated on patterns like
`when: not some.stat.exists or ...`. `gogs` isn't testable - its role
uses the legacy `include:` directive, removed from current
ansible-core, the same failure already documented for `geerlingguy.
phpmyadmin`. Before that, a `geerlingguy.composer`/`geerlingguy.solr`/
`geerlingguy.passenger`/`geerlingguy.drupal` round found two bugs in
`composer`
(`get_url:`'s checksum algorithm silently using SHA1 for anything but
md5/sha256, and `command:`/`shell:`/`unarchive:`'s `creates=`/
`removes=`/`chdir=` never expanding a leading `~`) and, chained across
a single role include file, six bugs in `solr`: a `creates=` extraction
regex that dropped values with exactly one `{{ }}` template block and
no other `}}` elsewhere in the string; local-connection `become_user:`
plugin execution breaking under a non-root-traversable install
directory (staged binaries fix it, mirroring the SSH upload path);
Crinja missing Python's `.split(...)` string method entirely (and its
own blanket exception handler silently discarding a whole template's
render on that one failure); Crinja's `trim_blocks` eating a literal
space instead of only a real newline; and `file:` not applying owner/
group/mode to newly-created *intermediate* directory components, only
the leaf. `passenger` and `drupal` both hit confirmed external
blockers (a stale apt-key ID; a role task that explicitly opts out of
root, which this benchmark harness's root-only connection violates for
both engines equally) - not engine bugs. Before that, a `geerlingguy.
tomcat6`/`geerlingguy.exim`/`geerlingguy.git`/
`geerlingguy.swap` round found `mount:` never recognized `name:`, real
Ansible's own original alias for `path:` - and fixing that surfaced a
much deeper gap chasing it down: `*`/`/`/`//` arithmetic were entirely
unimplemented anywhere in the plain `{{ }}` evaluator (even a bare
`{{ 10 / 2 }}` rendered "undefined"), which in turn meant `geerlingguy.
swap`'s own file-size comparison always differed, silently deleting and
recreating the swap file every single run instead of converging.
Implementing arithmetic (verified digit-for-digit against real Python's
own jinja2.Environment) surfaced two more compounding bugs: the `int`
filter always converted its input to a string first, so ANY float
(not just one from division) silently became 0; and a bare numeric
literal used alone or as a filter chain's own head was never
recognized at all. `git`/`exim` both passed clean (including git's
full download-and-build-from-source path); `tomcat6` isn't testable -
its package doesn't exist on Ubuntu 22.04 and both engines reject its
own deprecated `state: installed` identically. Before that, a
`geerlingguy.filebeat`/`geerlingguy.fluentd`/`geerlingguy.mailhog`/
`geerlingguy.ruby` round found `ansible.builtin.gem` had no plugin at
all (implemented from scratch, shelling out to the real `gem` CLI like
real Ansible's own module does) and, separately, that `apt:`
unconditionally reported `changed: true` whenever `apt-get install`
exited 0 without checking whether it actually did anything - a purely
*virtual* package name already satisfied via another installed
package's own `Provides:` (`rubygems`, satisfied by `ruby`) has no real
`dpkg -l` entry for the pre-check to find, so it always looked like it
needed installing. Fixed by parsing apt-get's own end-of-run summary
line post-execution instead of trusting the exit code alone.
`filebeat`/`mailhog` both passed clean; `fluentd`'s own apt repo has no
valid Release file for Ubuntu jammy, reproducing identically on real
ansible-playbook. Before that, a
`geerlingguy.puppet`/`geerlingguy.munin-node`/`geerlingguy.
phpmyadmin`/`geerlingguy.adminer` round found no engine bugs at all -
`munin-node` and `adminer` (incl. its apache dependency) both passed
byte-identical and idempotent on the first try; `puppet` and
`phpmyadmin` both hit confirmed external/upstream blockers (an expired
Puppet Labs apt key; a role version using the `include:` directive
current ansible-core has removed entirely), not crystal-ansible gaps.
Before that, a regression-verification pass (re-running `dev-sec.
os-hardening`, `geerlingguy.kibana`, and `geerlingguy.supervisor` to
stress-test a prior round's truthiness/bool fixes) found four MORE
real, pre-existing bugs on `os-hardening` alone - none of them
regressions: `with_flattened:` (the short lookup-plugin-name alias real
roles actually write, not the FQCN form) was entirely unrecognized as a
loop keyword at all; the same resolver silently dropped every literal
string loop source and never evaluated a filter-chain source, both
masked by a misleading dead duplicate elsewhere in the codebase; and a
real Jinja2 `in` test against a variable-bound list (not just an inline
literal) failed to parse inside `{% if %}` outright. `os-hardening` now
passes clean and fully idempotent; `kibana`/`supervisor` re-verified
clean end to end too. Before that, a `geerlingguy.clamav`/`geerlingguy.
kibana`/`geerlingguy.
logstash`/`geerlingguy.gitlab` round found six bugs, the deepest being a
handler's own `register:`/`changed_when:`/`failed_when:` entirely
unapplied (`execute_handler_plugin_once` just returned the raw plugin
result) - `gitlab`'s own "restart gitlab" handler depends on
`failed_when:` to suppress a real, expected upstream GitLab-version
incompatibility (confirmed identically failing run directly on both
hosts, a role issue not a crystal-ansible one); chasing why `| bool`
didn't suppress it surfaced a second bug, the plain evaluator's `bool`
filter reusing general truthiness instead of real Ansible's own
keyword-only semantics. `kibana` found Crinja's own truthiness treated
an empty String/Array/Hash as truthy (Python doesn't), silently breaking
`and`/`or` wherever both operands could be empty. `logstash` found the
`to_json` filter entirely unimplemented, and `command:`/`shell:`'s
`chdir=`/etc. extraction breaking on a templated value with internal
spaces (`chdir={{ x }}`, the near-universal style). `clamav` found
`.find(substring)` missing from the String method-call resolver. Before
that, a `geerlingguy.munin`/`geerlingguy.samba`/`geerlingguy.
supervisor`/`geerlingguy.htpasswd` round passed `samba` clean on the
first try and found `community.general.htpasswd` had no plugin at all
(implemented from scratch - `openssl passwd -stdin` for hashing,
apr_md5_crypt/md5_crypt/sha256_crypt/sha512_crypt/plaintext schemes,
idempotent via re-hashing with the existing entry's own salt), fixing
both `munin` (its own admin-user setup) and `htpasswd` (the whole point
of the role) in one fix; and two bugs in `supervisor`'s own
supervisord.conf.j2 template: the `hash` filter
(`ansible.plugins.filter.core.hash`) was entirely unimplemented in both
Jinja2 evaluators, and a bare boolean interpolated into a `.j2`
template rendered Crystal's lowercase "false" instead of real
Jinja2/Python's capitalized "False". Before that, `geerlingguy.postgresql` found the recursive-re-templating
bug class's newest sub-case: a role default that's a list of dicts,
whose own field values are themselves unrendered Jinja - every prior
fix for this bug class only re-rendered a top-level String value, not
one nested inside an Array/Hash. `geerlingguy.nginx`/`geerlingguy.docker`
were re-run as regression checks and still pass. Before that,
`ansible.builtin.pip` was implemented from scratch
(`geerlingguy.pip` - no plugin existed at all, so every real playbook's
`pip:` task silently skipped); `geerlingguy.haproxy`/`geerlingguy.
certbot` were re-run as regression checks and still pass exactly as
they did in round 4. Before that, `geerlingguy.ntp` found `service_facts:` missing from task
batching's fact-producing guard (a `when:` reading its output right
after gathering it always silently skipped); `geerlingguy.node_exporter`
found THREE bugs from one "download latest GitHub release and extract
it" task - `is match(...)`/`is search(...)` regex tests, `regex_replace`
missing from the plain `{{ }}` evaluator entirely, and `unarchive:`'s
`src:` as a URL (with `remote_src: true`) never implemented despite
being real Ansible's own documented behavior; and `geerlingguy.firewall`
found `command:`/`shell:` never extracting trailing
`creates=`/`chdir=`/etc. key=value params the way every other module's
inline syntax does. Before that, `geerlingguy.nfs` found two
filter-engine bugs: `map()` only
implemented the `map(attribute='x')` form, so real Jinja2's filter-name
positional form (`map('split')`) silently no-op'd; and `split` with no
delimiter argument split into individual characters instead of on
whitespace runs, matching Python's `str.split()`. (`geerlingguy.
php-mysql` was also attempted but its own repo is missing
`vars/Debian.yml` entirely - real ansible-playbook fails identically,
not a crystal-ansible gap.) Before that, a `geerlingguy.memcached`/
`geerlingguy.rabbitmq` round passed
`memcached` clean on the first try (byte-identical config) and found
two bugs in `rabbitmq`: `deb822_repository`'s `signed_by:` only handled
a local path (added the round before), not a bare URL - rabbitmq's own
task gives one directly, now fetched and dearmored into a local
keyring, matching real Ansible's own naming convention; and `apt:`'s
`name=version` pinning syntax was passed straight to `dpkg -l`, which
doesn't understand it, so a pinned package reported changed on every
single run even once already installed at that exact version. (A third
role, `varnish`, was blocked by an external packagecloud.io repo issue
affecting real ansible-playbook identically - not chased.) Before that,
a `geerlingguy.jenkins`/`geerlingguy.elasticsearch` round
found four real bugs in `jenkins` - a handler written as
`include_tasks: file.yml` crashed the whole process for any remote
host; a handler using `template:` never ran the controller-side render
step at all (a separate dispatch path from regular tasks, missing the
same `ActionPluginManager` check); `lineinfile`'s "line already
present" idempotency check was gated behind `!regexp`, so any
`regexp:` that failed to match appended a fresh duplicate line every
run; and `get_url`'s `force: true` unconditionally reported changed
after every download instead of comparing content first - and one in
`elasticsearch`: plain-string character indexing (`"7.x"[0]`) was
entirely unsupported, so the role's own version-branch `when:` silently
picked the wrong (pre-7.x) config layout and failed to start the
service. Before that, a `geerlingguy.apache`/`geerlingguy.nodejs` round passed
`apache` clean on the first try (byte-identical vhost config) and found
that `nodejs` needed `ansible.builtin.deb822_repository` - already
flagged as a known gap from `geerlingguy.docker` hitting it too, now
implemented for the shape real playbooks actually write. Before that, a
`geerlingguy.redis`/`geerlingguy.postfix` round passed `postfix` clean
on the first try (byte-identical `main.cf`) and found three bugs in
`redis`: `apt:` install/upgrade never passed real
Ansible's own default `--force-confdef`/`--force-confold` dpkg options,
hanging forever on an interactive conffile prompt; the legacy free-form
`key={{ x }} state=y` inline module-args tokenizer split on whitespace
with no awareness of `{{ }}` as an opaque span, corrupting a templated
value's own internal spaces; and `mode:` piped through a variable that's
itself an unquoted-octal YAML literal lost its octal-ness in a way a
*direct* `mode:` literal already didn't. Before that, a proactive
*audit pass* (not a real-host round - grepping every remaining
`VariableLookup#resolve` call site in the engine after two rounds found
5 independent copies of the "recursive re-templating" bug) found and
fixed **8 more copies**, plus a 10th while writing a test for one of
them, plus - unrelated - a single-element `loop:`/`with_items:` list
whose one templated element resolves to a scalar silently producing no
loop items at all, and `cron:` required `cron_file:` (a documented but
overly-broad scope cut - real Ansible's own default, editing a live
user crontab, is what `certbot`'s own renewal-cron task needs). See
KNOWN_MISSING.md for the full list of all of these (`0.9.225`-`0.9.266`),
the `ansible-vault` and `prometheus`/`grafana` rounds before that
(`0.9.198`-`0.9.224`), and the `geerlingguy.*`/`range(...)` rounds
before that.

The remaining open items are narrow, documented scope cuts:

- **`meta:`** supports only `clear_facts`.
  `end_play`/`flush_handlers`/`refresh_inventory` and friends act on
  execution-flow machinery this engine models differently, and are
  rejected at parse time rather than silently ignored.
- **`docker_*` `api_version:`** is deliberately not planned - the
  underlying `docr` client uses unversioned endpoint URLs throughout, so
  pinning a version means touching every endpoint in a separate shard.
  The unversioned URLs negotiate fine against current Docker and Podman.
- **Cloud plugins** (`ec2`, `s3_bucket`, `azure_rm_*`) and inventory
  *plugins* (`aws_ec2.yml` et al.) remain explicitly lowest-ROI and are
  not planned.
- **Role-private custom modules** (a role's own `library/*.py`, outside
  the `ansible.builtin`/`community.*`/etc. plugin set this engine ships)
  aren't executed - there's no generic arbitrary-Python-module runner.
  A task using one is skipped with a "Plugin not available" warning
  rather than crashing the run; anything downstream that depends on its
  result sees that value as undefined, which can cascade into broader
  task-status divergence from real Ansible for roles that lean on this
  (seen repeatedly benchmarking linux-system-roles - `sr_fingerprint`,
  `timesync_provider`, `kernel_settings_get_config`, `blivet`).
- **`crystal-mysql`'s wire-protocol driver has no `unix_socket`/
  `auth_socket` auth support** - reconfirmed again benchmarking
  `geerlingguy.mysql`; see KNOWN_MISSING.md.

`postgresql_privs`, which this roadmap tracked scope cuts against for a
long time, is complete as of `0.9.84` - every `type:` real Ansible's
module supports is implemented, including `function`/`procedure` and
`default_privs`.

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
