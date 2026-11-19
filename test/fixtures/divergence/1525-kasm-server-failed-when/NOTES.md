# #1525 - monolithprojects.kasm_server: failed_when beats the module message

- Issue: https://github.com/weirdbricks/krikri/issues/1525
- Role: `monolithprojects.kasm_server` (round `logs___1795001446`, check phase)
- Class: output gap (error text)

**What diverged.** The role's guard task is `debug: msg="kasm_package is
required"` with `failed_when: kasm_package is not defined`. Real reports the
FAILED_WITH keyword - `Action failed: A 'failed_when' expression evaluated to
'True'.` - with the module's message in the fatal dump; krikri reported the
module's message (`Action failed: kasm_package is required`) as the task
error, so both the [ERROR] block and its Origin differed.

**Fixture.** The role's `tasks/main.yml` first task verbatim; the
`include_tasks:` chain below it needs the package install and is dropped. Run
in `--check` mode as the round did (`flags.txt`), so nothing is installed even
if the guard were skipped.
