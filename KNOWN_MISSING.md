# Known Missing / Known Limits

The goal is 100% behavioral compatibility with `ansible-playbook`, verified against Ansible runs
rather than assumed, for **core (`ansible.builtin`) modules**. A community module explicitly promoted
to supported owes the same bar; a divergence rooted in an **unsupported** one isn't tracked (see
`krikri-role-tester`'s `COMMUNITY_MODULE_MISSING` classification and `SUPPORTED_COMMUNITY_MODULES`).

**Open gaps (defects with an unknown or unfinished fix) live in
[GitHub issues](https://github.com/weirdbricks/krikri/issues)**, not in this file. Fixes close them
with `Fixes #N` in the commit; round narrative lives in `git log` (e.g.
`git log --all --grep=auth_socket`) and per-role status in `ROLES_TESTED.md`.

This file holds **Deliberate limits** (below): decisions already made, with the reasoning attached;
nothing here is waiting on anyone. An item that turns out to be a defect becomes an issue and is
deleted from here.

## Test-suite environment notes

- The Docker plugin tests (`docker_compose_v2`, the `--check` mode Docker end-to-end test) talk to the
  user's podman API socket. If `podman.socket` is "listening" but `/run/user/$UID/podman/podman.sock`
  is missing (seen after a tmpfiles sweep), run `systemctl --user restart podman.socket`.
- One `statvfs` test can flake under parallel workers (passes alone).
- The live PostgreSQL/MySQL tests need throwaway servers; `scripts/db_tests.sh` starts
  postgres:17 on 127.0.0.1:15432 and mysql:8.4 on 127.0.0.1:33306, runs the three live
  suites and tears them down (they skip silently without a server, so use the script
  rather than a bare `scripts/minitest.sh` when touching the DB drivers).
- `docker_image_build`'s nonexistent-`path` test skips where `docker` is podman's shim.
- **A machine that runs out of disk space diverges by runtime footprint, not by behavior.** When a
  role fills the disk mid-run, each engine fails at whatever its own runtime writes next - ansible's
  python-apt cache save (`apt.Cache()`) and module payload transfer, krikri's plugin upload - with
  that runtime's own error text, and krikri does not imitate ansible's transport or cache internals.
  The outputs can never be byte-identical there, so a full-disk divergence is environment, not a gap:
  krikri #1369 (closed as an ansible artefact: "with disk space, output/exit code match byte for
  byte") and krikri #1355 (same root cause: `webarchitect609.k8slens` drove the microvm guest's 2.5G
  root fs to exactly zero free bytes mid-install). `krikri-role-tester`'s microvm backend now grows
  every guest disk to 10G so rounds stop landing on that knife edge; only chase a divergence that
  reproduces with disk room.

## Deliberate limits (decided, not defects)

Do not re-litigate without new evidence - and if new evidence turns up, open an issue rather than
arguing with the note in place.

### AWS SSM connections: deliberate v1 limits

`ansible_connection=aws_ssm` (and the `amazon.aws.`/`community.aws.` spellings) is a native
transport: no AWS CLI, no `session-manager-plugin`, no S3 bucket. The entries below are decided for
v1, and they are not all the same kind of thing: no S3, no port forwarding and no SSH-over-SSM are
**non-goals** (the issue exists to avoid them); no Windows and no `synchronize:` are
**unsupported capabilities** that fail cleanly instead of half-working.

- **S3 is never used, by design - it is not an unimplemented plugin feature.**
  `ansible_aws_ssm_bucket_name`, `ansible_aws_ssm_plugin` and the S3 addressing options are
  accepted and ignored with a one-time warning so existing inventories keep working; files and
  plugins always travel over the session itself.
- **`ansible_user` is not a login user.** The session runs as the SSM document's run-as user
  (`ssm-user` for a standard shell document). `become`/`become_user` is the only way to switch
  privileges, matching Ansible's own plugin note.
- **Linux shells only.** A PowerShell `ansible_shell_type` or Windows `ansible_os_family`/
  `ansible_system` fails before a session is opened; krikri has no winrm/psrp transport either.
- **No port forwarding, no SSH-over-SSM (`AWS-StartSSHSession`), no smux** - non-goals, not
  missing branches.
- **`async:` works, with the session as the job's lifetime.** A launched worker is detached
  (`nohup` + `setsid` when the target has it, stdin `/dev/null`) and writes the usual
  `~/.ansible_async/<jid>` status file, so `poll:` and a later `async_status:` behave as they do
  over ssh; `async_status: mode: cleanup` removes the status, args and sidecar files (the args
  file and a become-password wrapper are created 0600). Verified on a real target (issue #1693):
  the agent does **not** reap a detached child when the session ends - jobs outlived both an
  explicit `TerminateSession` and an agent-closed idle session (a bare `&` child survived the
  terminate run too, though only the nohup/setsid forms are pinned by a test). A job therefore
  outlives its session and is stopped only by something that kills the process itself (instance
  stop/reboot, agent restart, OOM, a manual kill). What is *not* implemented is a controller-side
  kill on `async:`
  timeout (same as the ssh path): the task reports `Timeout exceeded` and the worker keeps going.
- **`synchronize:` fails cleanly** with a documented message (`synchronize is not supported over
  aws_ssm yet`): the action builds an rsync-over-ssh argv and an SSM host has no ssh path.
- **Credential subset.** Environment statics and web identity, shared profiles (`role_arn` +
  `source_profile`/`credential_source`, `mfa_serial`, `credential_process`, SSO cache), ECS
  container credentials and IMDSv2 are supported. MFA-token AssumeRole reads the one-time code
  from the terminal (echo suppressed) or from an injected token provider; a non-interactive run
  with neither fails with a clear error.
- **Session lifetime.** Amazon's idle timeout and one-hour session cap still apply. A session that
  dies mid-command fails the task rather than re-running it, because the remote state is unknown.
- **The controller needs no AWS CLI and no session-manager-plugin** - the improvement over
  Ansible's plugin, which requires both plus a bucket.

### AWS SSM four-way comparison: console parity baseline (issue #1691)

The #1664 live four-way comparison (ansible/krikri over ssh/ssm, same playbook and role) found one
recap delta: `ansible-playbook` over SSH reported `ok=11` while the other three runs reported
`ok=12`. It was not a krikri counting defect.

- With the same gathering mode and capture (no TTY color), the exact play is **byte-identical**
  between ansible-core 2.21.6 and krikri over both local and SSH: 55 identical stdout lines, the
  same interpreter-discovery warning on stderr, `ok=12 changed=6`. `meta: flush_handlers` is not
  counted in `ok` by either engine; a notified handler is counted
  (`test/integration/meta_flush_handler_recap_test.cr` pins this).
- This box exports `ANSIBLE_GATHERING=smart` and
  `ANSIBLE_CACHE_PLUGIN=community.general.pickle` with
  `ANSIBLE_CACHE_PLUGIN_CONNECTION=/tmp/ansible_facts_cache`. Ansible skips the implicit
  `Gathering Facts` task on a host whose facts are still warm in that cache, even when the play
  says `gather_facts: true`. krikri implements only the `jsonfile` backend, so it never sees the
  warm pickle entry and gathers, adding exactly one `ok`. The final ansible/SSH run had a warm
  `ssh-target` entry; ansible/SSM's `ssm-target` was cold.
- Four-way runs must be normalized: clear/disable the fact cache (or set
  `ANSIBLE_CACHE_PLUGIN=memory` and `ANSIBLE_GATHERING=implicit`) and capture both engines without
  a TTY, or with `ANSIBLE_NOCOLOR=1`. With that, the two consoles match byte for byte for this
  play.
- Accepted transport-only tier-3 differences: Ansible's SSM plugin prints its own
  S3/bucket/session-manager-plugin notices (and requires both), while krikri prints one
  ignored-bucket warning and moves everything over the session; the Python
  interpreter-discovery warning appears where a Python interpreter is discovered (native facts
  over SSM discover none). Neither changes a task result or a recap counter.

### A non-string `import_tasks:` file value crashes real Ansible; imitated only for play-level tasks and handlers

A static import whose target is not a string, in the mapping form
(`import_tasks: {file: 46}`), makes real `ansible-playbook` (2.19.11 and 2.21.6) die at
playbook-load time with an uncaught Python `TypeError`: its own `DataLoader.path_dwim` runs
`len()` over the `_AnsibleTaggedInt` in `parsing/quoting.py`, so the run prints
`[ERROR]: Unexpected Exception, this is probably a bug: object of type '_AnsibleTaggedInt' has no len()`
followed by the two full Python tracebacks and exits 250 - before any play output. The free-form
form (`import_tasks: 5`) is caught by Ansible's own type check (`unexpected parameter type in
action: <class '..._AnsibleTaggedInt'>`). krikri counterfeits that whole crash byte for byte
against 2.21.6 (rc=250 included) when the import is a play's task, pre-task, post-task or
handler (`StaticImportNonStringFileError`, issue #1122): the frames are fixed for the release,
only the play.py entry differs between the tasks and handlers sections. Imports in the contexts
whose frames that render does not cover - a role's tasks, a block-nested import, a nested import
inside another statically imported file; each loads through different `helpers.py` frames - still
report the stringified value's missing-file error (`Unable to retrieve file contents. Could not
find or access '<dir>/46' ...`) at rc=1, i.e. they diverge the way the whole class did before
#1122. Issues #934, #945, #1122.

### Fact gathering does not need Python on the target

Real Ansible's `Gathering Facts` fails on a host with no `/usr/bin/env python3` (`The module
interpreter '/usr/bin/env python3' was not found`, recap `failed=1`). krikri's `setup` is a compiled
binary and needs no Python, so it gathers facts and the play proceeds. This is inherent to the
compiled-module design, not a defect; a role then failing later on that host (e.g. a variable only
defined from facts) is the same role-side gap either way.

### The static-musl Linux release binary cannot reach a musl host's `crypt()`

`password_hash` resolves libxcrypt/libc's `crypt()`/`crypt_gensalt()` at runtime (`dlopen`), the way
ansible's own `CryptFacade` does, so a host with libxcrypt (any glibc distro) gets byte-identical
hashes, a host without it degrades with Ansible's own `crypt cannot be used as the 'libxcrypt'
library is not installed or is unusable.`, and a bare musl `crypt()` (no `crypt_gensalt`) gets
Ansible's hand-built salt string instead (live-verified in an Alpine container: the same
`$6$rounds=656000$mysalt$...` libxcrypt produces).

The exception is the *shipped* `krikri-*-linux-*.tar.gz` binary: it is fully static musl, and musl's
static `dlopen` is a stub that fails, so on an Alpine/musl host even the musl `crypt()` compiled into
that binary is unreachable and `password_hash` reports the libxcrypt-missing error where a
Python-based Ansible on the same host would succeed. Deliberate: the alternative is statically
vendoring libxcrypt into the release build (an extra source build per arch) to buy back one filter on
a distro the static binary exists to avoid depending on in the first place.

### No automatic cross-compilation of plugin binaries for a foreign-arch target

krikri's modules are compiled binaries uploaded to the target and exec'd there, so an x86_64
controller managing an aarch64 target (a Raspberry Pi) needs binaries built for aarch64 - real
Ansible ships Python modules and has no equivalent constraint. krikri probes every target's
architecture over its own SSH channel (`uname -m`, folded into the upload path's existing
listing round trip, remembered in the plugin-state cache as `_arch` so warm runs never re-probe)
and then:

- same arch as the controller: the default `plugins/` binaries, exactly as before (unchanged
  path, byte-for-byte);
- different arch, and a `plugins-<arch>/` directory exists next to the `krikri-playbook`
  executable (or `bin/plugins-<arch>/` in the checkout): those binaries are selected, compared
  by md5, and uploaded like any other - one fat-plugin binary per arch dir serves every module
  name, mirroring build.sh's hardlink model;
- different arch, no `plugins-<arch>/` build: the run fails immediately with
  `PluginArchUnsupportedError` naming the missing directory and the remedy, before any
  multi-MB upload of a binary the target's kernel would refuse with exec-format error. The
  host is NOT booked UNREACHABLE (it answered - the controller has nothing runnable for it);
  its first task fails with the same message and the host halts from there.

The deliberate limit: krikri does not cross-compile those binaries for you. Crystal has no
practical turnkey cross-build for this project's plugin set (each plugin links the Crystal
stdlib against target-arch libgc/libyaml/libpcre, so a proper cross toolchain plus per-arch
native libraries would be needed), so the supported flow is: run `./build.sh` on a machine of
the target's architecture (a Pi, an ARM cloud box, an emulated/chroot arm64 environment) and
copy the resulting `bin/plugins/` directory to the controller as
`<krikri-install-dir>/plugins-<arch>/`. Verified live (2026-10-11) against a real sshd target
reporting aarch64 (a `/usr/local/bin/uname` shim inside an ubuntu:22.04 podman container
standing in for the CPU, since this dev box has no qemu-user-static/binfmt registration and
registering binfmt_misc needs root): the per-arch build was selected, uploaded and executed on
the target (remote file md5-identical to `plugins-aarch64/command`, not the default binary),
and the no-build case failed with the actionable message. A genuine foreign-CPU exec was not
exercised - nothing on this machine can execute aarch64 code - but the exec surface itself is
the same code path the same-arch run has always used. Decided 2026-10-11.

### Docker TCP-unreachable wording embeds a Python heap pointer

- A docker module run with `DOCKER_HOST` pointing at a closed TCP port fails with
  `Error connecting: Error while fetching server API version: HTTPConnectionPool(host='...',
  port=N): Max retries exceeded with url: /version (Caused by NewConnectionError('<urllib3.
  connection.HTTPConnection object at 0x7f...>: Failed to establish a new connection: [Errno 111]
  Connection refused'))` - the `object at 0x...` address is a live Python heap pointer, printed
  by real itself. Three runs of real ansible-playbook 2.19.11 against the same closed port
  produced three different addresses (`0x7f0a371d01a0`, `0x7f364e4d41a0`, `0x7fb1ca5c81a0`,
  2026-10-10), and krikri's own rendering (same wording, its `ex.object_id` in place of the
  Python address) varies the same way run to run - the wording, chain shape and errno match;
  only the per-process address differs on BOTH engines, so byte-for-byte comparison of this
  one field is meaningless. (krikri's errno is recovered through a blocking connect re-probe,
  0.9.1611: Crystal's own non-blocking connect surfaces EINPROGRESS without ever reading
  SO_ERROR, so the caught errno was never the verdict real's blocking socket reports.)
  Every other docker failure surface (SDK and CLI) is verified -
  see issue #6. Decided 2026-10-10.

### Both SQL drivers wire TLS but cannot enforce every verification mode

The mysql/pg helpers now pass each module's real TLS parameters through
(`client_cert`/`client_key`/`ca_cert`/`check_hostname` for mysql,
`ssl_mode`/`ca_cert`/`ssl_cert`/`ssl_key` for postgresql). Two verification
details remain the vendored drivers' limits:

- `crystal-pg` (`will/crystal-pg` 0.30/0.31) builds its client TLS context with
  `VerifyMode::NONE`, so `sslmode=verify-ca`/`verify-full` currently encrypt
  but do not verify the chain. Passing `ca_cert` still reaches the driver as
  `sslrootcert`.
- The mysql shard's `VerifyCA` mode also verifies the hostname, because
  Crystal's `OpenSSL::SSL::Socket::Client(hostname:)` always installs an
  X509 host check when verification is on. So `ca_cert` + `check_hostname:
  false` (PyMySQL: chain-only) is stricter here than in real Ansible.

Both require driver changes (a fork release for mysql, an upstream patch for
pg). Decided 2026-11-11: wire what the drivers support, do not silently
pretend to verify.

### `password_mechanism=sshpass` is not implemented (askpass is always the fallback)

ansible-core 2.21.6 defaults `password_mechanism` to `ssh_askpass` and only needs the `sshpass` program when
the option is set to `sshpass` explicitly (without it installed, real fails the host with `to use the
password_mechanism=sshpass, you must install the sshpass program`). krikri has no such option: with a
connection password it uses `sshpass -e` when the program exists and otherwise OpenSSH's `SSH_ASKPASS`
(helper in a fresh 0700 directory, password via `SSHPASS` in the environment only), so a play that sets
`ansible_ssh_password_mechanism: sshpass` without `sshpass` installed succeeds here where real fails.
Decided 2026-10-08: lenient direction, not worth emulating.

### Callback-plugin emulation covers exactly two shapes; everything else is skipped with a warning

There is no generic callback-plugin architecture. `ANSIBLE_CALLBACKS_ENABLED` implements exactly
`ansible.posix.profile_tasks` (plus the legacy short form `profile_tasks`);
`ANSIBLE_STDOUT_CALLBACK` recognizes exactly `oneline` (plus a no-op `default`, which is what
krikri's hardcoded display already is) and every other value there is a hard startup error. Every
other `ANSIBLE_CALLBACKS_ENABLED` entry is warn-and-skipped instead, like upstream: a name no
loader path (the playbook's and roles' `callback_plugins/`, `ANSIBLE_CALLBACK_PLUGINS`, the
configured roots, a collection's `plugins/callback/`) provides gets Ansible's own
`[WARNING]: Skipping callback plugin 'X', unable to load`, and a callback ansible would load gets
krikri's own `[WARNING]: Callback plugin 'X' cannot be executed by krikri-playbook and is ignored.`
Neither aborts the run (issue #1473: a reporting plugin must not stop the play). Custom callback
plugins are therefore never EXECUTED, so their own output lines (and any behavior they add, e.g. a
custom stdout callback named via `ANSIBLE_STDOUT_CALLBACK`) are missing from the run. Listing modes
(`--syntax-check`/`--list-*`) print no callback warning, matching upstream. Consequences:

- `profile_tasks`' own config surface is not implemented: `PROFILE_TASKS_TASK_OUTPUT_LIMIT` stays
  at the default 20 rows, `PROFILE_TASKS_SORT_ORDER` stays at the default descending, and
  `PROFILE_TASKS_SUMMARY_ONLY` is not honored. The -vv+ per-row `task path:` line under each recap
  row is not rendered either.
- Other aggregate callbacks (`profile_roles`, `profile_json`, `community.general.*` timings) and
  custom aggregate callbacks are skipped with a warning rather than run, so the lines they would
  print are absent.
- Other stdout callbacks (`minimal`, `dense`, `json`, `-t/--tree`) are not implemented and error.
- `ANSIBLE_CALLBACK_WHITELIST` (removed upstream >= 2.12) is deliberately NOT read.

On the oneline side, two scope bounds: -v/-vv/-vvv output is not reshaped by the callback beyond
suppressing the default callback's own artifacts (task banners, `task path:`, NOTIFIED HANDLER
lines) - controller-side verbose output is unchanged - and a task-level error's [ERROR] chain
block collapses to oneline's own `An exception occurred ...` line plus the FAILED! dump, as the
real callback's exception branch does. Also accepted: looped `include_tasks:`/`include_role:`
iterations print one line per iteration under oneline where real prints the whole loop as a
single aggregate (the per-iteration results never reach this engine as one aggregate shape).
Decided 2026-10-10.


### Third-party strategy plugins are refused at startup

`strategy:` resolves `linear`/`free`/`host_pinned`/`debug`, and for any other name looks for a
`<name>.py` on Ansible's strategy loader paths: the playbook-adjacent `strategy_plugins/` first, then
`ANSIBLE_STRATEGY_PLUGINS` (replacing the defaults) or the configured `plugins/strategy/` roots.
Real loads and runs such a plugin: Ansible's loader deprecates a non-`ansible.builtin` strategy with
two stderr lines, then `StrategyModule#run` drives Ansible's whole iterator. That is Python
control-plane code this engine has no seam for, so a play naming a plugin found on those paths stops
at startup with `[ERROR]: Strategy plugin '<name>' (<path>) cannot be executed by
krikri-playbook; ...` and rc 1. Warning and running as linear instead (krikri's behavior for issues
#1439/#1456) let a play finish with results the plugin never produced - a retry plugin turns a
first-attempt failure into a passing third attempt, so `failed=1` against real's `ok=1` (issue
#1657). A name on none of those paths still fails with Ansible's own `[ERROR]: Invalid play
strategy specified: <name>` (rc 1); a fully qualified collection strategy name
(`namespace.collection.name`) is not resolved and errors the same way. `debug` is Ansible's linear
strategy plus an interactive stdin prompt on a failed task: the linear half runs, the prompt does
not. Decided 2026-11-20.

The retry fallback (issue #1542) is the explicit opt-in to a degraded linear run: with
`KRIKRI_STRATEGY_RETRIES=<n>` (and `KRIKRI_STRATEGY_RETRY_DELAY=<seconds>`, default 5) set, a play
whose strategy plugin was found runs as linear instead of being refused, with Ansible's own
deprecation pair (no line of krikri's own, so the transcript stays comparable to real's) and every
task that wrote neither `until:` nor `retries:` retried on failure the way ansible's task_executor
does once `retries` is set (its condition defaults to `not utr.failed`) - reproducing the plugin's
pass/fail outcome (`ok=1` with the counter at the attempt count instead of a first-attempt
`failed=1`; see the `1657-strategy-plugin-retry-fallback` corpus case). The env var is the
operator's acknowledgement that the plugin's own code is not running. The settings are read ONLY for
such a play, so an inherited environment never reshapes a run krikri does implement, and an
unparseable value stops the run. The portable migration for anything else a plugin does -
logging/decorating the linear run, altering worker affinity, ordering beyond linear - is to move
that behavior onto the tasks. Decided 2026-11-20.


### `ansible.cfg` is read for six settings only; the rest still comes from `ANSIBLE_*` vars and play vars

- krikri locates `ansible.cfg` the way Ansible does (`$ANSIBLE_CONFIG`, `./ansible.cfg`,
  `~/.ansible.cfg`, `/etc/ansible/ansible.cfg`) and reads exactly the settings whose absence
  changes a run's outcome rather than its decoration: `[defaults] inventory`, `roles_path`,
  `library`, `remote_user`, `deprecation_warnings` and `[ssh_connection] ssh_args`, plus their
  env forms (`ANSIBLE_INVENTORY`, `ANSIBLE_ROLES_PATH`, `ANSIBLE_LIBRARY`, `ANSIBLE_REMOTE_USER`,
  `ANSIBLE_DEPRECATION_WARNINGS`, `ANSIBLE_SSH_ARGS`), which outrank the file. Env var > ini >
  default, and a relative ini path resolves against the config file's own directory, as Ansible's
  `ConfigManager` does.
- `deprecation_warnings` is the one read for its decoration: it is the switch ansible's own
  "Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg"
  hint names, so leaving it unread meant a project could not silence that output at all
  (issue #1660). It suppresses deprecation blocks and the hint, never a `[WARNING]`, and the
  result's `deprecations` list is untouched.
- Every OTHER ini key is still ignored. Seen in practice: `[defaults] inject_invocation = True`
  (2.21's default is off; real then echoes `invocation`, krikri does not - the #909/#910 repro
  shape), `stdout_callback`, `callbacks_enabled` and the `profile_tasks` knobs.
- The same switches do work through their environment variable (`ANSIBLE_INJECT_INVOCATION`,
  `ANSIBLE_STDOUT_CALLBACK`, `ANSIBLE_CALLBACKS_ENABLED`, ...) or a play var where Ansible has one
  (`ansible_inject_invocation`); those are what krikri reads.
- No general INI parser is planned: the file's key/merge semantics are a large surface for settings
  that mostly have an env-var equivalent. The six above were added because dropping them made a
  playbook target the wrong inventory, lose its roles/modules or open ssh as the wrong user
  (issue #1478), or printed output a project had explicitly turned off (issue #1660).
  Decided 2026-11-07, amended 2026-11-17 and 2026-11-20.


### Output-parity tiers: the cosmetic warning tier is best-effort, not a divergence to fix

Byte-for-byte parity with `ansible-playbook` 2.21.6 is the bar for everything a user or a script
can act on (tiers 1-2 below), and only best-effort for cosmetic warning text (tier 3):

- **Tier 1 - behaviour:** exit code, per-task results (`ok`/`changed`/`failed`/`skipped`), the
  `PLAY RECAP` counters, and the host's resulting state. Every difference is a defect.
- **Tier 2 - structured output:** module result fields, JSON shape and key order, `no_log`
  censoring, fatal error wording, and the `Origin:` error context under task errors. A difference
  is a real gap and gets an issue: this is the output tools and log scrapers consume, and `no_log`
  censoring is security-relevant.
- **Tier 3 - cosmetic warnings:** `[WARNING]`/`[DEPRECATION WARNING]` block text, their order and
  dedup, and Python-internal notices krikri counterfeits (`INJECT_FACTS_AS_VARS`,
  `to_text`-import deprecations). Fixed opportunistically when cheap, never a blocking divergence
  issue: ansible-core's own warning text changes between releases (2.23/2.24 already remove some),
  so chasing it is a moving target. Tier-3 noise that actually confuses users can still earn a fix.

The divergence-corpus tests stay exact in all tiers for what krikri already matches: the tiering
decides which NEW findings are issues, not what the tests assert. Differences unmatchable by
nature (PID, timestamp, Python string-hash randomization) are a separate list, below. Decided
2026-11-18 (trialled: revisit with evidence, not by relitigating).

### Console-output differences from ansible-core 2.21.6 that cannot be matched

krikri aims for byte-for-byte identical stdout/stderr/exit code to `ansible-playbook`
2.21.6 (checked with `scripts/output_parity.sh` and the per-module
`krikri-playbook-generator`). The known exceptions:

- Python interpreter-discovery warnings (`Host ... is using the discovered Python interpreter ...`):
  krikri has no interpreter to discover.
- Random per real run: temp file/dir names, string-set order (`union`/`intersect`/... on lists of
  strings), and the order of several invalid options in one error message. Integer set order *is*
  reproduced.
- Loops over `difference` / `symmetric_difference` of lists of strings (e.g.
  `loop: "{{ a | difference(b) }}"`, seen in l3d.sshd tasks/keys.yml): ansible-core builds these
  with `list(set(a) - set(b))`, so the item order comes from Python set iteration under
  per-process string-hash randomization and differs between real runs; krikri emits a fixed order,
  which cannot match every run. Integer lists are reproduced (src/krikri/py_set.cr). Issue #355.
- `community.general.filesystem`'s `value of fstype must be one of: ...` is built by real from a
  Python set of strings, so **Python string-hash randomization** reorders it per process -
  unmatchable by design; the generator masks it (`FSTYPE-SET-ORDER` in masks.cr).
- `ansible.posix.firewalld_info`'s `Please note: zone:(...) have been ignored in the gathering
  process.` note lists the ignored zones from `list(set(specified_zones) - set(collected_zones))`
  (firewalld_info.py), so **Python string-hash randomization** reorders them per module process:
  five real `ansible-playbook` runs of issue #1628's task in one container alternated between
  `zone:(wmnfiv,lecefn)` and `zone:(lecefn,wmnfiv)`. krikri keeps the declared order (which is one
  of real's possible orders; sorting would match no better) - unmatchable by design, still to be
  masked in the generator like `FSTYPE-SET-ORDER`.
- `unarchive`'s "Failed to find handler for ..." message joins the per-handler failure reasons
  (`Command ... could not handle archive`, `Unable to find required ... binary`) from a Python set
  of strings, so **string-hash randomization** reorders them per process (every sample differs,
  even cold vs warm of one round) - unmatchable by design; krikri emits a fixed order
  (issue #255, earlier #112).
- A `uri:` result carries the server's HTTP `Date` response header as `date` (uri.py merges every
  response header into the result, `-` to `_` lowercased): the value is the server's per-request
  wall-clock stamp. Two real Ansible runs of one playbook print different values, and even a single
  run's five requests can straddle two seconds, so no two runs agree by construction (kpg issue
  #1073's whole masked diff was this value and nothing else). Unmatchable by design; only the value
  is masked, in `scripts/output_parity.sh` and `krikri-role-tester`'s `Compare` (`http-date`). The
  generator has no mask for it yet, so `krikri-playbook-generator` still reports the shape as a
  divergence.
- A `copy:`/`template:` `validate:` command's stderr is echoed raw, and a validator like `haproxy`
  prefixes every ALERT line with the PID of the process that parsed the config
  (`[ALERT]    (590) : parsing [...]`). That PID is assigned by the kernel to whichever validator
  process each engine spawns, so it differs between any two executions of the SAME engine: two real
  Ansible runs of one `validate:` task printed `(4175548)` and `(4182901)`, and issue #1090's whole
  emmetog.haproxy diff was that number and nothing else. Unmatchable by design; only the digits are
  masked, in `scripts/output_parity.sh` (the krikri-role-tester side needs its own
  `Compare::MASKS` entry, which the mask pass adds).
- `-vvv` module-execution mechanics lines (`ESTABLISH LOCAL CONNECTION ...`, `EXEC`/`PUT`,
  `Using module file ...`, `Pipelining is enabled.`): no interpreter, module file or staged tmp dir
  exists here, and those lines embed per-run random `ansible-tmp-<epoch>-<pid>-<random>` paths. Masked
  in `scripts/output_parity.sh`.
- `copy:`/`template:` at `-vvv` carry Ansible's `invocation.module_args` block naming its random staged
  Python module file; krikri emits none (the deterministic check-mode content-copy shape IS
  reproduced). Masked in `scripts/output_parity.sh`.
- Malformed `-e '{...'` JSON: Ansible prints a multi-part stderr chain and exits 4; krikri prints one
  line and exits 1.
- `--version`: Ansible's block names Ansible's version, config file and Python paths - facts a non-Python
  engine cannot truthfully reproduce.
- `--help`/unknown option: Ansible's listing comes from its own option set (including options krikri
  lacks) and an unknown option is argparse's `usage: ...` + `error: unrecognized arguments: ...` with
  exit 2; krikri prints its own usage, exit 1. Matching it would mean embedding Ansible's help text.
- Multi-host task-line ordering: Ansible's order for 2+ hosts comes from hash-randomized set iteration
  and fork scheduling (two Ansible runs already disagree byte-for-byte); krikri uses inventory/pattern
  order, so `scripts/cli_output_parity.sh` runs its execution cases against single-host play
  patterns and sorts the `hosts (N):` block in `--list-hosts`.
- Quote-soup task arguments (single-quoted Jinja with embedded escaped quotes as YAML quote soup):
  krikri's YAML/arg split keeps backslashes verbatim where Ansible's splitter unescapes them, so both
  "succeed" with different bytes; clean quoting is identical.
- Broken `with_*` loop source (`with_subelements:` missing its subkey term): Ansible fails with the
  lookup-plugin error plus a bare `Origin: <unknown>` / `invoke_lookup()` block; krikri degrades the
  loop to a failed task with the finalization chain. (The with_dict-on-None shape left this class in
  round 5410000: it now fails with the dict lookup's own refusal wording, byte-identical.)
- `template:` with `output_encoding:` as a YAML list of plain strings (`[a, b]`) reports Ansible's
  `unknown encoding: a,b` instead of the Python type error: the params wire comma-joins such a list,
  making it indistinguishable from STRING `"a,b"`, which real itself reads as a codec name.
- `include_role`/`import_role` with SEVERAL of `defaults_from`/`handlers_from`/`tasks_from`/
  `vars_from` wrong-typed: real picks which to report by Python set order (the same playbook
  alternates), so krikri cannot match it. Masked in `scripts/output_parity.sh` and the generator;
  message text and type still have to match.
- String-list or dict literal where Ansible's module crashes on the type, on a param the wire flattens:
  `debconf` with a plain-string-list or dict `value:`, and the Python `repr` of an all-string list in
  `copy`'s `remote_src` missing-source message. Only non-string scalars and lists with a non-string
  member are reproduced.
- Python-set iteration order in results: `openssl_csr`/`openssl_certificate` `public_key_fingerprints`
  and `postgresql_privs`'s multi-privilege list come from a Python set/frozenset in real
  (nondeterministic across Ansible runs themselves); krikri keeps the declared order. Other
  `ansible-core` releases may differ; 2.21.6 is the reference.
- `apt:`/`apt_repository:` update-cache retry warnings against a repo with no Release file
  (`webbylab.nginx-proxy`, #220): real's python-apt exception text includes a libapt-only
  `W:Repositories should provide a clear-signed InRelease file...` line the apt CLI never prints, and
  which attempt quotes which lines varies run to run on the same host (two real runs disagreed on
  attempts 1 and 4). The `Sleeping for N seconds` values are random jitter in both engines. Krikri
  reproduces the failure, retry count and final classification but not these bytes.

### Differential-fuzz residual leniency between the two Jinja evaluators

- What remains after triaging `bin/differential_fuzz` is deliberate, not defect: two-raw-string and
  numeric-string-vs-number orderings, per-filter argument type leniency (`| sum`/`| abs` on strings,
  `| split(dict)`), `not (...)` around an unimplemented inner construct,
  bare-callable attributes (`str.count`), and the lenient chain off a lenient undefined for bracket
  indexing (`missing_var[9]` stays the "undefined" sentinel - the load-bearing shape behind
  `x | default(other.thing.y)`). These live as tight predicates in
  `src/krikri/differential_fuzz/runner.cr` (`KNOWN_DIFFERENCES`); the fixed-seed CI slice is
  `test/unit/differential_fuzz_test.cr`, which runs in the normal suite. The exploratory sweep
  binary is dev-only and opt-in: no shipped binary links it, so `./build.sh` skips it unless you
  pass `--differential-fuzz`.

### Unsafe-data taint is a provenance-closed registry, not an AnsibleUnsafe type

- Real marks host-controlled strings with a type (`AnsibleUnsafeText`) that survives every
  operation; krikri registers the hostile TEXTS in a global registry closed under derivation -
  once a render decision establishes (by resolved name, expression provenance or substring
  containment) that an output was fed by execution data, the transformed output is registered too,
  so every later re-render refuses it by text. Same verdict as the type for every shape tested,
  but structurally approximate: a NEW re-render path must extend the hostile matrix in
  `test/integration/unsafe_data_test.cr`, not be assumed safe.

### `fetch:` refuses a destination that escapes `dest`, stricter than Ansible

- A `src` whose `..` components carry the composed `dest/<host>/<src>` path outside `dest`
  fails with "Detected directory traversal, expected to be contained in ..." instead of writing
  there. Ansible 2.21.6 writes through: its CVE-2019-3828 traversal guard never fires in this case
  (observed behavior, re-verified 2026-11-07). Deliberate: `src` can come from host-controlled data (e.g. `find:` results) and a
  controller-side write outside `dest` is exactly that CVE. Non-escaping paths match real
  byte-for-byte.

### Modules do not log "Invoked with" lines to the target's syslog/journal

- Every real Ansible module run writes `ansible-<module> Invoked with ...` to the target's
  syslog or journal (observed: 181 such lines in a local `/var/log/syslog` after a few playbook
  runs). Krikri's plugins write nothing there. A role that archives `/var/log`
  (`deekayen.log_mailer`'s `community.general.archive` + `fetch`) therefore sees a changed
  archive between a cold and a warm run under Ansible (syslog mtime/size moved) but an identical
  one under krikri, so `Archive logs.`/`Fetch logs.` read `changed` vs `ok` on the warm run.
  Deliberate: emulating the log lines would mean every one of the ~148 plugins writing
  Ansible-format entries to a host-specific log sink, for no behavior a playbook should depend on.
  The archive plugin's own comparison (member-header set, mtime-sensitive) matches real.

### `ansible_version` is pinned to a fixed ansible-core release, not this project's own version

- `ANSIBLE_VERSION_MAGIC_VAR` reports `2.21.6` regardless of which `ansible-playbook` is
  installed on the machine running krikri. Deliberate: version-gated role features expect a
  2.x-shaped comparison target, and this project's sub-1.0 version would make every such min-version
  check fail unconditionally. It will not drift to match whatever is locally installed.

### krikri never consults an installed ansible-core or collections tree

- Decided 2026-11-18. krikri has **no runtime dependency on an Ansible installation** and its
  behavior is identical whether or not ansible-core/collections are present on the controller.
  Module-name resolution (the builtin name/redirect tables, each captured collection's plugin file
  tree), the pinned per-module collection release, the action-plugin inventory and the
  `ansible.module_utils` deprecation events all come from krikri's own baked tables
  (`src/krikri/builtin_module_names_data.cr`, `src/krikri/collection_runtime_data.cr`, generated by
  `scripts/gen_builtin_runtime_data.py` and `scripts/gen_collection_runtime_data.py`). Nothing in
  `src/` scans an installed ansible-core or `ansible_collections` tree. Executing python plugins is
  NOT reference data and still reads the environment: a role's/playbook's `library/*.py` module, a
  collection's python plugin, and the `ansible.module_utils` imports those executed modules resolve
  all run through the target's `python3`.
- Consequences, all accepted:
  - **Refusal parity is gone where real's own installed set decides.** Real refuses a whole
    playbook at load (rc=4, zero tasks) for a module name it cannot resolve on the controller it
    runs on; krikri no longer does that. An unresolvable name takes the executor's
    unavailable-module flow instead: a `when:`-gated task skips cleanly and a genuinely reached one
    is reported with a `uses unimplemented plugin` line and the run exits 4 at the end (except under
    `--check` for the unported modules real itself skips there - the ones whose Ansible module
    declares `supports_check_mode=False`: real does no work either, so krikri reports nothing and
    keeps real's exit 0, issue #1647). So a playbook using a collection nobody has installed, or a
    name real cannot resolve either, runs
    (and usually skips) under krikri where real refuses it at load. This also means the
    `ansible.mariadb.mariadb_db`-style aliases are unconditional (real resolves those only where
    the collection is installed, issue #499).
  - **Version-gated behavior uses the pinned snapshot, not the controller's collections.** The
    plugin wire's `collection_version` and the 2.1.x-vs-2.2.x deprecation gate follow the captured
    release (ansible.posix 2.1.0, community.docker 5.2.1, amazon.aws 10.1.1, containers.podman
    1.17.0, ...). A controller whose release differs gets the pinned line's behavior: e.g. real
    against an ansible.posix 2.2.x tree prints no mount import deprecations, while krikri keeps
    printing the captured 2.1.0 pair. Same class as the argument-spec snapshot limitation below;
    the collections installed on the machine no longer smooth it over.
  - **Counterfeited Python traceback frames use the captured install path.** They are spelled from
    this interpreter's `sysconfig` purelib plus `AnsibleInstall::CAPTURED_PACKAGE`, never from a
    discovered `ansible` package directory, so a virtualenv or distro install path no longer shows
    up in krikri's tracebacks (it shows the pip-default path instead).
  - `module_defaults: group/<name>` expands from the captured collections' `action_groups`; a group
    only an uncaptured collection defines no longer resolves.
- Regenerating: both generators are dev-time tooling and MAY read the capture environment; run
  `--check` after a target ansible-core/collection bump (CI does).

### Module argument specs are a captured collection snapshot, not the target's installed collection

- `data/argspecs.json` is captured by `scripts/gen_argspecs.py` from the collections installed at
  capture time (CI pins community.docker 5.2.1, community.general 12.5.0, ...), and every run
  replays that snapshot. A host whose distro ships an older collection validates differently under
  real `ansible-playbook`, and a baked table cannot adapt per host. Live case (issue #1319): kpg's
  Ubuntu microVM golden keeps the collections of Ubuntu's `ansible` package - Debian/Ubuntu
  ansible-core puts `/usr/lib/python3/dist-packages` on its collection search path, so
  `ansible-galaxy collection install community.docker` is a no-op there and the reference engine
  runs 3.7.0, which has no `definition`, `wait` or `docker_host|cli_context` at all: a
  `docker_compose_v2` task with `client_cert` alone fails with
  `parameters are required together: client_cert, client_key`, where krikri (the 5.2.1
  snapshot) reports `parameters are mutually exclusive: docker_host|cli_context,
  definition|project_src, definition|files`. The same playbook is byte-identical on both
  engines against community.docker 5.2.1 (this host) and 4.7.0 (kpg's Debian template), so
  the fix belongs in the harness: pin or force the collection versions it installs instead
  of keeping the distro copy.

### The benchmark's two microVM goldens install different Python interpreters, so a module's missing-library gate can diverge

- `krikri-role-tester`'s rocky microVM pair boots two different goldens: the krikri side is the
  Rocky GenericCloud image plus `python3`/`python3-pip` (`/usr/bin/python3.9`, which imports
  `requests` because the image's `cloud-init` package requires `python3-requests`), while the
  reference side is that same golden plus `python3.12` - added only so ansible-core 2.21.6 can be
  pip-installed on a python3.9 distro. Both engines resolve a module's interpreter by running
  Ansible's `INTERPRETER_PYTHON_FALLBACK` (`command -v` over python3.14 ... `/usr/bin/python3`), so
  the reference host's first hit is the requests-less `/usr/bin/python3.12` where the krikri host's
  only hit is `/usr/bin/python3.9`.
- Live case (issue #1348, `aem_design.nexus`): its `docker_container` task therefore fails on the
  reference side with `Failed to import the required Python library (requests) on localhost's Python
  /usr/bin/python3.12` and on the krikri side with the daemon-connect error the module reaches after
  that gate. krikri's docker SDK import gate probes the same discovered interpreter real's module
  runs under, so given ONE host both engines print byte-identical output (live-verified with the
  role's own playbook: a python whose `import requests` fails as the first fallback candidate makes
  both report the same missing-library message, and a requests-capable first candidate makes both
  reach the same connect error) - a harness asymmetry, not a krikri defect. A rocky host can never
  be identical for both engines: the reference engine needs python3.12 to exist to run at all.
- Live case (issue #1394, `laxathom.passbolt`): `geerlingguy.mysql`'s `Remove MySQL test
  database.` task. The role installs `python3-PyMySQL`, which lands in python3.9's site-packages,
  so the krikri host reaches the module with a driver and the task succeeds, while the reference
  host's discovery picks the driver-less `/usr/bin/python3.12` and the module stops at `A MySQL
  module is required: ...`. krikri's mysql driver gate probes the same
  `discovered_interpreter_python` real's module runs under, so given ONE host both engines print
  byte-identical output (pinned in `test/unit/mysql_connection_test.cr`).
- The fix belongs in the harness: give the reference golden's python3.12 `requests` and
  `PyMySQL` (e.g. `python3.12 -m pip install requests PyMySQL`) so both hosts behave like a
  target that has those libraries installed.
  Do not "fix" it here by probing interpreters that discovery would not pick - that diverges from
  real ansible on every host that does not look like these two.

### `aem_design.aem_license`'s `no_log`-vs-fail-hard divergence is a human security judgment call

- A `no_log: true` task masking a license-key value diverges from Ansible in a way that is
  borderline security-sensitive (fail hard vs. silently proceed on a masking edge case), not a
  clear-cut behavioral bug. Deliberately left unfixed - a human should decide, not an automated pass.

### Role-private custom `action_plugin`s are not supported (module execution is; action plugins are not)

- Found via the `amtega.*` Galaxy collection (~28 roles), which depend on `amtega.check_platform`'s
  role-private `action_plugins/_check_platform.py`, and via `yourlabs.remember` (issue #669), whose
  role-private `action_plugins/remember.py` is the task's only implementation (its `library/remember.py`
  is empty) - a real `ActionBase` subclass running on the
  controller with access to `action_loader`, `templar` and `connection` internals. Role-private
  `library/*.py` custom **modules** already run here; custom **action plugins** are different in kind -
  controller-side Python reaching into Ansible's own plugin-loading/templating/connection APIs, meant
  to run inside a `ansible-core` process rather than be dispatched to a target.
- Supporting them means either embedding a real Python interpreter with equivalent internal APIs or
  building a bespoke API surface with no other use, for an extension point most Galaxy roles never
  ship. Decision: krikri reports the plugin name as an unimplemented module rather than skipping.

### Python connection plugins are resolved but not executed (their tasks fail)

- A custom connection plugin (`ANSIBLE_CONNECTION_PLUGINS`, the playbook-adjacent or a loaded role's
  `connection_plugins/`, a collection's `plugins/connection/`, or `ansible.legacy.<name>`) is found on
  Ansible's own loader paths and is not refused with "the connection plugin 'X' was not found" (issue
  #1457). Its connection lifecycle (`_connect`/`exec_command`/`put_file`/`fetch_file`) is the whole
  transport layer this engine replaces with SSH or local execution, so the plugin's own code never runs
  - and no transport substitution can stand in for it. Every task (and the implicit gathering of facts,
  and handlers) whose effective `ansible_connection` names such a plugin therefore fails, naming the
  plugin:

  `Task failed: the connection plugin 'X' cannot be executed by krikri-playbook (Python connection
  plugins are not supported)`

  This replaced the warning-and-substitute behaviour of issues #1541/#1658: running the task over an
  approximated transport is what made an SSM-style plugin (`ansible_host=<instance id>`) ssh to the
  instance id and report UNREACHABLE, and it silently ignored whatever the plugin really did. Failing
  is the deliberate choice until running the plugin itself is implemented, which means reimplementing
  Ansible's whole connection lifecycle. `containers.podman.podman` and other resolvable collection
  connection plugins take the same failure (they too are Python plugins this engine cannot execute).

### Unimplemented community.general filter long tail (usage-audited, watchlist not backlog)

- Unimplemented: the dict-key filters (`keep_keys`, `remove_keys`, `replace_keys`, `dict_kv`,
  `groupby_as_dict`), the `lists_*` family (`lists_union`, `lists_difference`, `lists_intersect`,
  `lists_symmetric_difference`), `accumulate`, `counter`, `crc32`, `version_sort`, `random_mac`,
  `unicode_normalize`, `from_csv`, `from_ini`/`to_ini`, `from_toml`/`to_toml`, `json_diff`,
  `json_patch`, `hashids`, `reveal_ansible_type`, the `to_<time-unit>` family and `to_prettytable`.
- They ARE reachable by a role (that is how `lists_mergeby` was found), but a Sourcegraph audit of
  public GitHub YAML showed real usage is almost nil: hits are dominated by the collection's own
  docs/tests and third-party tutorial/vendored copies. The only real-role hits were one `version_sort`,
  one `keep_keys`, one `counter` and zero for `dict_kv`/`groupby_as_dict`/`remove_keys`/`replace_keys`/
  `lists_*`, while the same search for `dict2items` matches hundreds of genuine roles. Decision: none
  go in a backlog on spec; each is implemented on first live hit by a benchmark role.
- **ansible-core builtins** are effectively fully covered - the only absent names are `random`,
  `rejectattr` (deliberately excluded from `KNOWN_FILTER_NAMES`), `groupby`, and the Windows-only
  `win_basename`/`win_dirname`/`win_splitdrive`.

### ansible.netcommon IP filters are implemented even where the Ansible host lacks the collection

- krikri implements the `ansible.netcommon` filter family (`ipaddr`, `network_in_usable`, ...)
  natively, so a role using one renders fine here while `ansible-playbook` on a host without the
  `ansible.netcommon` collection installed fatals with `No filter named 'ansible.netcommon.<filter>'`.
  `jtprogru.hosts` is the precedent: such roles diverge BY DESIGN - the collection gap is on the
  Ansible side, and krikri having the filter is not a defect.

### Init systems and package managers

- **`service:` on an upstart host** - detection covers systemd, OpenRC and SysV (Ansible's own branches,
  in its own precedence order), so such a host is never silently driven as SysV, but upstart itself is
  not implemented: its enable path writes an `/etc/init/<name>.override` whose contents depend on the
  initctl version. Fails with a clear "not supported" rather than guessing.
- **`service_facts:` upstart / chkconfig / OpenRC scans** - systemd and SysV (`service --status-all`)
  are implemented and merged Ansible's way; the other three branches are not. On such a host the systemd
  scan still runs and an empty result is correctly reported *skipped*, not as an empty
  `ansible_facts.services` dict.
- **`package:` backends beyond apt/dnf/yum** - detection uses the same path table and priority as
  `ansible_pkg_mgr`, so the module and the fact a role gates on cannot disagree, but only apt/dnf/yum
  have backends; zypper/pacman/apk/pkgng fail by name ("package manager 'pacman' is not supported by
  this engine"). Out of scope: this engine targets Ubuntu and RHEL-family hosts only. apk is doubly
  out of reach - Alpine is musl and this engine's glibc-linked plugin binaries cannot execute there, so
  the upload fails before any module runs; a musl plugin build is the prerequisite, not an apk backend.

### Arbitrary Python

- **Role-private custom `lookup_plugins/*.py` lookups run on the controller**
  (`PythonLookupRunner`): `lookup('name', ...)`/`query('name', ...)` for a plugin the role ships in
  its own `lookup_plugins/` (or the playbook-adjacent one) dispatches to the controller's own python3
  and runs the plugin's `LookupModule.run(terms, variables, **kwargs)`; a lookup plugin's name IS its
  file name, so no introspection pass is needed. Search roots follow Ansible's loader: the role's own
  directory, the playbook-adjacent one, every role LOADED this run, then the CONFIGURED paths -
  `ANSIBLE_LOOKUP_PLUGINS` when set (it REPLACES the defaults, and `~` is expanded) and otherwise
  `~/.ansible/plugins/lookup` + `/usr/share/ansible/plugins/lookup`. Wired into BOTH templating
  engines separately: the hand-rolled `{{ }}` evaluator's `evaluate_custom_python_lookup` and the
  krikri-jinja side (`krikri_jinja_lookups.cr`, which also serves `query()`/`q()`). The interpreter is
  that same python3, retried once under the interpreter `ansible-playbook` itself runs under when the
  PATH one cannot import `ansible` (the pipx/Homebrew layout). A controller with no `ansible` package
  at all (the normal krikri deployment) still runs a plugin whose imports are the common ones - the
  wrapper installs a built-in stand-in for `ansible.plugins.lookup.LookupBase`/`AnsiblePlugin`,
  `ansible.errors` and `ansible.utils.display.Display`, the same shim approach the module runner uses
  for `module_utils` on a bare target. What still degrades to undefined/`[]`: no python3 at all, a
  plugin importing more of ansible than the stand-in (e.g. `ansible.module_utils`), or no
  `LookupModule` class; a plugin that RAN and raised fails the task with its own error, like real.
  Two pieces of Ansible's environment are reproduced because real plugins use them when ansible IS
  installed: `self._loader` is a real `DataLoader` (so `find_file_in_search_path` resolves through
  `ansible_search_path`), and `self.set_options()`/`self.get_option()` work off the plugin's own
  `DOCUMENTATION` (under the stand-in only values the plugin set itself resolve, since reading
  `DOCUMENTATION` needs PyYAML). The one piece that cannot be is a `Templar`: `self._templar` stays
  `None`, so a plugin that templates through it fails instead of resolving (ansible-core refuses to
  render strings it did not mark itself, so a stand-in would silently return unrendered text).
- **Custom `vars_plugins/` plugins run once, at inventory-parse time** (`PythonVarsRunner`): legacy
  `.py` files under the playbook-adjacent `vars_plugins/`, the `ANSIBLE_VARS_PLUGINS` list (it
  REPLACES the defaults, and `~` is expanded) or `~/.ansible/plugins/vars` +
  `/usr/share/ansible/plugins/vars` have their `VarsModule.get_vars(loader, path, entities)` called
  with ansible's own `Host`/`Group` objects and ansible's per-host precedence (a plugin's vars beat
  inline inventory vars and group_vars-file values; a host_vars-file value beats the plugin).
  `REQUIRES_ENABLED` plugins run only when named by `ANSIBLE_VARS_ENABLED` (default
  `host_group_vars`). Deliberate limits: role-adjacent `vars_plugins/` are not scanned (roles load
  after the inventory), and a plugin whose `get_vars()` raises is warned about with its vars dropped
  instead of aborting the run the way ansible does.
- **Arbitrary-Python-module support is scoped to role-private `library/*.py` sources** (plus the
  playbook-adjacent `library/`): a module with a resolvable source RUNS on the target with the
  target's own python3 through the py_module plugin. Still cut: a module reference with NO library
  source anywhere (parse-time warning, and exit 4 for a reachable one - Ansible's own code for refusing
  a playbook it can't resolve a module for) and every THIRD-PARTY COLLECTION module (next bullet),
  which lives inside installed collections rather than in the playbook tree the runner can see. The
  exit-status half stays divergent for source-less modules: WHICH TASKS RUN differs (Ansible refuses at
  parse time and runs nothing; this engine runs the rest of the play), not the exit status a caller
  sees.
- **Third-party COLLECTION modules and filters, same cut** (e.g. the `bodsch.*` author's
  `bodsch.core`/`bodsch.systemd` collections): Ansible runs these as ordinary Python, so a MODULE
  reference reports "unavailable modules" and skips the task while a FILTER reference fails with
  Ansible's own "No filter named 'x'." rather than silently passing the operand through un-filtered.
  Every `bodsch.*` role calls at least one of these, so that author's roles keep diverging by design.

### Fact caching

- **Only the `jsonfile` backend** (`src/krikri/fact_cache.cr`): by far the most common real-world
  choice, and the only one worth a from-scratch implementation without a client library to lean on.
  `redis`/`memcached` would need real client libraries this project doesn't carry; the built-in
  `memory` backend needs no support at all (this engine's in-run `@facts` store already IS that).
  Revisit only if a real role needs a non-jsonfile backend. Under `ANSIBLE_GATHERING=smart` a
  configured non-jsonfile backend is invisible here, so krikri gathers while Ansible skips a warm
  host's `Gathering Facts` - a one-`ok` recap difference with no behavioural cause (the #1691
  four-way delta; see the SSM console-parity baseline above). Normalize comparison runs with
  `ANSIBLE_GATHERING=implicit` or a cleared cache.

### Templating

- **A tuple-bearing value stored in a var, then `| string`'d later, renders as a bracketed list
  instead of a parenthesized tuple.** Ansible's native-types finalization converts a Python tuple to a
  list at every rendered-output position EXCEPT when `| string` applies Python's own `str()` first;
  krikri replicates that for the inline case (`{{ d1 | dictsort | string }}`), but a tuple crossing
  INTO a var first (`t1: "{{ (1, 2) }}"`) loses its tuple-ness when stored, since krikri's vars
  world is JSON. Recovering that means carrying a real tuple type through the whole vars pipeline,
  for a shape nothing in the role corpus hits.

### `replace:` pattern syntax is checked by a targeted Python-re scanner, not a full re._parser port

`ansible.builtin.replace` compiles `regexp:`/`after:`/`before:` with Python's own `re`
module, outside its `except re.error` - so a pattern Python rejects kills the module ("Task
failed: Module failed: <re.error text>"). PCRE2 (krikri's engine) accepts a superset of Python's
syntax, so krikri runs a left-to-right Python-re scanner over each pattern first
(`plugins/replace.cr`, `PythonPattern`) and translates PCRE2 compile errors to Python's
wording/position where the mapping is exact.

Covered with real-verified messages: the PCRE group-name spellings `(?<name>...)`/`(?'name'...)`
and every other extension char Python rejects (`(?R)`, `(?&`, `(?|`, `(?1`, ...), the inline-flag
section rules, PCRE-only escapes (`\e`, `\z`, `\K`, `\h`, `\G`, `\C`, `\c`, `\o`, `\p`, `\Q`,
`\x{...}`) with the class-context rules for `\A`/`\B`/`\Z`/`\g`, and `\uXXXX`/`\Uhhhhhhhh` (Python
accepts, PCRE2 does not - rewritten to `\x{...}`).

Deliberately left unchecked (they surface with PCRE2's wording inside the same crash wrapper, or
accept where Ansible rejects): `\N{...}` character names; `\8`/`\9` group-reference semantics; `(?P=name)`
resolution and `(?P<>`-shape name errors; Python's semantic inline-flag checks (`(?iLmsxua)`'s
"cannot use 'L' flag with a str pattern", `a`/`u` negation, global-flags placement);
character-class ranges over escapes (`[\d-e]`).

The surrogateescape twin for undecodable bytes under `encoding:` is the private-use codepoint
U+F780+(byte-0x80) rather than Python's U+DC80+(byte-0x80), because PCRE2 aborts a match whose
subject holds raw surrogates; one undecodable byte is one character to the regex either way and the
byte round-trips on write. The collision risk is the one real carries itself, just in a different
range.

### Cosmetic differences (both engines fail; only the wording differs)

These change no outcome and no recap. Listed so they aren't re-reported as bugs, not
because anyone intends to fix them.

- **An erroring task NAME prints an inline marker instead of Ansible's warning.** When a task's
  `name:` itself fails to template (e.g. it reads an undefined `_latest_release.json`), Ansible emits
  `[WARNING]: Encountered 1 template error` and the task runs on; krikri runs it too but renders an
  inline `<< error ... >>` banner marker in the task header instead of the warning line. No outcome or
  recap changes (found via `coopdevs.backups_role`).

### Test-environment notes: output that is nondeterministic by nature

- **`samba-tool` stderr differs on every run (`uspdev.sambadc`).** A failed `samba-tool domain
  provision` embeds python log timestamps, pids, ASLR-randomised stack-frame addresses and a random
  "first record" in the LDB repack lines in its JSON `stderr`. Two runs of real Ansible differ from
  each other the same way, so `krikri-role-tester` masks these in `Compare::MASKS`
  (`samba-log-timestamp`, `samba-pid`, `samba-stack-address`, `samba-repack-record`). Not a krikri
  gap; the Samba 4.15 token-stack panic itself reproduces identically on both engines.

- **Host-key fingerprints and `stat` timestamps differ per host (`HomeSecExplorer.sshaudit`).** The
  role regenerates SSH host keys, so the `ssh-audit` `(fin) ssh-ed25519/ssh-rsa: SHA256:...` lines
  echoed by its results `debug` loop are random on every host, and the `with_items` dump of
  `find`/`stat` results for the removed host keys carries `atime`/`mtime`/`ctime` of the moment they
  were created. The ansible and krikri runs are on different hosts, so these values cannot match;
  the structure around them (item repr, `__hsesa_sshaudit_out` var dump) does. Not a krikri gap.

- **Mounting tmpfs over `/tmp` kills real Ansible's own module run (`hannseman.raspbian`).** Ansible
  unpacks each AnsiballZ payload into `/tmp/ansible_<module>_payload_*`; `mount:` of a tmpfs on `/tmp`
  hides that directory mid-run, so ansible-core fails with "Module result deserialization failed" and
  stops the play (exit 2), leaving every later task unapplied (warm run then shows `changed` where
  krikri shows `ok`). krikri's plugins are standalone binaries with no payload in `/tmp`, so the mount
  succeeds and the play continues. An artifact of Ansible's execution model, not a krikri gap.

- **`mount_facts`' repeat-mounts warning order differs between podman containers (#1236).** The
  warning prints a source's mount points in the order the source file lists them (Ansible's
  `handle_deduplication` keeps `mounts_by_source` insertion order and never sorts), and `/etc/mtab`
  is `/proc/self/mounts`, whose order podman randomises per container for the mounts it injects
  (`/etc/hosts`, `/etc/hostname`, `/etc/resolv.conf`, `/dev/shm`, `/run/.containerenv`). Two
  containers started from the same image list them in different orders, so the kpg harness's two
  containers disagree on those entries while everything else in the list matches. Running both
  engines inside one container produces byte-identical warnings, so this is not a krikri gap; the
  generator would need a mask for that list's order, as it already has for other per-process
  orderings.

- **A failed `npm install` names a per-run debug log (kpg npm cases, issue #1374).** npm writes its
  debug log to `$HOME/.npm/_logs/<YYYY-MM-DD>T<hh>_<mm>_<ss>_<ms>Z-debug-0.log` and repeats that path in
  the last line of its stderr ("A complete log of this run can be found in:"), which Ansible carries into
  the result verbatim (raw in `stderr`/`stderr_lines`, and inside the sanitized `msg`). The stamp is the
  wall-clock moment npm started, and the two engines run in two containers seconds apart, so it can never
  match byte for byte - two runs of real Ansible disagree the same way. Every other field of that failed
  result already matches (`cmd`, the sanitized `msg` text, `stderr`, rc and the recap), so this is not a
  krikri gap: the generator needs a mask for the `_logs/<timestamp>-debug-0.log` component, like the ones
  it has for its other per-run values. The rest of the diff this issue originally showed (krikri's raw,
  unsanitized `msg` and a bare `install` as `cmd`) was a real engine gap, fixed with the sanitiser in
  issue #1372.

- **`file:` with `state: touch` diffs wall-clock timestamps (kpg file cases, issue #1503).** Under
  `--diff` the module prints `initial_diff()`'s payload, and its `atime`/`mtime` entries are the
  file's own stat times plus the "now" Ansible reads immediately before applying `utime`
  (`update_timestamp_for_file`). For a NEW path the hunk carries a pair on both sides (the
  just-created file's times as the before side, next to the `absent -> touch` transition). Those
  floats are the wall clock at each engine's own run moment, so the two containers' runs - and even
  two runs of real Ansible - can never agree on them byte for byte. Every other line of that hunk
  already matches (the key order, the state transition, the hunk's line counts), so this is not a
  krikri gap: the generator needs an epoch-seconds mask (`\d{10}\.\d+`) like the ones it has for its
  other per-run values. `test/integration/touch_result_shape_test.cr` pins the shape such a mask
  anchors on.

- **`assemble:`'s controller-side diff names a per-run staging file (kpg assemble cases, issue
  #1539).** With `remote_src` falsy under `--diff`, Ansible's assemble action assembles the fragments
  into a `tempfile.mkstemp` file in its own `~/.ansible/tmp/ansible-local-<pid><rnd>/` and heads the
  diff's after side with that path (`_get_diff_data(dest, path, ...)`), so `+++ after:` carries a
  name drawn at random by Ansible's Python runtime - two runs of real Ansible differ in exactly those
  characters. Everything else in the hunk (the bare `--- before` for a not-yet-existing dest, the
  body, `changed`) matches byte for byte, so this is not a krikri gap: the generator's
  `ansible-local-<rnd>/tmp<rnd>/` mask requires a trailing path separator, which the template-shaped
  header has (staged dir plus the source's basename) but the assemble one does not (the staged FILE
  is the last component), so that mask needs to accept the end of the path too.
  `test/integration/assemble_test.cr` pins the file-shaped header so such a mask keeps a stable
  anchor. The same task's `backup: true` leaves `<dest>.<pid>.<timestamp>~` behind, and that name
  embeds each engine's own process id and run moment, so the harness's state diff (which does not
  apply `ByteDiff::MASKS`) reports it on every run; the backup's content, size and mode already
  match (Ansible's `backup_local` copies with `shutil.copy2`, so a 0444 destination leaves a 0444
  backup, which krikri now reproduces).

- **`hostname:`'s `--diff` before side is the run host's own name (kpg hostname cases, issues
  #1547/#1550).** The module's diff is the text-string pair `hostname = <name_before>` /
  `hostname = <name>` (the shape issue #1504 fixed), and `name_before` is whatever the run host
  currently calls itself. The kpg harness runs each engine in its own podman container with
  podman's default hostname (the container's own 12-hex id), so the two sides name two different
  machines and can never agree - two real Ansible runs in two containers disagree the same way
  (the generator's own `--control` noise check, real ansible on both sides, reproduces exactly that
  one line and nothing else). Starting the engine pair with one shared `--hostname` makes the whole
  run byte-identical, and every other line of the hunk (the `--- before`/`+++ after`/`@@ -1 +1 @@`
  framing and the after side) already matches, so this is not a krikri gap: the generator needs a
  mask anchored on `hostname = ` plus that value. `test/integration/hostname_test.cr` pins the
  hunk's shape and that the before value is the run host's own hostname;
  `test/integration/hostname_param_coverage_test.cr` pins the same before side with an explicitly
  container-id-shaped hostnamectl shim, so the mask's anchor stays stable even where the build
  host's own name has another shape.

### Everything else

- **`ansible-playbook`'s CLI flag surface is fully covered by name, and all but one flag is
  behavioral.** `--help` lists every flag ansible-core 2.21.6 does, including its own long
  aliases (`--inventory-file`, `--vault-pass-file`).
  * `-M`/`--module-path` is accepted and ignored, a scope cut rather than an oversight: real searches
    those directories for PYTHON modules while every module here is a compiled binary, and faking it
    would silently look for a same-named compiled binary in a directory of `.py` files this can never
    execute.
  * `--scp-extra-args` extends the scp command lines in `SSHManager#upload_file`/`#download_file`,
    alongside `--ssh-common-args` (which real applies to scp as well - only `--ssh-extra-args` is
    ssh-only). `PluginManager` also falls back to scp for the plugin-binary push when rsync is missing.
  * `--sftp-extra-args` is accepted and inert (nothing here ever invokes `sftp`); `--flush-cache` is
    correct (facts live only in a run-scoped store, so no on-disk cache exists).
  * Short forms match Ansible: `-C` is `--check`, `-D` is `--diff`, `-c` is `--connection`.
    **`-c` previously meant `--check` in this engine and no longer does**, a deliberate breaking change
    so a copied command line behaves the same here. `-d` is kept as an extra alias for `--diff`.
- Cloud provider modules: only a narrow AWS/EC2 slice is implemented - `amazon.aws` `ec2_instance`,
  `ec2_key`, `ec2_security_group`, `ec2_ami_info`, `ec2_vpc_net_info`, `ec2_vpc_subnet_info`,
  `ec2_metadata_facts` and `iam_user_info` (a hand-built SigV4 API client, `plugin_helpers/ec2_api.cr`;
  none can be exercised against a real account by the test rounds, see below) - plus the `aws_ec2`
  inventory plugin. Everything else (`community.aws`, other `amazon.aws` modules, `azure_rm_*`,
  `google.cloud`, `openstack.cloud`, `community.vmware`) is not implemented and not planned: each
  needs a real per-provider API client with request signing/auth, not "another module that shells
  out to a CLI tool". Revisit only if a specific need justifies it.
- YAML-defined inventory plugins (`plugin:` sources): `host_list`, `ini`, `yaml`, `constructed` and
  `amazon.aws.aws_ec2` are implemented via `src/krikri/inventory_plugins.cr`; aws_ec2 talks to the real
  EC2 API with SigV4 through the `krikri-aws-signer` shard, credentials from the standard `AWS_*`
  environment variables. Deliberate approximations: default `hostnames` order is `ip-address`,
  `private-ip-address`, `instance-id`; constructed `filters` are AND-combined `key=value` / bare-key /
  `*` / `!`-negation entries, not Ansible's richer condition syntax; keyed_groups with a dict value make
  one group per key; a non-empty group-name prefix defeats `leading_separator: false`. Custom Python
  inventory plugins (`inventory_plugins/<name>.py` next to the playbook, or in
  `ANSIBLE_INVENTORY_PLUGINS`) are NOT reimplemented: `src/krikri/python_inventory_runner.cr` runs the
  user's own plugin file under the controller's `python3` and reads back the hosts, groups and vars it
  populated, the same delegation the custom lookup/filter runners use. Collection inventory plugins
  (azure, gcp, openstack, ...) are unimplemented and follow the cloud modules' rule.
- More of the same "genuinely unimplemented plugin, referenced only in a task this platform never
  actually reaches" class - same root cause each time (this engine's eager parse-time module check
  counts a reference regardless of a gating `when:`, matching real, but the local comparison side has
  the collection installed and never hits the check): `zypper` (`weareinteractive.docker` - SUSE-only)
  and `community.general.clustering.consul.consul_acl` (`mrlesmithjr.consul` - also showing the "WHICH
  TASKS RUN differs" side: Ansible refuses at parse time with zero tasks run, this engine runs the whole
  play first before the same rc=4 - covered by the role-private-custom-modules entry above).
- The legacy free-form `action: "<templated module name> key=val ..."` syntax is implemented (free-form
  string, its `{module: ..., args: {...}}` dict form, and a runtime-templated module name via
  `TaskExecutor#resolve_templated_action`); `weareinteractive.users_oh_my_zsh`'s shape is covered by
  `playbook_parser.cr`'s `ACTION_DIRECTIVE_KEYS` branch.
- `docker_*`'s `api_version:` pin - not implemented, not planned: `docr` uses unversioned endpoint URLs
  throughout, and they negotiate fine against current Docker/Podman. The value is still VALIDATED at
  client construction the way real's vendored SDK does (an unparseable or below-minimum version fails
  the task with real's own message), since that decides whether the task runs at all.
- `containers.podman.podman_container` (issue #1156) - ported surface: the AnsibleModule argument
  validation (1.17.0 spec), main()'s present/created-without-image check, and the
  `get_bin_path(executable, required=True)` probe real runs before ANY state's work, check mode or
  not - so a host without podman fatals the task with real's
  `Failed to find required executable "podman" in paths: ...` (that failure was the whole observable
  divergence; the graceful skip + engine-limit exit 4 it used to get is gone). Everything AFTER a
  successful probe is deliberately unported: the container management behind every state and the
  quadlet unit-file generation (real drives `podman`/writes `/etc/containers/systemd/*.container`).
  The plugin answers a plain ok there, so on a host WITH podman krikri reports ok where real reports
  the real work's changed/ok - revisit if a round lands on a podman-present host.
- `community.general.pacman` (issue #1583) - ported surface: the AnsibleModule argument validation
  (community.general 12.x setup_module spec, required_one_of, mutually_exclusive) and the
  `get_bin_path(executable, required=True)` probe Pacman.__init__ runs before ANY package work,
  check mode included - so a host without pacman fatals the task with real's
  `Failed to find required executable "pacman" in paths: ...` (jpedrodelacerda.yay on Ubuntu used to
  get the graceful skip + engine-limit exit 4 there, which let the play run on past the point real
  stopped). Everything AFTER a successful probe is deliberately unported: the package inventory and
  install/remove/upgrade/update_cache work (real drives `pacman --print-format` against a real Arch
  package database). The plugin answers a plain ok there, so on an Arch host krikri reports ok where
  real reports the real work's changed/ok - out of scope with apt/dnf/yum backends, this engine
  targets Ubuntu and RHEL-family hosts.
- `meta:` - every action in Ansible's `meta` choices list is supported (`clear_facts`, `flush_handlers`,
  `end_host`, `end_play`, `clear_host_errors`, `noop`, `refresh_inventory`, `end_batch`, `end_role`,
  `reset_connection`), each matched to Ansible's observed behavior. Non-obvious ones: `end_play` and
  `clear_host_errors` are genuinely GLOBAL (every currently-active / every-failed host, even one whose
  `when:` skipped the meta task), while `end_host` is per-host only; `clear_host_errors` exempts a host
  from later plays and from the run's exit code but does NOT resume it in the CURRENT play;
  `refresh_inventory` re-reads a dynamic script's output in place but does NOT add newly-discovered
  hosts to the CURRENT play's host loop, only a LATER play's; `end_batch` behaves like `end_play` while
  `serial:` batching isn't modeled.
- `config`/`inventory_hostnames` lookups are implemented; `inventory_hostnames` needed no inventory
  plumbing - Ansible's plugin builds its throwaway InventoryManager purely from `variables['groups']` and
  runs the standard host-pattern machinery over THAT (`ExpressionEvaluator#lookup_inventory_hostnames`,
  spec in `inventory_hostnames_lookup_spec.cr`); `groups` also gained its missing `ungrouped` key.
  Known shared limitation: a wantlist/query list result renders `["a","b"]` in debug msg where real
  prints Python's `['a', 'b']` repr.
- `win_*` filters - Windows-only, irrelevant to this project's targets.
- `community.crypto`'s remaining modules. Implemented: `openssl_dhparam`, `openssh_keypair`,
  `openssl_privatekey`, `openssl_csr`, `openssl_pkcs12` (`action: export`/`parse`), `x509_certificate`
  (providers `selfsigned` and `ownca`) and the info/read-only half (`openssl_privatekey_info`,
  `x509_certificate_info`, `openssl_csr_info`, `openssl_publickey`, `openssl_publickey_info`,
  `get_certificate`) - what the role corpus touching this collection calls. Built on the `openssl` CLI
  rather than the `dirless/x509-crystal` shard, which has no CSR-based issuance. Still unimplemented,
  none seen in a role yet: `luks_device`, the `acme`/`entrust` providers, `openssl_pkcs12` export's
  `encryption_level: compatibility2022`, and the CRL/revocation family - all fail with a clear "not
  supported" message.
- `community.general.vdo` - unimplemented; untestable so far, no real role sets a non-empty
  `vdo_devices`.
- `gluster.gluster.gluster_volume` - unimplemented; causes a cosmetic parse-time task-drop vs. Ansible's
  "skipping" recap line, not a runtime crash.
- `community.general.zypper_repository` - unimplemented; same cosmetic parse-time-drop class, no
  zypper/openSUSE host ever tested.
- `community.general.homebrew`/`homebrew_tap` - unimplemented; reachable in practice via the
  linuxbrew roles (`ctorgalson.linuxbrew`, `markosamuli.linuxbrew`), which then diverge by design:
  krikri skips those tasks, ansible runs them (and the Linux brew path fails on this hardware
  anyway - Homebrew's x86_64 build needs an SSSE3 CPU).
- `community.general.portage` - unimplemented; Gentoo-only, and this engine targets Ubuntu and the
  RHEL family. `fgierlinger.docker` is the role that calls it (issue #1359), and the divergence is
  the documented skip: krikri drops both `portage:` tasks and runs on to the role's `service:` task,
  while real Ansible executes the module, whose own source respawns itself under a hard-coded
  `/usr/bin/python` when the Gentoo python bindings are absent, so it fatals with `[Errno 2] No such
  file or directory: '/usr/bin/python'` on a non-Gentoo host. The unimplemented module keeps the run
  at rc 4 (`unavailable_module_report_test.cr` pins that a later failing task does not downgrade it
  to 2), which is what the role tester reads as COMMUNITY_MODULE_MISSING.
- `ansible.posix.firewalld` - `zone:` defaults to the system default zone (`firewall-offline-cmd
  --get-default-zone`) and Ansible's `permanent`/`immediate`/`offline` validation is matched to Ansible's observed behavior, so
  `offline: true, permanent: true` isn't required explicitly. A running firewalld daemon (auto-detected
  via `firewall-cmd --state`) plus a requested or defaulted `immediate:` change is serviced through
  `firewall-cmd` (the D-Bus client CLI), and a `target:` operation in the immediate context fails with
  the Ansible module's "Zone operations must be permanent..." rather than being silently serviced offline.
  Still unimplemented: bare defaults against a host with no firewalld daemon.

## Plugin key-order probe coverage

`PluginResult#key_order` (or an omit-`changed` wire) pins a plugin's keys to `ansible-playbook`'s own order. The probes below were captured on 2.19.11 controllers; re-probing each family under the 2.21.6 target is still pending (2.21 did change the registered-result wrapper order, which `src/krikri/result_shape.cr` already reproduces). Probes: `testing/keyorder_probes/kop_*` roles, run via `krikri-role-tester run` with `local:` queue entries and compared by `krikri-role-tester keyorder` (`--values` for values, not just shapes). Add to this list when another module family is probed.

### Verified

- `kop_snap`, `kop_iptables`, `kop_apt_fail` (rounds 1100100+): `snap`, `iptables`, `apt` real-mutation/failure shapes.
- `kop_docker_build`, `kop_docker_invalidrepo` (rounds 1600100/1800100, 5331000): `docker_image_build` buildx gate, CLI image lookup, both resolve_repository_name refusals (`http://foo`, `registry.example.com-/thing`), on a real docker.io 26.1.3 + buildx host, byte-identical cold and warm. The refusals escape the module body uncaught and register as `msg: "Task failed: Module failed: <raw text>"` with keys failed/changed/exception/msg.
- Docker plugins: API failures, container start failures, daemon-unreachable wording (SDK and CLI modules) and `docker_network` `ipam_config` verified against community.docker 5.2.1 on a podman socket. TCP-unreachable wording is a deliberate limit (see above).

### Not a gap to close

- `homebrew*`, `ovirt_auth`/`redhat_subscription`/`rhsm_*` (macOS-first, or need a live oVirt engine / Red Hat entitlement; well under 2% of roles).
- `ec2_*`, `iam_user_info`, `nsupdate`, `rabbitmq_*` (need an external account or appliance neither engine can reach).
- Host noise (apt/dnf output text, per-host keys/UUIDs, snap revisions, mount/systemd dependency ordering) is not a krikri difference.

---

For the fixed-bug history (150+ rounds of real-host benchmarking against production
Ansible roles), see `git log`.
