# hesidoryn.python-coreos: Install python and packages

Extracted by `krikri-role-tester extract-repro` from one divergent round of the
real-host differential run, so the repro replays as a test instead of living in a
closed issue.

- issue: #1641
- role: hesidoryn.python-coreos
- round dir: /home/labros/git_work/krikri-role-tester/logs___1795172676/hesidoryn_python-coreos
- phase: warm (block 4)
- task: Install python and packages
- divergence: task results differ: ansible=[fatal] krikri=[skipping]
- first differing line:

  ```
  ansible: [ERROR]: Task failed: Action failed: non-zero return code
  krikri:  skipping: [localhost]
  ```

- round versions: krikri 0.9.2998, ansible-playbook [core 2.21.6]

## Corpus fit

`expected.out` is real ansible 2.21.6's transcript of `playbook.yml`, captured
with `bin/krikri-capture-case` from this directory:

    bin/krikri-capture-case test/fixtures/divergence/1641-hesidoryn-python-coreos-install-python-and-packages

`inventory.ini` pins the interpreter on the `[local]` host, the only spelling
both engines read alike.

The task is gated: `creates=gate-dangling`. The round's cold phase ran the
role's bootstrap, which fails (ActivePython 2.7.8.10 is a 404 now) but still
links `/opt/bin/python` to the never-installed interpreter, leaving a DANGLING
symlink. On the warm phase:

- ansible: the task re-runs and the script exits non-zero, so the play exits 2
- krikri (before the fix): `skipping:` - its gate matched the link itself and
  let the play exit 0

which is the exit-code half of #1641 (the gate semantics themselves were fixed
with #1648; the cold phase's remaining byte diff is a wget wall-clock
timestamp, output no engine can reproduce byte for byte).

Two adaptations keep the case replayable in-process; both are the same limits
the #1648 case for this role records:

- A symlink cannot be committed to the corpus (the case runners copy a case
  with a recursive copy that follows links, and this one dangles), and the
  round's gate path is a root-owned `/opt/bin/python` a case may not create.
  So the play's first task recreates a dangling symlink (`gate-dangling` in
  its scratch directory) with `script: make_gate.sh`, and the divergent task's
  gate names that. The symlink target is `/opt/python/bin/python`, the round's
  never-installed interpreter.
- `bootstrap.sh` is the role's script with its sudo wget/tar/pip body replaced
  by a fixed failure: the divergence turns on the script RUNNING and exiting
  non-zero, not on how it failed, and the original's transcript (sudo, the
  network, wget timestamps and DNS ordering) can never replay byte for byte.

`roles/hesidoryn.python-coreos/` is the role tree the round ran, so the real
YAML is in the case even when `playbook.yml` only runs the two adapted tasks.
