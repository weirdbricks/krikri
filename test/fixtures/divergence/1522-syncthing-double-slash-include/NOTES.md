# #1522 - diademiemi.syncthing: doubled slash preserved in the `included:` line

- Issue: https://github.com/weirdbricks/krikri/issues/1522
- Role: `diademiemi.syncthing` (round `logs___1795001446`)
- Class: output gap (path normalization)

**What diverged.** The role's `tasks/setup/always.yml` includes
`setup/common//configure.yml` - a doubled slash. Real prints that path as
written (`.../tasks/setup/common//configure.yml`); krikri normalized it to a
single slash.

**Fixture.** The include task is `tasks/setup/always.yml`'s own task verbatim
(the double slash included), `tasks/main.yml` is trimmed to it, and the
included file keeps the real `configure.yml`'s first task. The rest of
`configure.yml` and `always.yml` install packages and enable services, so they
are dropped. Role defaults carry just the two flags the include is gated on.
