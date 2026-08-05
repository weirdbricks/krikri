# Ansible compatibility harness

Verifies crystal-ansible's behavior against **real** `ansible-playbook`,
not just documentation - for each playbook under `playbooks/*.yml`, runs it
once with `ansible-playbook` and once with `bin/crystal-ansible`, each in
its own fresh, throwaway container, then diffs:

- success/failure (exit code 0 vs nonzero)
- the final state of `/work` (file contents + directory structure), and
  for the user/group playbook, the resulting `getent passwd`/`getent
  group` entries

Raw stdout is **not** compared - the two tools format output completely
differently, so that would just be noise. The filesystem/account state is
the actual signal: if both tools end up in the same place, they behaved
the same way regardless of how they logged getting there.

## Running it

```
crystal run compat/run.cr
```

Requires `docker` (or a `docker`-compatible CLI, e.g. podman with the
docker shim). The first run builds `compat/Dockerfile` - an image with
real `ansible-core` + `ansible.posix` (for `authorized_key`, which lives
outside ansible-core) installed via pip/ansible-galaxy, and a from-source
build of crystal-ansible - which takes a few minutes. Subsequent runs
reuse Docker's layer cache unless the source changed.

Containers are genuinely disposable (`--rm`), so playbooks are run for
real, not just `--check` - including real `useradd`/`groupadd` in
`05-user-group.yml`, which would never be safe to run for real on a
developer's actual machine (see `feedback_no_customer_beta`-style caution
in the rest of this repo's testing: the plain `spec/integration/{user,
group}_spec.cr` specs deliberately only exercise `--check` mode or
read-only `getent` lookups for exactly this reason - they run on a real
machine, this harness does not).

## What it found (first run, 2026-08-01)

Four real, previously-shipped bugs, none related to whatever feature was
being worked on when they were introduced - found because this harness
runs actual playbooks through actual `ansible-playbook`, not because
anyone was looking for them:

1. **`authorized_key` was registered under the wrong FQCN.**
   `ansible.builtin.authorized_key` doesn't exist - `ansible-doc` inside
   the container confirmed it lives in the separate `ansible.posix`
   collection. A real playbook author would write
   `ansible.posix.authorized_key`; crystal-ansible only recognized the
   `ansible.builtin.` form, which would silently fail to parse against a
   real-world playbook. Fixed by registering it as
   `ansible.posix.authorized_key` and teaching `PluginManager`'s FQCN
   stripping about the `posix` collection prefix too.

2. **Plugins could only be found by `cd`-ing into the repo first.**
   `PluginManager` resolved plugin binaries via the cwd-relative path
   `./bin/plugins/<name>`, unlike real `ansible-playbook`, which can be
   invoked from anywhere. Fixed by resolving `plugins/` relative to the
   running binary's own location (`Process.executable_path`) instead of
   the working directory, with a cwd-relative fallback for `crystal run`
   in development (where there's no installed binary to resolve a sibling
   from).

3. **`Host.from_json` crashed on a host with no explicit user.**
   `json["user"]?.try(&.as_s)` only guards against a *missing* key -
   a key present with a JSON `null` value still makes `.as_s` raise, since
   the `JSON::Any` itself is non-nil even though it wraps `null`. Every one
   of crystal-ansible's own test fixtures uses an *empty* inventory file,
   which takes a separate "implicit localhost" code path that always
   defaults a non-nil user - so this was never exercised until the compat
   harness used an explicit `localhost ansible_connection=local` line (an
   entirely ordinary, common inventory pattern) with no `ansible_user=`.
   Fixed by using `as_s?`/`as_i?` instead of `.try(&.as_s)`/`.try(&.as_i)`.

4. **`lineinfile` inserted a spurious blank line on every append/removal**
   to a file already ending in a newline. `String#split("\n")` always adds
   one trailing `""` artifact when content ends with `\n`; the guard meant
   to drop that artifact was conditioned on the *negation* of exactly the
   case where it needed to fire, so it never actually popped anything.
   Every unit test of the pure line-matching logic
   (`spec/unit/line_editor_spec.cr`) passed throughout, because that logic
   only ever sees an already-split `Array(String)` - the bug lived
   entirely in the plugin's own split/rejoin glue, one level up, which is
   exactly the kind of thing an integration-level, real-content diff
   catches and a pure-logic unit test structurally cannot.

All four are fixed, with regression tests added at the level that would
actually have caught each one (unit test for `Host.from_json`, integration
tests for the plugin-resolution and cwd-independence bugs, an integration
test with exact content assertions for the `lineinfile` bug).

## Coverage

Thirty-eight playbooks, one per concern: `debug`/`copy`, `file` states,
`lineinfile`, `loop`/`with_items`, real `user`/`group` creation and
modification, `block`/`rescue`/`always`, `until`/`retries`, `cron`
(`cron_file:`), `authorized_key`, `git` clone/checkout against a local
throwaway fixture repo, `roles:` (directory resolution, `meta/main.yml`
dependency ordering, `defaults/main.yml`/`vars/main.yml`/invocation-var
precedence, `files/` `src:` resolution, role handlers), `import_playbook:`
(top-level playbook composition), `import_tasks:` (static, parse-time,
with `vars:`), `include_tasks:` (dynamic, with `vars:`/`loop:`/`when:`),
`include_role:` (dynamic single-role inclusion, looped), a whole playbook
file that is itself vault-encrypted (`16-vault.yml`, real
`ansible-vault`-encrypted with `compat/vault_pass.txt` as the password),
and an inline `!vault`-tagged variable value inside an otherwise-plaintext
playbook (`17-vault-inline.yml`, generated with real `ansible-vault
encrypt_string`). Both vault playbooks are run with
`--vault-password-file` against `compat/vault_pass.txt`. `stat`
(`18-stat.yml`) covers a regular file, a missing path, a directory, and a
symlink stat'd both with and without `follow:` - the stable fields
(`exists`/`isreg`/`isdir`/`islnk`/`mode`/`size`/`checksum`) are written to
a file via `register:` + `{{ }}` templating rather than compared from
stdout, since volatile fields like `atime`/`mtime` would never match
across two separate runs. `find` (`19-find.yml`) covers non-recursive vs
recursive search, `excludes:`, `hidden:`, `file_type: directory`, and
`depth:` - compared via each run's `matched` count, plus (since
`map(attribute=...)`/`sort`/`join` filter-chaining shipped, see
`ROADMAP.md`) the actual sorted `files` path list itself
(`recursive.files | map(attribute='path') | sort | join(',')`), closing
what was previously a real, separate gap unrelated to `find` itself: this
codebase's filter engine only ever split a `{{ }}` pipeline on the first
`|`, so a single chained filter after another silently did nothing.
`archive` (`20-archive.yml`) covers a
single-file compress-only run, a whole-directory tar.gz build, an
idempotent rerun, `exclusion_patterns:`, and a partial run with a missing
path mixed in - compared via `dest_state`/`changed` plus each archive's
own `tar tzf`/`unzip -Z1` listing and `gzip -dc` content (sorted, since
member order isn't a meaningful contract either engine guarantees). The
raw archive files themselves are deleted before the compat snapshot,
since gzip/zip/tar embed timestamps and tool-specific metadata that make
even logically-identical archives byte-different - the listing/content
comparisons above already prove equivalence at the level that matters.
`unarchive` (`21-unarchive.yml`) covers tar.gz extraction, an idempotent
rerun (`tar --compare`-based - the same mechanism real Ansible's own
`TgzArchive#is_unarchived` uses), zip extraction, `exclude:`, and
`creates:` - compared via `changed`/`handler`, with the source archives
deleted before the snapshot for the same non-byte-comparable-binary
reason as `archive`'s own compat playbook. `apt_repository`
(`22-apt-repository.yml`) covers adding a repo with a custom filename,
an idempotent rerun, adding a second repo with a derived filename,
removing a repo, and an idempotent rerun of the removal - this is the
plugin that caught the `grep -v`/`&&` short-circuit bug (see
`ROADMAP.md`), which only ever showed up running a removal *twice*, not
once. `yum_repository` (`23-yum-repository.yml`) covers writing a
`.repo` file, an idempotent rerun, a rewrite with a different parameter
set (confirming keys not passed this time are dropped, not merged), a
custom `file:` target, and removal - compared via `changed` plus each
file's actual content read back with `command:`/`shell:`. `sysctl`
(`24-sysctl.yml`) covers updating an existing key, an idempotent rerun,
appending a new key, and removing a key, all against a throwaway
`sysctl_file:` (not the real `/etc/sysctl.conf`) with `reload: false` so
the container's real running kernel is never touched. `mount`
(`25-mount.yml`) covers the same shape of coverage against a throwaway
`fstab:` file - add, idempotent rerun, update an existing entry's
`opts:`, add with `boot: false`, and `absent_from_fstab` - `mounted`/
`unmounted` (which run real `mount`/`umount`) aren't exercised here,
matching how `spec/integration/mount_spec.cr` only checks those via
`check_mode`. `firewalld` (`26-firewalld.yml`, `offline: true,
permanent: true` throughout - see `ROADMAP.md` for why) covers enabling
a service, an idempotent rerun, a rich rule, masquerade, disabling the
service, and an idempotent disable rerun - compared via `changed` plus
`firewall-offline-cmd --query-<thing>` state checks rather than a raw
zone-file diff, since real Ansible's own module leaves the zone XML in a
very slightly different (but behaviorally identical) shape.

`set_fact` (`27-set-fact.yml`) covers setting facts of a few different
types, overwriting one, and deriving a second fact from the first via a
filter (`| upper`) - a bare unquoted YAML `is_ready: true` is used
deliberately rather than a quoted `"true"` string, since the two render
differently (`True` vs `true`) and only the unquoted form matches real
Ansible's own behavior once coerced through this codebase's params
pipeline (every param is stringified before a plugin ever sees it, so a
quoted string stays a literal string with no type coercion, exactly like
real Ansible). `get_url` (`28-get-url.yml`) and `uri` (`30-uri.yml`) both
start a real local `python3 -m http.server` in the background (no real
network access in this container) and hit it - `get_url`'s idempotent
rerun uses a `checksum:` computed ahead of time via `stat:`, not
crystal-ansible's own get_url result (a real field-naming bug this
playbook caught - see `ROADMAP.md`'s `get_url` entry). `blockinfile`
(`29-blockinfile.yml`) covers insert-at-EOF, an idempotent rerun, an
in-place content update, `insertbefore:` with custom markers, removal,
and file creation. `assert` (`31-assert.yml`) covers a passing
multi-condition, a failing one (default message), a custom `fail_msg:`,
a custom `success_msg:`, and a `{{ }}`-wrapped dotted-access condition.
`wait_for` (`32-wait-for.yml`) covers a port coming up, a closed-port
timeout with the exact message, `state: stopped` against an
already-closed port, and an already-existing path - the background
server-start task here is *not* a plain `sleep N && daemon &` (see the
next paragraph for why). `fetch` (`33-fetch.yml`) covers the default
hostname/path layout, an idempotent rerun, `flat: true` to both a
directory and a literal path, and a missing source with
`fail_on_missing: false`. `pause` (`34-pause.yml`) covers a `seconds:`
sleep, a `minutes:` sleep, and the `seconds:`/`minutes:` mutual-exclusion
failure. `mysql_db`/`postgresql_db` `state: dump`/`import`(`restore`)
(`35-mysql-db.yml`/`36-postgresql-db.yml`) each start their own throwaway
server inside the container via its init.d script (no systemd in this
image) and cover: a seed import/restore, a plain-SQL dump plus
gzip/bzip2/xz-compressed dumps (native `Compress::Gzip`/`Compress::BZ2`/
`Compress::XZ`, no `gzip`/`bzip2`/`xz` subprocess - the latter two added
in `0.9.43`), each dump restored into a second database with the row
count verified after each round trip, and a missing-`target:` failure
(both engines must fail the same way). The raw dump files are deleted
before the `/work` snapshot - `mysqldump`/`pg_dump` both embed a
timestamp comment, so even logically identical dumps are byte-different
across the two engines' separate runs; the row-count round trips already
prove the content matched.
`postgresql_db`'s compat playbook sets the `postgres` superuser's password
via a plain `su postgres -c '...'` shell command rather than
`become:`/`become_user:` - at the time this playbook was written,
crystal-ansible parsed `become:` but didn't actually apply privilege
escalation to command execution (a real, previously-undocumented gap found
while writing this playbook - see `ROADMAP.md`), so using it here would
have silently run as root on one engine and as `postgres` on the other.
Since fixed (see `37-become.yml` below) - this playbook wasn't retrofitted
to use `become:` instead, since the plain `su` command already works fine
and there's no reason to churn a passing playbook.

`become`/`become_user` (`37-become.yml`) is the one playbook here that
deliberately runs as root inside its own throwaway container (the compat
image's default user) rather than working around it like every other
playbook - the whole point is to exercise a *real* privilege drop, which
`spec/integration/cli_spec.cr`'s own become spec can't safely do on an
arbitrary dev machine (it only ever "becomes" the same user already
running it). Creates a throwaway non-root user, then covers: `whoami`
with no `become:`, with an explicit `become_user:`, and with `become:`
defaulting to root; a `copy:` task run under `become:` actually creating
the file with the become user as owner (not just a command running as
that user - proving the *whole plugin process* is escalated, not just a
shell command inside it); and an invalid `become_user:` being rejected
(both engines fail the task, though for different reasons - real
Ansible's own become/privilege-setup machinery rejects it one way,
crystal-ansible's username validation rejects it before ever reaching a
shell another way; the compat comparison only checks the `failed:` result
matches, not the exact error text, the same way `find`'s own compat
playbook compares `matched` counts rather than exact path lists).
`compat/Dockerfile` needed `sudo` added to its package list for this,
which wasn't there before since nothing in this codebase used it.

`postgresql_privs` (`38-postgresql-privs.yml`, `0.9.44`) covers the four
object types this codebase implements (`table`, `sequence` isn't
exercised directly but shares `table`'s own code path, `schema`,
`database`) - a `table` grant, an idempotent re-grant, `grant_option:
true` then `grant_option: false` on a separate table (verifying the
underlying privilege survives losing just its grant option), a partial
revoke leaving one of two granted privileges intact, a `schema` grant,
and a `database` grant. Compared via each task's `changed:` plus the
actual final `relacl::text` read back for both test tables (not just
booleans) - `postgresql_privs.cr`'s own class doc has the full ACL-format
verification notes.

Building `32-wait-for.yml` found a real, previously-unknown bug unrelated
to `wait_for` itself: `LocalExecutor.exec` (backing `shell:`/`command:`
on any local connection) **hangs forever** - confirmed via `timeout`, not
just "slow" - on a command shaped like `sleep N && long-running-daemon &`.
Crystal's `Process.run(..., output:, error:)` blocks until the child
exits *and* its stdout/stderr pipes reach EOF; `sleep N && daemon &`
backgrounds a *shell* that blocks in `wait()` on `daemon` (a trailing `&`
backgrounds the whole `&&`-list, and `nohup` only suppresses `SIGHUP` - it
doesn't exempt a child from its parent's own `wait()`), so if `daemon`
never exits, neither does the shell holding the pipe open, and
`Process.run` never sees EOF. Confirmed this is a real crystal-ansible
gap and not a fixture mistake: the identical command ran fine under real
`ansible-playbook` in the same container. `32-wait-for.yml` works around
it with `nohup sh -c 'sleep N; daemon' &` (one process backgrounded
directly, no separate parent shell left waiting) - full detail and a
suggested fix direction in `ROADMAP.md`.

`ufw` has no compat playbook, unusually for this repo - `ufw` itself
refuses to run at all without root (even a bare `ufw status` fails), and
the container lacks working netfilter access even running as root.
Confirmed this isn't crystal-ansible-specific: real `ansible-playbook`'s
own `community.general.ufw` module fails identically in the same
container, even in `--check` mode. See `ROADMAP.md`'s `ufw` entry for
what verification *was* possible (unit tests on the pure
command-construction logic).

Not covered here (same gaps noted elsewhere in this repo): `apt`/`dnf`/
`package` (would need a slower, distro-specific compat image and real
network access to a package mirror), `service` (needs an init system
running inside the container, which the base image doesn't have), and
`template` (not yet a priority to compat-test specifically). Extending
this harness to those is straightforward - add a playbook, rebuild, rerun
- if/when they become worth the added image complexity and runtime.

## `39-batching.yml` runs differently from every other playbook here

Every playbook above runs both engines via `docker exec <container> ...`
with `ansible_connection=local` (`compat/inventory.ini`) - no real
network involved at all. `--experimental-batching` (`0.9.61`) is an
SSH-specific optimization;
`PluginManager.is_local_connection?` short-circuits before ever
consulting a batch group, so that mechanism can never exercise it,
batching flag or not.

`compat/run.cr`'s `compare_batching` (used only for this one playbook,
via `BATCHING_PLAYBOOK_NAME`) instead spins up *two* fresh containers
from the same image - a "target" (runs its own real `sshd`) and a
"controller" (runs `ansible-playbook`/`crystal-ansible
--experimental-batching` against the target over a real SSH connection)
- on a dedicated `docker network` so they can reach each other by IP.
Both directions use one keypair `compat/Dockerfile` bakes into every
image built from it (`compat/batching_test_key`/`.pub`, committed
on purpose - it grants access to nothing outside an ephemeral container
built from this exact image, never a real host; same accepted pattern as
e.g. Vagrant's well-known default box keypair). Snapshot diffing is
otherwise identical to every other playbook here, just captured from the
target container instead of the one the engine ran inside of.

## Why this isn't wired into GitHub Actions

`.github/workflows/ci.yml` runs `crystal spec` + `ameba` on every push and
needs to stay fast. This harness rebuilds a from-source crystal-ansible
inside a fresh container and spins up ~20 more containers on top of that
- multiple minutes, and it needs `docker`/a container runtime, which the
existing CI image doesn't set up. It's a manually-invoked verification
tool for now, not a merge gate.
