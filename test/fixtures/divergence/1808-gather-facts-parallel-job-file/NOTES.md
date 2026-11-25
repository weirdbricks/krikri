# 1808 - kpg gather_facts (state, happy path)

- Issue: https://github.com/weirdbricks/krikri/issues/1808
- Playbook: `000001-multi-gather_facts-happy` (krikri-playbook-generator,
  seed 1795606213), play `multi-task #1.0`.

## What diverged

The engines printed the same output but left their hosts in different
states: real ansible's (`-`) side carried
`/root/.ansible_async/j<digits>.<digits>` (9196 bytes, 0644) that krikri's
(`+`) did not. The task is a `gather_facts:` with `parallel: true`, and
Ansible's gather_facts action runs its fact module under `async_wrapper`
when `parallel` is truthy: the wrapper writes the finished module result
into the target's async dir, the action polls it with `async_status`
*status* mode, and nothing ever unlinks it (only `mode: cleanup` does).
So the file is a real side effect of the task, not incidental churn - a
later `async_status:` on the reported `ansible_job_id`, or any task that
lists `~/.ansible_async`, sees it.

## What this case pins

The play is the issue's play, with its `gather_facts: true` and the
failing task YAML copied verbatim, only adapted to run against localhost:
the kpg round delegated the gather to a second host this case does not
have, so its `delegate_to:` is the one line dropped (the gather still
runs on the only host there is). Two probe tasks then report the job
file in a jid-independent form: how many files the parallel gather left
in `$HOME/.ansible_async` and their modes. Real ansible prints
`jobs=1 modes=0644`; krikri printed `jobs=0` before the fix. The play's
implicit `Gathering Facts` also keeps krikri on the inventory's pinned
interpreter, so no discovery warning enters the transcript.

The state delta itself cannot live in a corpus case: the file's name
carries async_wrapper's pid and its payload is the host's own facts, so
two hosts can never agree on either. `live/cases.txt` and
`KNOWN_MISSING.md` carry that half (the oracle needs to prune
`~/.ansible_async`, like `~/.ansible`, before judging the state delta).
