# hesidoryn.python-coreos: Install python and packages

Extracted by `krikri-role-tester extract-repro` from one divergent round of the
real-host differential run, so the repro replays as a test instead of living in a
closed issue.

- issue: #1648
- role: hesidoryn.python-coreos
- round dir: /home/labros/git_work/krikri-role-tester/logs___1795172676/hesidoryn_python-coreos
- task: Install python and packages (`script: bootstrap.sh creates=/opt/bin/python`)
- round versions: krikri 0.9.2998, ansible-playbook [core 2.21.6]

## Divergence

The task is gated: `creates=/opt/bin/python`. The round's cold phase ran the
role's bootstrap, which fails (ActivePython 2.7.8.10 is a 404 now) but still
`symlink`s `/opt/bin/python` to the never-installed interpreter, leaving a
DANGLING symlink behind. On the warm and `--check` phases:

- ansible: `changed:` (its script action tests the gate with the shell's
  `test -e`, which follows the symlink and reports "does not exist", so the
  script would run)
- krikri: `skipping:` (its gate globbed the path, and `glob(3)` matches a
  dangling symlink via `lstat`)

So the whole task never ran under krikri where ansible re-ran it. The root cause
is the script action's gate semantics, not the network failure: krikri now uses
`File.exists?` on the literal value, matching `test -e` (no globbing, no `~`
expansion either - ansible's script action never runs these through
AnsibleModule).

## Corpus fit

`expected.out` is real ansible 2.21.6's transcript of `playbook.yml` under
`--check` (`flags.txt`), captured with `bin/krikri-capture-case` from this
directory:

    bin/krikri-capture-case test/fixtures/divergence/1648-hesidoryn-python-coreos-install-python-and-packages

`playbook.yml` runs the role the way the round's play did (gather facts, then the
role), so the task banner keeps its `TASK [hesidoryn.python-coreos : ...]`
prefix. `inventory.ini` pins the interpreter on the `[local]` host, the only
spelling both engines read alike.

The trigger needs the dangling symlink at `/opt/bin/python`, a root-owned path a
case may not create (a case never mutates the machine), so this transcript pins
the check-mode verdict for the gated task - `changed:` where krikri used to print
`skipping:` - while the dangling-symlink half is pinned by the script plugin
specs in `test/integration/script_test.cr`.
