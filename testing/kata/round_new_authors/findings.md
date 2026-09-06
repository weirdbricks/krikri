# Round: 120 new-Galaxy-author roles, kata pairs (discovery phase notes)

Do not fix yet - collecting per CLAUDE.md workflow. One-line diagnosis per divergence.

## Divergences found so far

- **0x0i.systemd**: krikri skipped=9 vs ansible skipped=8 (cold+warm both). Diff shows
  krikri drops the role-name prefix on the `meta: flush_handlers`-adjacent
  "Broadcast uninstall signal"/"Flush handlers to ensure uninstall is completed" tasks'
  TASK header, AND appears to count one more of them into recap `skipped`. Likely a
  meta-task recap-counting bug (ansible doesn't count a skipped meta task; krikri does).

- **wezhai.minio** (already tested round160, but new failure mode on Debian trixie):
  ansible unpacks `minio.tar.gz` successfully (unarchive w/ bare relative `src:`,
  no remote_src); krikri fails "Source 'minio.tar.gz' failed to transfer" - looks
  like krikri's unarchive plugin fails to resolve/upload the role-local file that
  ansible finds fine via its default files/ search path. Real, reproducible bug
  candidate (unarchive local-src path resolution).

- **nginxinc.nginx** (already tested clean round159 on Rocky 9.6 - NEW divergence on
  Debian trixie): cold run only, handler `(Handler) Start/reload NGINX` -
  `ansible.builtin.service: state=reloaded` - fails on krikri ("nginx.service is not
  active, cannot reload") where nginx was never started before. Real ansible's
  `service` module treats `state: reloaded` as "start if not running, else reload";
  krikri's service plugin apparently errors instead of starting. Warm run (nginx
  already running) matches exactly on both engines - confirms it's specific to
  reloaded-when-inactive semantics.

- **mbaran0v.ansible_role_prometheus_nginxlog_exporter**: uses
  `community.general.deploy_helper` module, which krikri does not implement
  ("unavailable modules: deploy_helper"). Missing-module gap, not a logic bug -
  low priority to implement just for this one role.

- **ansistrano.deploy**: both engines fail with failed=1 (same count) but for
  DIFFERENT reasons - coincidental, not a real match. Ansible's `synchronize`
  (rsync) task fails because the kata image has no `sudo` binary (environment
  gap, not an engine bug - `rsync-path='sudo -u root rsync'` -> "sudo: command
  not found"). krikri doesn't implement `synchronize` at all ("unavailable
  modules: synchronize"), skips that task, then fails differently one task
  later ("Missing required parameter: cmd") because a var that task depends on
  was never set by the skipped task. Recap skipped counts differ (2 vs 3)
  confirming these are different failure paths that happen to both end
  failed=1. Real gap: `synchronize` module unimplemented.

- **krzysztof-magosa.docker**: both fail (rc=1 vs rc=2) but for unrelated reasons -
  not a real match. Ansible fails at PARSE time: role uses
  `community.general.docker_service`, removed from that collection since 2.0.0
  (broken/outdated upstream role, not an engine bug). krikri gets further (real
  ansible never even runs a task) and fails later at "Add APT key" - its
  `apt_key` plugin shells out to `curl` on the target, which the kata image
  didn't have. **Fixed the image gap**: added `curl gnupg2 unzip ca-certificates`
  to `Containerfile` and rebuilt (`localhost/kata-krikri-systemd:latest`) - this
  was about to cause repeated false divergences across many more roles in this
  same shortlist (curl/gpg/unzip are extremely common role dependencies this
  minimal image never had). The upstream-role brokenness itself remains
  unrelated to krikri; not re-tested since ansible can't get past its own
  removed-module error regardless of image contents.

- **igor_nikiforov.etcd**: real, reproducible krikri correctness bug. Task
  "Create etcd directory structure" loops over dicts and accesses
  `item.data-dir` - real Jinja2/Python parses this as `item.data - dir`
  (subtraction, minus binds tighter than the dict has no such attribute),
  which real ansible-core correctly raises as `AttributeError` on both cold
  AND warm ("object of type 'dict' has no attribute 'data-dir'" - a real
  upstream role bug, faithfully reproduced by ansible every run, non-idempotent
  failure baked into the role). krikri instead resolves the malformed
  expression to `undefined` for 2 of 3 loop items and silently continues,
  completing the ENTIRE play successfully where real Ansible cannot get past
  this task on any run. This is the same "lazy dict-templating" bug class as
  prior fixes (git log: crinja keys-default flip, hyphen-in-key handling) -
  worth a proper fix: `item.data-dir` must raise the same
  attribute/subtraction error real Jinja does, not silently become undefined.

## Matches (no divergence)

- ajsalminen.hosts
- dj-wasabi.zabbix-agent
- igor_nikiforov.docker
- nickhammond.logrotate
- jnv.unattended-upgrades
- ansiblebit.oracle-java

## Galaxy 404 / install failures (not engine bugs)

- elastic.elasticsearch (galaxy role install failed - likely a collection now, not a
  legacy role)

## Progress

Shortlist: testing/kata/round_new_authors/shortlist120.txt (120 roles, new authors only)
Tested so far: 8 (lines 1-8, after the wezhai swap) - see results/<role>/status
Next to run: line 9 onward
