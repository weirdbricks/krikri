# #1594 - ivansible.cert_cloudflare's include-task vars warn at load, not on execution

- Issue: https://github.com/weirdbricks/krikri/issues/1594
- Role: `ivansible.cert_cloudflare` (rocky host, round `logs___1795085158`, round29918180)
- Class: output gap (missing reserved-name warnings for include statements)

**What diverged.** `tasks/root.yml` carries two `include_tasks:` statements
whose `vars:` define `name` (the account and certificate loops, over
`certbot_acme_accounts`/`certbot_certificates`). ansible-core's
`load_list_of_tasks` builds a variable context with `get_vars(play, task)` for
every include_tasks/import_tasks/import_role statement while it is LOADED, so
both produce

```
[WARNING]: Found variable using reserved name 'name'.
Origin: <WORK>/roles/ivansible.cert_cloudflare/tasks/root.yml:<line>:5
```

before the play starts. The round's play aborted at the role's very first task
(the `cert_base` install, `ansible_lsb` missing on rocky), so neither include
was ever executed - and krikri, which parked those warnings on the Task object
and printed them only when the strategy reached it, printed neither warning.
Real's transcript differed by exactly those two blocks (1483 B vs 1060 B).

**Fixture.** `tasks/root.yml` is trimmed to the two include statements, copied
verbatim, and the role's earlier tasks are replaced by one localhost-safe
`fail:` so the play still stops before them, as it did on the round host (the
real first task needs a full `ivansible.lin_base`/`cert_base` chain and root
privileges, which a corpus case must not touch). `tasks/main.yml` keeps the
real `import_tasks: root.yml` minus its `become: true`, for the same reason.
`account.yml`/`certificate.yml` are unnecessary - neither engine loads them
after the failure. The play is the round's `site.yml` adapted to localhost
with `gather_facts: false`, so the failure does not depend on machine facts.

**Fix.** `src/krikri/playbook_parser.cr` now emits the reserved-name warning for
include_tasks, import_tasks and static import_role task vars at parse time
(unbuffered, since real warns there before the load is aborted by a later
task), leaving only plain tasks and dynamic include_role deferred to
execution, which is where real's `get_vars` call sits for those.
