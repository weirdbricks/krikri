# totaldebug.users: "Get all users from device" fails on a null getent key

- issue: #1849
- role: totaldebug.users (ubuntu)
- round dir: /home/labros/git_work/krikri-role-tester/logs___1795686235/totaldebug_users
- phase: cold and warm (block 6)
- task: Get all users from device
- divergence: task results differ: ansible=[ok] krikri=[fatal]

## Why it diverged

The role asks getent for the WHOLE passwd database by passing `key:` with no
value. Ansible's getent.py reads the option with `module.params.get('key')`,
which is `None` both when the play omits the option and when it passes an
explicit YAML null, so it runs `getent passwd` and enumerates. krikri's plugin
read the null as the empty string (see `explicit_null_param?`) and ran
`getent passwd ''`, whose rc 2 became "One or more supplied key could not be
found in the database." - failing the task, skipping the ten tasks after it and
ending the play with exit code 2 instead of 0.

The same `module.params.get()` semantics apply to `split` and `service`: a null
split is not the empty string the 2.21 guard rejects, and a null service must
never reach the binary as `-s ''` (which crashes it, rc 139).

## The case

`playbook.yml` is the role's failing task copied verbatim from
`tasks/main.yml`; only the play around it is adapted to run against localhost.
The task only reads the passwd database, so the case runs in-process.
