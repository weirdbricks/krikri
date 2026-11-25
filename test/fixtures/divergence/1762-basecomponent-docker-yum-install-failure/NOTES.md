# #1762 - basecomponent.docker: the failed `yum install` block's bytes differ

- Issue: https://github.com/weirdbricks/krikri/issues/1762
- Role: `basecomponent.docker` (rocky host, round `logs___1795546590`)
- Class: output gap (the failing task's captured stdout)

**What diverged.** The role's `install docker packages` task is a plain
`shell:` running `yum  install -y --setopt=obsoletes=0 docker-ce-17.03.*
docker-ce-selinux-17.03.*` (two spaces after `yum`, as the role writes it),
which exits 1 on a Rocky host because the pinned 17.03 packages no longer
exist. Both engines render that failure identically - the same `cmd` string,
`changed: true`, `rc: 1`, the generic msg, the command's own
`stderr`/`stderr_lines`, and the full command-module key set - but the compared
blocks still differed, 1139 B on each side. The differing bytes are inside the
command's own stdout: `Docker Repository     <N> kB/s |  15 kB     00:00` on the
cold run, `Last metadata expiration check: 0:00:<N> ago on <date>` on the warm
one. That rate and age are dnf's measurement of the host's own metadata fetch,
so the two engines' separate hosts - and two runs of real ansible - can never
agree on them (they are recorded as host-timing noise in KNOWN_MISSING.md).

**What this fixture pins.** The task's failure shape, with `bin/yum` standing
in for dnf so the run is reproducible on any host: the verbatim role command
(docker_package/docker_version inlined from the role's defaults), the exact
`cmd` text including the role's double space, `changed: true` with rc 1, the
generic msg, and the command's stdout/stderr carried into both the raw fields
and their `*_lines` split. `expected.out` was captured with
`bin/krikri-capture-case` from real ansible-core 2.21.6.

**Normalization.** A printed command result carries `start`/`end`/`delta`,
whose values are the wall clock at each engine's own run moment; the corpus
transcript now masks exactly those three values as `<TIME>` (the spelling the
round harness uses) so a case containing a command result is expressible at
all. Keys, quoting and formats still have to match byte for byte.
