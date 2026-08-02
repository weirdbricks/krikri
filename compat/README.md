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

Eleven playbooks, one per concern: `debug`/`copy`, `file` states,
`lineinfile`, `loop`/`with_items`, real `user`/`group` creation and
modification, `block`/`rescue`/`always`, `until`/`retries`, `cron`
(`cron_file:`), `authorized_key`, `git` clone/checkout against a local
throwaway fixture repo, and `roles:` (directory resolution, `meta/main.yml`
dependency ordering, `defaults/main.yml`/`vars/main.yml`/invocation-var
precedence, `files/` `src:` resolution, role handlers).

Not covered here (same gaps noted elsewhere in this repo): `apt`/`dnf`/
`package` (would need a slower, distro-specific compat image and real
network access to a package mirror), `service` (needs an init system
running inside the container, which the base image doesn't have), and
`template` (not yet a priority to compat-test specifically). Extending
this harness to those is straightforward - add a playbook, rebuild, rerun
- if/when they become worth the added image complexity and runtime.

## Why this isn't wired into GitHub Actions

`.github/workflows/ci.yml` runs `crystal spec` + `ameba` on every push and
needs to stay fast. This harness rebuilds a from-source crystal-ansible
inside a fresh container and spins up ~20 more containers on top of that
- multiple minutes, and it needs `docker`/a container runtime, which the
existing CI image doesn't set up. It's a manually-invoked verification
tool for now, not a merge gate.
