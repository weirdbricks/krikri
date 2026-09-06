# Known Issues — 120 new-Galaxy-author roles, kata-pair round (raw findings)

Raw discovery-phase findings from a round testing 120 Ansible Galaxy roles from
authors NOT already covered in `ROLES_TESTED.md`, using local Kata VM pairs
(`testing/kata/`) instead of Atlantic.net. **No fixes applied yet** — this file
is input for a separate fix pass (possibly a different model/session). Each
entry: role, what diverged, root-cause hypothesis, and whether it's a real
engine bug vs. an environment/upstream-role artifact.

Shortlist, per-role logs, and running notes: `testing/kata/round_new_authors/`
(`shortlist120.txt`, `results/<role>/`, `findings.md`).

---

## HIGH PRIORITY: concurrent plugin-upload race corrupts transfers (harness-wide impact)

**FIXED (0.9.770)**: the control-socket directory is now per-process (pid-suffixed), so concurrent processes never race on `ControlMaster=auto` handshakes. See `git log` - the per-host muxing within one process is unchanged.

**This affects every prior and future round that runs krikri-playbook
concurrently against multiple hosts from the same control machine** -
including the existing Atlantic.net "4 pairs in parallel" workflow in
`CLAUDE.md`, not just this kata round. Confirmed real, not host-load noise:

When 2+ `krikri-playbook` processes run at the same time on this control
machine (as any concurrent-pair batch does), uploading the same local plugin
binary (e.g. `bin/plugins/stat`, `bin/plugins/package`) to their different
remote targets intermittently races and corrupts the transfer:

```
fatal: [target]: UNREACHABLE! => {"changed": false, "msg": "Failed to upload
/home/labros/git_work/krikri/bin/plugins/stat to 10.99.11.2:/var/tmp/.krikri-playbook/plugins/stat:
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@", "unreachable": true}
```

(the `@@@@...` looks like raw rsync/scp progress-meter bytes leaking into the
error path). The subsequent `Gathering Facts` task then also fails
("Plugin execution failed on remote") and the whole play is reported
UNREACHABLE.

**Confirmed via isolation, not assumption**: `xanmanning.k3s`,
`sensu.sensu`, and `evrardjp.keepalived` all hit this reproducibly when run
as part of a concurrent batch (2-8 roles at once), on a perfectly healthy
host (9-10GB RAM available, no swap growth) - ruling out resource
contention. Re-running the SAME role **solo** (confirmed via `ps aux` that
no other `krikri-playbook` process was alive) on a **fresh, never-reused**
octet produced a clean result every time, with a real (non-UNREACHABLE)
recap. One retry is not reliably enough to work around it - `xanmanning.k3s`
and `sensu.sensu` both hit UNREACHABLE on a same-batch retry too; only a
fully solo run was clean 3/3 times.

**Root cause hypothesis** (not verified in source, just from behavior): the
plugin-upload code path likely computes/writes something from a shared
location keyed only by plugin name (e.g. a temp file, checksum cache, or
connection-multiplexing artifact) without disambiguating by target host or
process, so two concurrent uploads of the same plugin binary to different
hosts step on each other.

**Impact on this round's methodology**: any `UNREACHABLE` result from a
concurrent batch must be re-verified with a solo run before being trusted as
a real divergence or a real match - `testing/kata/run_role.sh` now retries
up to 3 times with jitter as a stopgap (not a fix) for the rest of this
round. **This also means every prior round using Atlantic.net's "4 pairs in
parallel, don't fix during discovery" workflow may have silently absorbed
some fraction of UNREACHABLE-then-retried-differently results without anyone
tracing them back to this cause** - worth an audit once this is fixed
properly, not urgent to re-verify old rounds retroactively.

---

## Real / candidate krikri bugs

### `riemers.gitlab-runner` — `apt: cache_valid_time:` alone (no `name`) wrongly requires `name`

**FIXED (0.9.770)**: a bare `cache_valid_time: N` now runs the freshness-checked cache pass and early-exits ok, matching apt.py. Verify live on the next round.
Real, reproducible, confirmed solo (clean host, no concurrency). Task:
```yaml
- name: "(Debian) Refresh package cache"
  ansible.builtin.apt:
    cache_valid_time: 3600
```
No `name:`, no explicit `update_cache:`. Real Ansible treats a bare
`cache_valid_time` (no `name`) as a cache-refresh-only invocation and
succeeds (`ok=39/40`, no failures, on both cold and warm). krikri's `apt`
plugin fails: "Missing required parameter: name (unless using
update_cache)" - its argument validation doesn't recognize
`cache_valid_time` alone as sufficient to skip the `name` requirement, only
an explicit `update_cache: true`. **Likely high-impact**: `apt:
cache_valid_time: N` with no `name` is a common idiom for "keep the apt
cache fresh but don't install anything yet" and probably explains some
fraction of other early-task failures seen elsewhere in this round too (an
early apt-refresh task failing outright would cascade into everything
after it never running). Cosmetic bug spotted in the same log: task name
`(item.debuerreotype)`-style dynamic naming rendered as `"debuerreotype-"`
(trailing stray hyphen) instead of ansible's clean `"debuerreotype"`.
Logs: `testing/kata/round_new_authors/results/riemers.gitlab-runner/`
(re-run solo at octets 140/141 after the concurrency-race false positive
above was ruled out).

### `xanmanning.k3s` — real divergence (re-verified solo)

**FIXED (0.9.772)**: `VariableLookup#walk`'s bracket-suffix handling found the closing `]` for an indexed suffix via a plain, non-depth-aware `String#index`, so a key that is itself bracket-indexed (`k3s_service_handler[ansible_facts['service_mgr']]`, this role's own service-manager lookup table) stopped at the INNER close bracket and extracted the malformed `ansible_facts['service_mgr'` (missing its own closing bracket) as the key text, instead of resolving the nested `ansible_facts['service_mgr']` sub-expression first. Real Ansible resolves the whole thing to `systemd` and evaluates the `when:` normally; krikri raised "... is undefined" on the very first task using this idiom, short-circuiting the rest of the role. Fixed with a depth-aware `matching_bracket_close` (mirrors the existing `top_level_char_index` depth tracking). Regression specs: `variable_lookup_spec.cr` (VariableLookup level) and `conditional_evaluator_spec.cr` (the bare `when:` path the role actually hits). Live-reverified on a fresh Kata pair: `ok=8 failed=1 skipped=2` identical on both engines, cold and warm (the one `failed=1` is an unrelated pre-existing environment gap, not re-diagnosed here).
Warm run: ansible `ok=58` vs krikri `ok=5`, both `failed=1`. Cold run:
ansible timed out at 900s (genuinely slow role, real network/download
bound - not itself a bug), krikri failed with `ok=5`. Needs a closer task-
level diff before this is actionable - not done yet, logged here as
"confirmed real, diagnosis incomplete" so it isn't lost. Logs:
`testing/kata/round_new_authors/results/xanmanning.k3s/` (solo re-run,
octets 120/121).

### `igor_nikiforov.journald` — NOT a real divergence (re-verified, 0.9.772)

**RETRACTED**: re-run on a fresh Kata pair against the current build - `ok=1 failed=1` identical on both engines, cold and warm. The original log's extra krikri-only "Gathering Facts... Plugin execution failed on remote" failure was the concurrent plugin-upload race (already fixed 0.9.770, see the HIGH PRIORITY section above) masking what both engines actually agree on: the role's own `journald_config` template var is genuinely undefined (an upstream-role bug, both engines fail identically at the same task with the same message). This entry was logged from a 4-wide batch run before that race was understood as the explanation for exactly this shape of extra failure.

### `kyl191.openvpn` — missing role-name prefix on `|`-named tasks (again) + earlier real failure

**PREFIX PART FIXED (0.9.770)** - same root cause as 0x0i.systemd's missing prefix (recursive role-context propagation). The earlier real failure ("Missing required parameter: cmd" upstream of the firewall check) remains undiagnosed.
Same cosmetic bug as `0x0i.systemd` above: tasks named
`validate | Assert CA CN length (strict mode)` etc. lose their
`kyl191.openvpn :` prefix in krikri's TASK header. Separately, and more
importantly: real Ansible gets much further (`ok=21`, fails late on "No
firewall detected" - an image gap, not an engine bug) while krikri fails
much earlier with "Missing required parameter: cmd" - a different, real,
unresolved divergence upstream of the firewall check. Diagnosis incomplete.
`testing/kata/round_new_authors/results/kyl191.openvpn/`.

**Re-test attempt (2026-09-06) inconclusive - blocked by a local environment gap, not re-diagnosed**: this machine's Kata VMs currently have NO internet egress at all (`net.ipv4.ip_forward=0` and no host-side NAT rule - see `testing/kata/README.md`'s own documented one-time manual prerequisite, confirmed broken via `getent hosts`/`curl` timeouts against 3 independent fresh VMs on unrelated octets). A fresh re-run both cold and warm timed out at ~500-504s on BOTH engines (`ok=5 failed=1`, skipped 16 vs 17) - consistent with both engines stalling on the same network-dependent step rather than a real behavioral difference, but not conclusive either way without working internet. Needs re-verification once the host's NAT/ip_forward prerequisite is restored.

**"Missing required parameter: cmd" FIXED (0.9.773), root-caused after the NAT prerequisite was restored**: the task in question (`server_keys | Generate CA key`) uses `ansible.builtin.command`'s `argv:` list form (`argv: [openssl, req, -nodes, ..., -subj, "/CN={{ openvpn_ca_cn[:64] }}/"]`) instead of `cmd:`/free-form - real Ansible's own alternative for avoiding shell quoting entirely. `plugins/command.cr` never recognized `argv:` as anything but an unsupported parameter (only listed in its own `warn:`-rejection error text, never actually parsed), so every `argv:`-only task failed outright with "Missing required parameter: cmd". Fixed: the plugin now accepts `argv:` as a third alternative to `cmd:`/`_raw_params`, executing its elements literally with no shell splitting at all (`resolve_bracket_index_key`-style dedicated helper, `parse_argv_list`). Also fixed in `playbook_parser.cr`: the generic Array-param path comma-joins list values into a single string, which would have re-corrupted a multi-word argv element like this role's own `-subj` value right back into several arguments - `argv:` now gets the same JSON-encode-then-decode treatment as `assert: that:`/`mysql_query: query:`'s own list params.

Live-reverified against the real role on a fresh Kata pair: krikri now progresses from `ok=5` all the way to `ok=20 failed=1 skipped=30` (warm: `ok=19 failed=1 skipped=31`, BYTE-IDENTICAL to real Ansible's warm recap). The role next hit `No filter named 'netmask_to_cidr'` (`community.general`'s subnet-mask-to-CIDR-prefix filter, used by `openvpn_server_netmask_cidr`'s own default) - **also fixed (0.9.773)**, implemented in the shared `FilterCore` (registered in both evaluators per the usual rule) as a direct popcount-based conversion rather than pulling in a full IP-address library, raising on a non-contiguous or malformed mask the same way real Ansible's `ipaddress.IPv4Network` does.

With both fixed, the role reaches the exact same final failure as real Ansible ("No firewall detected... install one before proceeding" - the pre-existing, documented image gap, not an engine bug) and the cold recap's one remaining count difference (`ok=20` vs real Ansible's `ok=21 ignored=1`) is fully explained by ANOTHER pre-existing documented environment gap: real Ansible's `package_facts` task fails on this image (missing `python3-apt`, the same gap noted for `l3d.gitea` etc.) and is `ignore_errors:`'d, while krikri's own `package_facts` implementation has no such dependency and succeeds outright - both engines then correctly branch differently on `when: __package_gathering_result.failed`, which is the expected, correct downstream consequence of a real upstream difference, not a bug. One residual COSMETIC gap noticed along the way: the missing role-name-prefix issue "PREFIX PART FIXED (0.9.770)" above does not cover this exact task shape - `validate | Assert CA CN length (strict mode)` and `install | Check if CRB repository is enabled` still print without their `kyl191.openvpn :` prefix on this fresh run. Not re-diagnosed further here (purely cosmetic, doesn't affect recap counts).

### `lablabs.rke2` / `rvm.ruby` — same failed=1, unrelated causes (not real matches)
- `lablabs.rke2`: ansible fails on a real upstream role bug
  (`validate_argument_spec`: `object of type 'dict' has no attribute
  'masters'`, faithfully reproduced every run). krikri fails differently/
  earlier: `Error while evaluating conditional: 'groups[rke2_servers_group_name]' is undefined`.
  Two different real errors that happen to both count as one failure - not a
  same-match, needs its own look.
- `rvm.ruby`: ansible's failure was the `sudo` image gap (now fixed, not
  re-tested post-fix). krikri failed separately at an rvm gpg-keyserver
  fetch ("Command failed", `hkp://keyserver.pgp.com`) then later
  "~/.rvm/bin/rvm: No such file or directory" - possibly a real network/
  retry-handling gap in krikri's `command`/gpg-key task, not confirmed.
`testing/kata/round_new_authors/results/{lablabs.rke2,rvm.ruby}/`.

**`lablabs.rke2` diagnosed (2026-09-06), same class as `igor_nikiforov.etcd` below - NOT a drive-by fix**: the role's `meta/argument_specs.yml` default expression `groups[rke2_servers_group_name]` (`rke2_servers_group_name` defaults to the string `"masters"`, and this test inventory has no `masters` group) triggers a genuine Jinja2 quirk in real Ansible - a dict `[]` subscript that raises `KeyError` falls back to `getattr()`, and a plain dict has no `.masters` attribute, so real `validate_argument_spec` raises `AttributeError` immediately while resolving the arg spec's own default. krikri's arg-spec validation doesn't replicate that subscript-falls-back-to-getattr semantic (or the strict-raise-on-default-error behavior) - it resolves the bracket lookup leniently to undefined and passes the task, only failing three tasks later when `groups[rke2_servers_group_name]` is referenced directly in a `when:`. Both engines ultimately fail the role either way; this is the same lenient-vs-strict-undefined design tradeoff already deferred for `igor_nikiforov.etcd`, not a bug with an isolated fix - moved to "Deliberate limits" territory rather than "Open gaps".

**`rvm.ruby` re-test attempt (2026-09-06) inconclusive - blocked by the same broken-Kata-network environment gap as `kyl191.openvpn` above**: with no internet egress, krikri's fresh re-run failed at "Install rvm installer" with `Hostname lookup for raw.githubusercontent.com failed: Temporary failure in name resolution` (confirmed reproducible against 3 independent fresh Kata VMs regardless of role) - this specific failure is the environment gap, not a krikri defect. Real Ansible's fresh re-run failed even earlier, at the role's very first task, with an unrelated `become`/temp-file-ownership pipelining error ("Failed to change ownership of the temporary files Ansible... needs to create despite connecting as a privileged user") - a separate real-Ansible-side quirk when becoming root while already connected as root, also not a krikri-relevant gap. Both fail for reasons unrelated to each other and unrelated to real engine behavior; the original gpg-keyserver-fetch failure noted above may or may not still be real but can't be re-confirmed until the host's NAT/ip_forward prerequisite is restored.

### `evrardjp.keepalived` — NOT a real divergence (re-verified)

**RETRACTED**: re-run against a podman container with working internet (this role's octet in the original round had no internet egress at all - the Kata host-side NAT rule + `net.ipv4.ip_forward=1` documented as a manual one-time prerequisite in `testing/kata/README.md` wasn't set up when this round ran, so `apt-get install keepalived` silently had nothing to install and krikri's own `Output keepalived version` task correctly failed with "No such file or directory" - a real, correct failure given the actual on-disk state, just for an unrelated reason). With internet available, both engines install keepalived fine and reach the exact same task - `ok=12 failed=1 skipped=21` on both, both failing at "Ensuring keepalived is enabled and started" with the identical message ("Job for keepalived.service failed because a timeout was exceeded") - a container/VM VRRP-networking limitation (not an engine difference). Confirmed match, not a krikri bug.

### `0x0i.systemd` — meta-task recap-counting + missing role-name prefix

**FIXED (0.9.770)**: propagate_role_context now recurses into block/rescue/always children (skipped-block banners keep their `role : ` prefix), and a skipped meta: task prints its `skipping:` line but is no longer counted in the PLAY RECAP. Regression spec: `test-block-skip-prefix.yml`.
Cold AND warm: krikri recap `skipped=9` vs ansible `skipped=8` (all else equal:
`ok=4 changed=0 failed=0`). Diff of task-level output shows krikri's TASK
header for "Broadcast uninstall signal" / "Flush handlers to ensure uninstall
is completed" drops the `0x0i.systemd :` role-name prefix that real Ansible
keeps, and krikri appears to count one of these into `skipped` where ansible
does not. These read like `meta:`-adjacent tasks (flush_handlers point) —
likely ansible does not count a skipped meta task in PLAY RECAP, and krikri
does. Logs: `testing/kata/round_new_authors/results/0x0i.systemd/`.

### `wezhai.minio` — `unarchive` can't resolve a bare relative `src:`

**FIXED (0.9.770)**: the executor's unarchive staging resolves a bare relative src against the role's `files/` dir (reusing resolve_script_path) and stages it for remote targets / hands local connections the absolute path. End-to-end regression spec with a real tarball: `test-unarchive-role-files.yml`. Verify live on the next round.
Task `unarchive: src: "{{ package_name }}"` (no `remote_src`, no explicit
`files/` prefix) — real Ansible finds and transfers the role's local
`files/minio.tar.gz` fine (`changed`, then unpacks). krikri fails: "Source
'minio.tar.gz' failed to transfer". This role was previously marked "not an
engine bug" in `ROLES_TESTED.md` (round 160, Rocky 9.6) because BOTH engines
failed there for an unrelated reason (missing `tar` on that image, masking
this path-resolution gap). On Debian trixie (which has `tar`), the real gap
surfaces: krikri's `unarchive` plugin doesn't search the role's `files/`
directory the same way Ansible's default `unarchive` action-plugin does for a
bare relative `src:`. Logs: `testing/kata/round_new_authors/results/wezhai.minio/`.

### `nginxinc.nginx` — `service: state=reloaded` fails when service isn't already active

**FIXED (0.9.770)**: `state: reloaded` now starts an inactive service and reloads a running one, matching real Ansible's service module. Verify live on the next round.
Cold run only (warm matches exactly). Handler `(Handler) Start/reload NGINX`
(`ansible.builtin.service: name=nginx state=reloaded enabled=true`) fails on
krikri: "nginx.service is not active, cannot reload." Real Ansible's `service`
module treats `state: reloaded` as "start it if it isn't running, otherwise
reload" — it does NOT require the service to already be active. krikri's
`service` plugin appears to hard-require an already-active service for
`reloaded` and errors instead of starting it. This role was previously clean
in round159 on Rocky 9.6 — Debian trixie's fresh-boot (nginx never started
before) is what exposes it; Rocky's run must have had nginx already active by
that point in the play. Logs: `testing/kata/round_new_authors/results/nginxinc.nginx/`.

### `igor_nikiforov.etcd` — `item.data-dir` silently becomes `undefined` instead of raising

**DIAGNOSED (0.9.770), not fixed - design decision**: the logs show the failing expression is actually `etcd_config['data-dir']` (bracket access on a dict MISSING that key) inside the `loop:` - not hyphen parsing. Real Ansible raises (module-arg/loop templating is strict-undefined); krikri renders the "undefined" sentinel and continues - the deliberate, pervasive leniency documented at the top of `variable_substitutor.cr`. Matching real Ansible here means tightening strict-undefined for loop items and module args, a wide-blast-radius behavior change that needs its own decision + real-host validation, not a drive-by fix.
Real, reproducible correctness bug, both cold and warm. Task "Create etcd
directory structure" loops over dicts and does `item.data-dir`. Real Jinja2
parses `.data-dir` as `item.data - dir` (attribute access binds tighter than
the following `-`, but `dir` is then read as a bare variable name and
subtracted) — since `item` (a dict) has no `.data` attribute, real Ansible
raises `AttributeError` every single run: "object of type 'dict' has no
attribute 'data-dir'" (a genuine upstream-role bug, non-idempotent by
construction — real ansible fails cold AND warm identically). krikri instead
resolves the malformed expression to `undefined` for 2 of the 3 loop items
and continues, completing the ENTIRE play successfully (`rc=0` warm) where
real Ansible can never get past this task. This is the same class of bug as
prior "lazy dict-templating" fixes noted in `git log` (crinja keys-default
flip, hyphen-in-key handling) — worth checking both evaluators
(`ExpressionEvaluator` and `Crinja`) for how a dotted-with-hyphen expression
against a `Hash`/dict is parsed. Logs:
`testing/kata/round_new_authors/results/igor_nikiforov.etcd/`.

---

## Missing modules (feature gaps, not logic bugs)

- `community.general.deploy_helper` — used by
  `mbaran0v.ansible_role_prometheus_nginxlog_exporter`. Real Ansible succeeds
  end to end; krikri reports "unavailable modules: deploy_helper".
- `synchronize` (rsync wrapper, `ansible.posix.synchronize` /
  `community.general` alias) — used by `ansistrano.deploy`. Both engines end
  up `failed=1` in this run, but for UNRELATED reasons (see below) — this is
  not confirmation the module works elsewhere; treat "synchronize
  unimplemented" as the standing gap regardless of this coincidence.

---

## Environment / harness artifacts (fixed or noted, not krikri bugs)

- **Kata test image was missing `curl`/`gnupg2`/`unzip`/`ca-certificates`.**
  Caused a real-looking divergence on `krzysztof-magosa.docker` (krikri's
  `apt_key` plugin shells out to `curl` on the target; ansible got a
  different, earlier, unrelated failure so never reached that task). **Fixed**
  by adding those packages to `testing/kata/Containerfile` and rebuilding the
  image mid-round — this would otherwise have caused repeated false
  divergences across the rest of this shortlist, since curl/gpg/unzip are
  extremely common role dependencies a minimal systemd+openssh+python3 image
  doesn't have.
- Kata image was also missing `sudo` (many roles' `become:`/shell tasks
  invoke it directly). Caused `rvm.ruby`'s ansible-side failure ("sudo: not
  found") to be a coincidental environment failure rather than a real
  comparison point. **Fixed**: added `sudo` to `Containerfile`, rebuilt.
- The user's shell has `ANSIBLE_CACHE_PLUGIN=community.general.pickle` +
  `ANSIBLE_GATHERING=smart` + a persistent fact cache at
  `/tmp/ansible_facts_cache`, keyed by inventory hostname. Every fresh Kata VM
  in this harness reuses the hostname `target`, so real ansible-playbook's
  *warm* run was silently skipping fact-gathering using STALE cached facts
  from the previous role's VM — a pure harness artifact, not an engine
  difference. **Fixed** in `testing/kata/run_role.sh`'s `run_ansible()` by
  explicitly overriding `ANSIBLE_CACHE_PLUGIN=`, `ANSIBLE_CACHE_PLUGIN_CONNECTION=`,
  `ANSIBLE_GATHERING=implicit` for every real-ansible invocation in this
  harness.

---

## Same failure, different (unrelated) root cause — not real matches

These both end up "failed" on both engines with plausible-looking similar
recap shapes, but tracing the actual failing task shows the two engines fail
for entirely unrelated reasons — recorded here so nobody later treats them as
confirmed-matching:

- **`ansistrano.deploy`**: ansible's `synchronize` (rsync) task fails because
  the Kata image has no `sudo` binary (`rsync-path='sudo -u root rsync'` →
  "sudo: command not found" — an environment gap, would likely fail
  identically for krikri too if it implemented `synchronize` at all). krikri
  doesn't implement `synchronize`, skips that task ("unavailable modules:
  synchronize"), then fails one task later with "Missing required parameter:
  cmd" because a variable the next task depends on was never set by the
  skipped task. Recap `skipped` differs (2 vs 3), confirming different paths.
- **`krzysztof-magosa.docker`**: ansible fails at PARSE time — the role uses
  `community.general.docker_service`, removed from that collection since
  2.0.0 (broken/outdated upstream role, unrelated to krikri). krikri gets
  further (parses fine, runs several tasks) and fails later at "Add APT key"
  — see the curl fix above; not re-tested post-fix since ansible can never
  get past its own removed-module error regardless of image contents, so
  there's no clean two-engine comparison possible for this role at all.

---

## Galaxy 404 / install failures (not engine bugs, no comparison possible)

- `elastic.elasticsearch` — `ansible-galaxy role install` failed (likely
  republished as a collection, not a legacy standalone role anymore).
- `wpninfra.fluent_bit` — `ansible-galaxy role install` failed.

---

## Clean matches so far

`ajsalminen.hosts`, `dj-wasabi.zabbix-agent`, `igor_nikiforov.docker`,
`nickhammond.logrotate`, `jnv.unattended-upgrades`, `ansiblebit.oracle-java`,
`ansistrano.rollback`, `ahuffman.resolv`, `ansible-ThoTeam.nexus3-oss`,
`mbocquet.tmpfs` (confirmed match once re-run outside a concurrent batch —
see the plugin-upload race section above), `sensu.sensu` (same — confirmed
match solo).

---

## Progress

24 / 120 roles run as of this note (some required a solo re-run to rule out
the plugin-upload race above before their result could be trusted). Stepped
back down from 8-wide to 4-wide concurrency after confirming 8-wide degrades
the host in a way that doesn't fully recover even once concurrency drops
back down (swap stayed pinned near its 8GB ceiling for a long time after).
4-wide is what's actually reliable on this box. Any `UNREACHABLE` result
from here on gets a solo re-run before being trusted (the harness itself now
retries up to 3x with jitter as a stopgap — see above — but a solo re-run is
still the real confirmation). Remaining roles:
`testing/kata/round_new_authors/shortlist120.txt` from line 25 on.
