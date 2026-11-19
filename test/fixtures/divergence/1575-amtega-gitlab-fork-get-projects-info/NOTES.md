# amtega.gitlab_fork: Get projects info

Extracted by `krikri-role-tester extract-repro` from one divergent round of the
real-host differential run, so the repro replays as a test instead of living in a
closed issue.

- issue: #1575
- role: amtega.gitlab_fork
- round dir: /home/labros/git_work/krikri-role-tester/logs___1795043292/amtega_gitlab_fork
- phase: check (block 4)
- task: Get projects info
- divergence: bytes differ (441 B ansible, 175 B krikri)

The case runs the round's own role: `amtega.gitlab_fork`'s meta dependency on
`amtega.gitlab_projects_fact` passes `gitlab_projects_fact_server` the value
`{{ gitlab_merge_request_server }}`, which nothing in the round defines, and the
dependency's task fails first - under `--check` (flags.txt) exactly as in the
round. `roles/` carries both role trees the round ran.

## Why the two sides differed

The dependency's `action_plugins/gitlab_projects_api_rest.py` reads that var
through `self._templar.template(...)`, so real ansible raises
`AnsibleUndefinedVariable` there; the plugin's own `except:` handler then reuses
a local it never assigned (`result`), which is the UnboundLocalError both the
fatal msg and the error block report - even though `no_log: true` censors the
result dump.

krikri used to hand the plugin the raw `{{ ... }}` text (no real templating), so
nothing failed at that line and the plugin died later with its own
`KeyError: 'url'`, rendered in krikri's own "custom action plugin ... failed"
wording with no `[ERROR]` block under `no_log`.

## Expected transcript

`expected.out` is real ansible-playbook 2.21.6's full transcript for this
directory, captured with:

    bin/krikri-capture-case test/fixtures/divergence/1575-amtega-gitlab-fork-get-projects-info

It pins the `[ERROR]: Task failed: cannot access local variable 'result' where
it is not associated with a value` block with its `Origin:` excerpt and
`<<< caused by >>>` section above the censored fatal line. Never regenerate it
from krikri's own output.
