# External module plugins (issue #1755)

A `module` (target-side) plugin can be built and shipped **outside the krikri
tree**, in any language that produces an executable, and used by
`krikri-playbook` through a plugin directory. No fork, and no krikri rebuild
for each plugin or each krikri release.

This works because krikri's module boundary is already a process boundary: the
plugin reads its whole task config as JSON on stdin and writes its result as
JSON on stdout. Everything else on the dispatch path (upload, md5 de-duplication,
the per-host staging cache, task batching, remote staging by name) is
name-keyed and language-neutral, so a Rust, Go, Nim or Zig binary, or a script
with a shebang, behaves exactly like one of krikri's own compiled binaries.

## Layout

```
<plugin-root>/
  mycompany.internal.foo                    # controller platform (local connections)
  plugins-linux-x86_64/mycompany.internal.foo
  plugins-linux-aarch64/mycompany.internal.foo
```

`plugins-<key>/` uses the same key as krikri's own per-arch plugin
directories: the bare architecture (`x86_64`, `aarch64`, ...) when the target
runs the controller's own OS, and `<os>-<arch>` (`linux-aarch64`,
`darwin-x86_64`, ...) when it does not.

## Discovery

- `--plugin-path DIR`, repeatable.
- `KRIKRI_PLUGIN_PATH`, a `:`-separated list.

Both are combined (not one overriding the other). The current directory is
never searched. These names are krikri-only: nothing in the Python ecosystem
reads them, and `library/`, `ANSIBLE_LIBRARY`, `[defaults] library` and the
`ANSIBLE_*_PLUGINS` variables keep meaning exactly what they mean to Ansible.
`-M`/`--module-path` stays accepted-and-inert for command-line compatibility
and is deliberately not reused.

## Resolution

| Where the task runs | File used |
|---|---|
| A local connection, including `delegate_to: localhost` | `<root>/<name>` only (no arch probing) |
| A remote target whose platform key is the controller's own, or whose arch is not known yet | `<root>/<name>` |
| A remote target whose platform key differs | `<root>/plugins-<key>/<name>` **only** |

A different-platform target never falls back to the flat file: the
controller's own binary could only fail there with an exec-format error, so a
miss fails the task early with `PluginArchUnsupportedError` naming the
directories that were searched.

Lookup is by **exact filename**. krikri's own fat-plugin "any executable in
the directory" fallback deliberately does not apply to external directories:
it exists because one krikri binary serves every module name, while here it
would silently run a different plugin than the task named. The file must be a
regular, executable file; a non-executable match is not a match.

One scope is honoured on top of the exact name: a task's `collections:`
keyword (its own, else the play's, plus the role's `meta/main.yml` list) is
searched for the qualified `<collection>.<task name>` before resolution gives
up, which is the same lookup real ansible performs - `hello:` on a play with
`collections: [acme.tools]` therefore reaches an external `acme.tools.hello`.
A bare `hello:` with no matching collection scope still does not resolve
(supply the FQCN, or name the plugin `hello`), and the scope never overrides
an exact-name or built-in match.

## Naming rules

- `[A-Za-z0-9][A-Za-z0-9_.-]*` - no slashes, no leading dot, no spaces or glob
  characters (the name is a path component locally, in the remote staging
  directory, and in the shell/batch target string).
- A name may not be in a namespace krikri reserves for its own plugins
  (`ansible.builtin.*`, `ansible.legacy.*`, `ansible.posix.*`,
  `ansible.mysql.*`, `community.general.*`, `community.docker.*`,
  `community.mysql.*`, `community.postgresql.*`, `community.crypto.*`,
  `community.rabbitmq.*`, `ovirt.ovirt.*`, `amazon.aws.*`,
  `containers.podman.*`): krikri strips those prefixes from module names, so
  such a plugin would be renamed on dispatch and could collide.
- A name may not shadow a module krikri implements natively, nor one of the
  module aliases krikri resolves (`raw`, `systemd_service`, `openssl_certificate`,
  ...) - the task would run that module and your plugin would never execute.
- The `plugins-` prefix is reserved for the per-platform directories, so a flat
  plugin may not be named `plugins-<something>`.
- The same name provided by two roots (or twice for one platform key) is an
  error.

Duplicates, invalid names and unsafe roots are reported before the playbook is
parsed.

## Security

A plugin root is trusted operator input, but it is still checked:

- the directory must exist, be a directory, not be a symlink, not be
  group- or world-writable, be listable, and be owned by the invoking user or
  by root;
- plugin files must be regular files (symlinks are refused), and so must the
  `plugins-<key>/` directories - a symlinked platform directory would silently
  hide every build under it;
- nothing else in a root is registered, so unrelated directory content
  (`README`, `.md5` sidecars, hidden files) is ignored.

`KRIKRI_PLUGIN_PATH` (and the `--plugin-path` values resolved into it) is
inherited by krikri's own child processes, which is how the local
`__async_run` re-invocation finds the same plugins. A task's `environment:`
never influences plugin resolution.

## Concurrency features

- **Async**: works through both `KRIKRI_PLUGIN_PATH` and `--plugin-path`.
- **Persistent daemon**: an external plugin is daemon-ineligible (the daemon's
  dispatch table is compiled into krikri's fat binary), so it always takes the
  one-shot transport; a batch group containing one is sent over the script
  transport instead of the daemon. Results are identical.
- **Batching / SSH upload / md5 de-duplication**: unchanged - external plugins
  are uploaded to the target's staging directory like any other module binary.

## Build advice

krikri uploads the same executable to every managed host, so prefer a **static
build** (musl/static for Linux; static Go/Crystal/Rust builds). A dynamically
linked binary needs a matching libc/runtime on every target; a shebang script
needs its interpreter there instead.

## protocol: 1 - the config JSON an external module receives

A plugin is one executable. It is run once per task with the task's config on
**stdin** and must write one JSON object to **stdout**. This subset is frozen
as `protocol: 1` and is independent of any implementation language (and of the
Crystal types krikri itself happens to use). Unknown keys must be ignored;
they may be added in later protocol versions.

### stdin (one JSON object)

```json
{
  "host": {"name": "web1", "user": "root", "port": 22},
  "params": {
    "name": "world",
    "_ansible_check_mode": "false",
    "_ansible_diff": "false",
    "_module_name": "mycompany.internal.foo",
    "_verbosity": "0"
  },
  "vars": {
    "ansible_connection": "local",
    "ansible_host": "web1",
    "ansible_ssh_private_key_file": "/home/me/.ssh/id_ed25519",
    "ansible_python_interpreter": "/usr/bin/python3",
    "inventory_hostname": "web1"
  },
  "collection_version": null,
  "become": "false",
  "become_user": null,
  "become_flags": null
}
```

- `host` - the task's effective connection target. Under a local connection
  (`ansible_connection=local`) the module's own filesystem operations are the
  target's, exactly as for a krikri-built module.
- `params` - the task's own arguments, plus krikri-injected keys (all strings,
  `"true"`/`"false"`):
  - `_ansible_check_mode`, `_ansible_diff` - effective modes for this task.
  - `_module_name` - the name exactly as the playbook invoked it.
  - `_verbosity` - the run's `-v` level.
  - `_environment` - JSON-encoded `environment:` for this task, when set.
  - Keys starting with `_ansible_` / `_first_gather` are krikri/Ansible
    internal; ignore whatever you do not understand.
- `vars` - a fixed, pruned set of connection/lookup keys: `ansible_connection`,
  `ansible_host`, `ansible_ssh_private_key_file`, `ansible_private_key_file`,
  `ansible_ssh_common_args`, `ansible_ssh_extra_args`,
  `ansible_ssh_executable`, `playbook_dir`, `ansible_pkg_mgr`,
  `ansible_python_interpreter`, `discovered_interpreter_python`,
  `inventory_hostname`. It is not the full variable context (sending that over
  the wire would cost tens to hundreds of KB per task).
- `collection_version` - always `null` for an external plugin (it names a pin
  for a captured collection release, which an external name never has).
- `become`, `become_user`, `become_flags` - informational: krikri has already
  wrapped the whole process in the necessary privilege escalation, so a plugin
  does not have to act on them.

### stdout (one JSON object)

Return the conventional Ansible module result:

```json
{"changed": true, "msg": "hello from world", "anything": "else"}
```

- `changed` (bool) - whether the task changed anything. Backfilled to `false`
  when omitted on success, as Ansible's task executor does.
- `failed` (bool) - `true` fails the task. Backfilled from a nonzero `rc` when
  omitted. A failure should carry `msg`.
- `msg`, `rc`, `stdout`, `stderr`, `stdout_lines`, `stderr_lines`, `diff`,
  `warnings`, `deprecations`, `ansible_facts` and any other keys you add are
  carried into the task's registered result unchanged.
- Exit non-zero only for a crash or "could not run at all" (stdout is then
  not trusted); a task-level failure is `failed: true` with exit 0.

A non-executable plugin, a name that does not resolve, a missing per-platform
build, or stdout that is not one JSON object all fail the task with a message
naming what was wrong - never a silently skipped task.

A registered name also shadows a removed-module tombstone (`consul_acl`, ...),
the same way a role's own `library/<name>` source does: supplying your own
implementation of a module ansible-core removed is a normal reason to build an
external plugin.

## Out of scope (v1)

Action, filter, test and lookup plugins, callbacks, Python plugins and
installed collections, custom inventory/connection/strategy/vars/become
plugins, plugin manifests or aliases, per-platform key directories for local
or same-platform connections, and in-process shared-library loading or any
dynamic-linking ABI.
