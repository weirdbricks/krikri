# #1911 - srikalyan.docker: `not in` a null container ran the task

- Issue: https://github.com/weirdbricks/krikri/issues/1911
- Role: `srikalyan.docker` 6.0.1 (round `logs___1795725136`, ubuntu, cold + warm)
- Class: behavioural bug (a task ran on krikri where ansible failed)

**What diverged.** On a host with no `docker-compose` binary the role's
`command: "{{ docker_compose_path }} --version"` exits nonzero with an empty
stdout, so `regex_search` stores a null `docker_compose_current_version`. The
next task's clause is

```
docker_compose_current_version is defined
and (docker_compose_version | regex_replace('v', '')) not in docker_compose_current_version
```

Python's `in` needs an iterable right operand, so real ansible fails the task
with "argument of type 'NoneType' is not iterable" (fatal, recap ok=14
failed=1) and never reaches the delete. Krikri's membership evaluator answered
false for a null container instead, which turned `not in` into true: the
`file: state=absent` task ran (`ok`), then the FOLLOWING task's `|length` gate
died on the same null - a different task, a different error, and a recap
carrying one extra ok.

**Fixture.** The role's `tasks/docker-compose.yml` up to and including the
failing task, copied verbatim; only `docker_compose_path` differs, pointed at
a directory that cannot exist (the role default `/usr/local/bin/docker-compose`
may genuinely exist on a developer box, which would make the probe find a
version and skip the failing clause). Nothing else changes: same probe, same
`set_fact` regex, same folded `when:`, so both the statement Origin and the
clause Origin land on the same columns as the round.

`expected.out` was captured with `bin/krikri-capture-case` from ansible-core
2.21.6 (the corpus's pinned parity target).
