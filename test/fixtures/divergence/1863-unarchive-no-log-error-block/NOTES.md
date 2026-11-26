# #1863 - drew1kun.dnscrypt: a failed no_log download loses its [ERROR] block

- Issue: https://github.com/weirdbricks/krikri/issues/1863
- Role: `drew1kun.dnscrypt` (rocky), round `logs___1795714389`
- Class: output gap (fatal error block)

**What diverged.** The role's `Download dnscrypt-proxy version: 2.0.17` task
(`ansible.builtin.unarchive` with a remote `src`, `no_log: true`) fetches a
GitHub release asset that 404s. Real prints a `[ERROR] Task failed:` /
`Origin:` block naming the download failure above the censored per-item
line; krikri printed only the censored line, so the operator lost the only
explanation of why the download failed.

**Why.** `Krikri::ResultDisplay`'s no_log path suppresses ansible's uncensored
`[ERROR]` block on purpose (the upstream display leaks a no_log task's data,
issue #271) and only prints it for messages ansible itself composes as fixed
text. `Failure downloading <url>, <detail>` is urls.py's `fetch_file`
wording - real's own - and it is what a failed remote download reports, so
the gate now allows it (live-verified vs 2.21.6, both the 404 shape the round
hit and the connection-refused shape this fixture pins).

**Fixture.** The role's task copied verbatim, adapted to localhost: the asset
URL points at a closed loopback port instead of GitHub (no network; port 1
is never listening and the wording carries no timing), `dest` is the case's
own scratch directory, and the role's two `notify:` handlers are dropped
(the case runs no handlers). The trigger is the same exchange property as
the round: a remote `src` whose download fails under `no_log`.

The block-5 divergence the same round reported (the GitHub API probe's
`content_length` field) is its own case, `1863-uri-gzip-content-length`.

`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6.
