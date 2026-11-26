# 1869 - drew1kun.dnscrypt: deferred loop error's when: failure

Issue: https://github.com/weirdbricks/krikri/issues/1869
Role: `drew1kun.dnscrypt` (round round29928586, krikri 0.9.3157 at 4bd78dba455c)

The role's `tasks/install.yml` finds the dnscrypt-proxy download for the
current architecture by looping over a `uri:` result's `.json.assets` while
its `when:` list dereferences `item`. In check mode the `uri:` task is skipped
(it does not support check mode), so the registered result is a skipped-result
dict with no `json` key: the loop source raises "object of type 'dict' has no
attribute 'json'", and the `when:` list is evaluated against a still-unbound
`item`, which raises too.

ansible-core 2.21.6 keeps the loop-source error deferred
(`_loop_eval_error`) and evaluates the conditional first, DISPLAYING the
conditional's own failure as its own one-record [ERROR] block - clause label,
detail and the failing CLAUSE's Origin - before re-raising the loop error and
printing its block. krikri swallowed that conditional failure entirely, so 295
bytes of the recap tail were missing.

The playbook is the role's failing task, verbatim except for the two vars the
role gets from its defaults plus the skipped-register shape the `uri:` task
would have produced (play vars here, since the role's network call cannot be
part of a corpus case).

Fix: `emit_deferred_loop_when_error_block` (src/krikri/task_executor/
executor_loops.cr) prints the deferred conditional block at both loop
resolution sites, in the one-record shape for a raising conditional and in
2.21.6's chained shape (label + detail + ALLOW_BROKEN_CONDITIONALS hint) for
a non-boolean conditional result.
