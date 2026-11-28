# Divergence regression corpus

One directory per divergence, replayed by
`test/integration/divergence_corpus_test.cr`. A case pins the **real**
`ansible-playbook` transcript for the role YAML that actually hit the bug, so
the replay compares the whole transcript and fails on EXTRA output exactly as
it fails on missing output. Hand-written `must_include` assertions could only
ever catch the missing half, and the invented YAML often pinned a different
trigger than the role hit - which is why closed divergences kept coming back
("Previously closed as #N").

## Case layout

```
<issue-number>-<slug>/
  playbook.yml     entry playbook; the failing task YAML is the real role's,
                   copied verbatim and only adapted to run against localhost
  roles/           the role (or the trimmed part of it) the YAML came from
  inventory.ini    optional; pins the interpreter on the [local] host (a
                   multi-host issue inventory pins it on every host that runs
                   modules, e.g. 1687/1704)
  flags.txt        optional, one CLI flag per line (e.g. --check)
  env.txt          optional, one NAME=value per line; overrides the harness
                   environment for a case that depends on the RUNNING
                   process's own variables (e.g. a PATH with no rsync)
  always-fail      optional stub transport: an inventory points a dead ssh
                   host's ansible_ssh_executable at it (1681/1687/1688/1704)
  expected.out     real ansible-playbook's transcript, `<WORK>`-normalized
  NOTES.md         issue URL, role, what diverged and why
```

`playbook.yml` + `roles/` are the case's *input*, and so is a helper script
like `always-fail` (a case may not need a live service to reproduce a
transport failure). Everything else must be regenerated from real ansible,
never from krikri's own output. A helper is addressed from the inventory
with a case-relative path (`./always-fail`): the replay and the capture
tool both run the playbook from inside the case's scratch directory.

## Capturing `expected.out`

```bash
bin/krikri-capture-case test/fixtures/divergence/<case>
```

The tool (`./build.sh` builds it; the source is `krikri-capture-case.cr`) copies
the case into a scratch directory, runs the pinned real
`ansible-playbook` there with `HOME` pointed at the scratch tree, and writes
the normalized transcript to `expected.out`. Capture rules:

- ansible-core **2.21.6** is the parity target. This box has it in the
  invoking user's site-packages while `/usr/bin` carries an older 2.19.11, and
  the cases run with `HOME` pointed at their scratch tree - which hides that
  user site-packages. The script therefore pins the 2.21.6 tree on
  `PYTHONPATH` and refuses to capture from anything that does not report
  `core 2.21.6`. Never capture from `krikri-playbook`: that would enshrine the
  bug.
- `env -u ANSIBLE_GATHERING -u ANSIBLE_CACHE_PLUGIN
  -u ANSIBLE_CACHE_PLUGIN_CONNECTION` and `ANSIBLE_NOCOLOR=1`, always - this
  box's `ANSIBLE_GATHERING`/fact-cache env would otherwise change both the
  task list and the facts.
- `PATH` is pinned to the standard system directories, always - a module that
  fails `get_bin_path` names every directory it searched, so the developer
  shell's PATH (this box's carries a random AppImage mount point) would make
  the recording differ from every replay.
- The docker daemon selectors (`DOCKER_HOST`, `DOCKER_CONTEXT`, `DOCKER_CONFIG`,
  `DOCKER_TLS`, `DOCKER_TLS_VERIFY`, `DOCKER_TLS_HOSTNAME`, `DOCKER_CERT_PATH`,
  `DOCKER_API_VERSION`) are cleared, always - they decide which daemon a
  `docker_*` module talks to, so an inherited `DOCKER_HOST` makes a case run
  against a different daemon than its recording (issue #1611: real ansible
  connected to rootless podman during the capture gate and succeeded where the
  recording had failed). Unset, both engines use `/var/run/docker.sock`; a case
  that needs a specific (for example unreachable) socket pins it in its own
  `playbook.yml`'s `environment:`.
- The transcript is **stdout followed by stderr**, captured to separate files
  and concatenated. A `2>&1` capture is not reproducible: python's stdout is
  block-buffered when redirected, so real ansible's stderr lands in one block
  after stdout while krikri's stream is line-buffered and interleaves.
- Normalize the scratch directory to `<WORK>` and, besides that, only the values
  that move between two runs of the SAME engine (each one is a spec in
  `test/unit/divergence_transcript_test.cr`, and each replacement is narrow
  enough that the wording around it still has to match):
  - the ORDER of the `Valid booleans include:` enumeration: convert_bool builds
    it from a Python frozenset, so its iteration order changes with each module
    process (string hash randomization) and two real ansible runs already
    disagree. `DivergenceTranscript` sorts only that list's members;
    membership, quoting and every surrounding word still have to match.
  - command/shell's `start`/`end`/`delta`, which are the module process's own
    clock, so two real runs disagree on them like the two engines do.
  - the stamp in npm's debug-log file name (`$HOME/.npm/_logs/<stamp>-debug-0.log`,
    issue #1970): npm names the log after the moment it started and repeats that
    path in the failure, so the recording could otherwise only pin the wall
    clock of its own capture. The log directory, the `-debug-<n>.log` suffix and
    the message around it are still compared.
- A case whose trigger lives in the RUNNING process's environment rather than in
  the play (issue #1643: the synchronize module's `get_bin_path` probe only fails
  when no rsync is on PATH, and the play's `environment:` keyword reaches only
  the module process) pins it in `env.txt`, one `NAME=value` per line with `#`
  comments allowed. Capture and replay both apply it through
  `Krikri::DivergenceCase.env_overrides`, so the recording and every replay
  agree. Keep the pin absolute and machine-independent (a nonexistent directory
  for "not installed"), never a copy of the developer's PATH.
- A case may not mutate the machine: everything it writes stays inside the
  scratch tree, and `--check`/read-only modules are used wherever the real role
  would touch system state. Cases that genuinely need package/service/crontab/
  pip mutation live in `live/cases.txt` instead.

## Interpreter pin (inventory.ini)

Real ansible prints a `Host ... is using the discovered Python interpreter`
warning that krikri cannot reproduce (it has no interpreter to discover, and
the message's docs URL even differs between the 2.19 and 2.21 spellings). It is
on `KNOWN_MISSING.md`'s unmatchable list, so a case that executes modules ships
an `inventory.ini` pinning the interpreter on the `[local]` host:

```ini
[local]
localhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3
```

That silences the discovery path in both engines and keeps the transcript
machine-independent. The `[local]` host var is the placement both engines
resolve identically - a play-level `vars:` pin is not enough (krikri's implicit
gather only reads host vars and role defaults).

## Adding a case

1. Reproduce the issue locally against real ansible.
2. Copy the role's failing YAML in verbatim (`roles/` + the play that runs it),
   changing only what localhost/scratch paths require.
3. `bin/krikri-capture-case` it, add `NOTES.md`, then add its replay `it` in
   its own file, `test/integration/divergence_cases/<issue>-<slug>.cr`. The
   suite requires that directory by glob, so one case is one file: a branch
   capturing a case never edits a shared list, and two branches landing
   together cannot conflict on it. The suite fails when a case directory has
   no such file or a file names no directory, so nothing is silently skipped.
4. Run `scripts/minitest.sh test/integration/divergence_corpus_test.cr`.
