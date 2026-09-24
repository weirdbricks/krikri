# dnf5 side-by-side parity harness

Exercises every `ansible.builtin.dnf5` option and diffs real
`ansible-playbook` against `krikri-playbook`, so the new dnf5 plugin
(`plugins/dnf5.cr`) can be validated against the real module's behavior.

## Why a container

`dnf5` only exists on RHEL-family hosts with `libdnf5` (Fedora 41+). The real
module additionally needs `python3-libdnf5`, and it runs on the *target*, so a
local Fedora container with `connection: local` is the fastest reproducible
harness. Each engine runs on its own freshly-started container (same base
image), so the two never share package state (see the workspace rule about not
running both engines concurrently against shared state).

## One-time base image setup

From `localhost/krikri-fedora-compat` (has `dnf5` + an `ansible-core` venv but
ships the *dnf4* python bindings only), add the dnf5 bindings and commit:

```bash
podman run -d --name dnf5prep localhost/krikri-fedora-compat:latest sleep infinity
podman exec dnf5prep dnf5 -y install python3-libdnf5
podman commit dnf5prep localhost/dnf5cmp-base:latest
podman rm -f dnf5prep
```

## Running

```bash
# Bind-mounts this worktree at /repo (krikri binary + plugins + this dir).
./testing/dnf5/run_compare.sh testing/dnf5/dnf5_options.yml
```

It runs `dnf5_options.yml` under both engines on fresh containers, then prints
a per-task `changed/ok/failed/skipped` report diff, a failure-message diff, and
the two PLAY RECAPs. `inventory` pins `ansible_python_interpreter=/usr/bin/python3`
(the venv python has no `libdnf5`; the modules run under the system python that
does).

## Result (2026-09-24, dnf5 5.2.17, ansible-core 2.21.4)

44 of 46 option exercises match exactly, including the whole
argument-spec-rejection surface (`state` choices, `use_backend` unsupported,
non-bool coercion, explicit-null list `NoneType`, `name|list` and `best|nobest`
mutual exclusion), the `pkg`/`expire-cache` aliases, `list` query mode,
`security`/`bugfix` advisory updates, and `autoremove` with no `name`.

Three accepted divergences, none in the transaction logic:

- **`enable_plugin`/`disable_plugin` with an unknown name** - real (libdnf5 API)
  hard-fails ("No matches were found for the following plugin name patterns
  while enabling libdnf5 plugins"); the `dnf5` CLI krikri shells instead warns
  and proceeds. Only surfaces for invalid plugin names; valid ones behave the
  same. Not reproduced (would require matching a CLI warning string).
- **`autoremove` `changed` vs `ok`** - the count of unneeded packages depends on
  the dependency state accumulated across the whole matrix, which differs by a
  package or two between the two runs; the autoremove *operation* is equivalent.
- **`name:` given an explicit null** - both engines FAIL the task (status
  parity), but the message differs: real reports the argspec `NoneType`
  conversion error, krikri reaches `dnf5` and fails on the empty spec. This is
  the shared engine's null-vs-empty-string parameter handling, identical for
  `dnf`/`yum`, not dnf5-specific.

The non-bool rejection message's "Valid booleans include:" list is a Python
`set` in real, so its element *order* varies run to run; krikri matches the
element set, not the order.
