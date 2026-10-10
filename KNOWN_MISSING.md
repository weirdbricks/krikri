# Known Missing / Known Gaps

The goal is 100% behavioral compatibility with `ansible-playbook`, verified against Ansible runs
rather than assumed, for **core (`ansible.builtin`) modules**. A community module explicitly promoted
to supported owes the same bar; a divergence rooted in an **unsupported** one isn't tracked here (see
`krikri-role-tester`'s `COMMUNITY_MODULE_MISSING` classification and `SUPPORTED_COMMUNITY_MODULES`).

This file tracks what's missing **today** - no implementation history, per-round narrative or
root-cause analysis, which live in `git log` (e.g. `git log --all --grep=auth_socket`). When an item
gets fixed, delete its bullet; the fixing commit is the record.

**Open gaps** is defects with an unknown or unfinished fix. **Deliberate limits** is decisions already
made, with the reasoning attached; nothing there is waiting on anyone. An item that stops being a
defect moves down or gets deleted.

**Currently at `0.9.1581`.**

## Open gaps

- **Removed collection modules abort real's play; krikri skips them.** A module removed from a
  collection (kkolk.mssql's `community.windows.win_domain_user`, removal message and all) makes
  real 2.19.11 abort the whole play rc=1 at that task; krikri skips the task and continues, then
  fails later on the role's own undefined `ansible_reboot_pending` conditional. Related shape,
  same class: a module real cannot resolve AT ALL (bare `docker:` with no community.docker on
  the controller, removed `ec2_facts`) refuses the whole playbook at parse time rc=4 while
  krikri - which implements community modules natively - runs on (gbraad.docker-registry,
  JohnPreston.awslogs; the community.crypto precedent from round 2300000 covers the
  host-lacks-the-collection half).
- **Registered-result key order: what is verified and what is not.** `PluginResult#key_order` (or an
  omit-`changed` wire) pins a plugin's keys to Ansible 2.19.11's order. Probes: the
  `testing/keyorder_probes/kop_*` roles, run through `krikri-role-tester run` with `local:` queue
  entries and compared by `krikri-role-tester keyorder` (`--values` for values, not just shapes).
  - Verified by the `kop_snap`, `kop_iptables` and `kop_apt_fail` probes (rounds 1100100+): `snap`, `iptables`
    real mutations and `apt`'s failure/no-op shapes. The one difference left there is host noise: `apt`'s
    `update_cache` retry warnings ("Sleeping for N seconds ...") carry random jitter in Ansible itself, so
    their numbers differ between any two Ansible runs.
  - Not a gap to close: `homebrew*` and `ovirt_auth`/`redhat_subscription`/`rhsm_*` (macOS-first, or
    needing a live oVirt engine / Red Hat entitlement, together well under 2% of roles) and `ec2_*`,
    `iam_user_info`, `nsupdate`, `rabbitmq_*` (need an external account or appliance neither engine
    can reach).
  - Host noise (apt/dnf output text, per-host keys/UUIDs, snap revisions, mount/systemd dependency ordering) is
    not a krikri difference.
- **PostgreSQL:** the deprecated aliases (`port`, `host`, `login`, `unix_socket`, `db`) register
  Ansible's deprecation, connection-failure results use libpq's own wording (byte-identical, including
  every `getaddrinfo` failure code), and `postgresql_query` without a database name warns like real.
  `connect_timeout` (via `connect_params` or `PGCONNECT_TIMEOUT`, task `environment:` first) is verified
  byte-identical against real 2.19.11 on a held listener ("timeout expired", no hint line). A connect to an unroutable
  address (`192.0.2.1`) with a `connect_timeout` set words as "timeout expired" too (probe still pending
  after a fiber-side failure is read as the deadline, not an errno; unit-pinned, and
  re-confirmed on an Atlantic.net host in round 2400002). The live tests
  on port 15432 need a **postgres:16** server.
- **Docker plugins:** API failures, container start failures, daemon-unreachable wording (SDK and CLI
  modules) and `docker_network` `ipam_config` are verified against community.docker 5.2.1 on a podman
  socket. Still different: TCP-unreachable wording embeds a Python heap pointer (unstable even in real).
  `docker_image_build` is verified against real Ansible 2.19.11 + community.docker on a real
  docker.io host (the `kop_docker_build` probe, 7 probes byte-identical): the buildx-plugin gate
  ("Docker CLI /usr/bin/docker does not have the buildx plugin installed", before any daemon call) and
  the image lookup, which real runs through the CLI (`docker image ls`, then `docker image inspect`),
  so a daemon failure surfaces in the CLI run_command shape (`cmd rc stdout stderr failed msg ...`),
  never as an SDK APIError. The one DockerException this module can raise,
  resolve_repository_name's InvalidRepository ("An unexpected Docker error occurred: ..."), is
  unit-pinned (docker_image_build_lookup_test.cr) but not provoked live.
- **`version_type='pep440'` compares with LooseVersion semantics, not PEP-440.** The `version`
  test's `strict=True`/`version_type='strict'|'semver'|'semantic'` schemes (plus every
  validation wording, positional binding and the empty-operand checks) are byte-pinned against
  2.19.11, but packaging's `PEP440Version` (epochs, post/dev releases) is not implemented:
  `version_type='pep440'` falls back to the LooseVersion component scan. No benchmarked role has
  used pep440 yet; it gets implemented on first live hit.
- **Test suite needs a reachable container socket:** the Docker plugin tests (`docker_compose_v2`, the
  `--check` mode Docker end-to-end test) talk to the user's podman API socket. If `podman.socket` is
  "listening" but `/run/user/$UID/podman/podman.sock` is missing (seen after a tmpfiles sweep), restart it
  with `systemctl --user restart podman.socket`. One `statvfs` test can flake under parallel workers
  (passes alone). `docker_image_build`'s nonexistent-`path` test skips where `docker` is podman's shim.

- **Facts-gathering crash with a bare "Index out of bounds"** (ktechmidas.openvpn, round 5210000's
  warm run - after the role changed the host's network state). The gatherer now annotates the
  failing section ("... (while gathering network)") so the next occurrence pinpoints itself;
  root cause pending a recurrence.

## Round 5290000/5291000 (fix-confirm for 4 round-5250000 stragglers + 1 new find, 0.9.1577 -> 0.9.1581, 2026-10-09)

Four fixes landed (each repro'd byte-identical against local ansible-playbook 2.19.11 first,
each with a regression test, all live-confirmed CLEAN on Atlantic.net), plus one disposition:

- 0.9.1577: a bare null `environment:` key was stringified into an empty environment_raw that
  env finalization JSON.parsed and crashed with `unexpected token '<EOF>'` before the task ran;
  real treats a null environment as no environment (lifeofguenter.nginx).
- 0.9.1578: `when:` comparisons rendered a container variable by its literal template text -
  `accounts != ['root']` over `accounts: ["{{ ansible_user_id }}"]` answered True and ran the
  gated task on root; container leaves now render recursively first (l3d.dotfiles).
- 0.9.1579: the task batcher's fact-publishing whitelist was missing six plugins (deploy_helper,
  hostname, mount_facts, virt_net, ec2_metadata_facts, current_container_facts) - over SSH, a
  later batch member's args referencing the fact rendered before the earlier member ran and
  failed with `'deploy_helper' is undefined` (mbaran0v.ansible_role_prometheus_redis_exporter).
- 0.9.1580: a loop_control.label that cannot template now fails the item on the block-skip path
  too - real still templates labels per item under a False block when: and converts the skip
  into that item's FAILED result carrying the chain's false_condition (veselahouba.openvpn;
  closes the Open-gaps edge left by 0.9.1576).
- 0.9.1581 (found BY the 5290000 confirm: the fixed comparison advanced l3d.dotfiles to its
  next task): copy/template with a prefixed relative src (`src: 'templates/vimrc'` living at
  `<role>/templates/vimrc`) never actually opened the role-root candidate its own "Searched
  in:" error listed; the lookup now walks exactly that candidate list (real's _find_needle
  role-root fallback). Confirmed CLEAN on round 5291000.

chris1984.motd dispositioned: real 2.19.11 itself crashes on the role's `motd_content` default
(`item.iteritems()` - a Python-2 dict method - inside the Jinja template), on any py3 host;
krikri succeeds. Broken upstream role, not a krikri bug; emulating real's crash is out of scope.

## Round 5250000-5250356 (357 new Galaxy top-download roles, 0.9.1567 -> 0.9.1576, 2026-10-09)

357 roles never tested before (Galaxy top-download list, deep-paged past the ~6000-role
already-tested frontier): **288 CLEAN, 19 DIVERGENT, 50 Galaxy-missing**. Eight fixes landed
from this round (each with a regression test, each repro'd byte-identical against local
ansible-playbook 2.19.11 before landing), seven of them live-confirmed on Atlantic.net:

- 0.9.1568: a trailing comma in a list literal (`['Debian', 'Ubuntu', ]`) evaluated an empty
  element as the variable `''` and failed the whole conditional (cans.package-install).
- 0.9.1569 + 0.9.1572: the vars lookup now renders the found value like real's templar
  (sscheib.openwrt_extroot's assert loop), and `lookup('vars', x) is defined` on a call operand
  no longer answers a name-existence check (always False for an existing variable).
- 0.9.1570: a variable whose own value is multi-span template text (`{{ playbook_dir }}/x{{
  item }}/y`) was evaluated as an EXPRESSION when read through a `+` operand - its literal `/`
  chars parsed as division - and a mixed-text set_fact value now stores real's Python-repr list
  form, not JSON quoting (opsta.graylog).
- 0.9.1571: with_subelements over a dict source ran the task once with `item` unbound instead
  of iterating the dict's values (veselahouba.ufw).
- 0.9.1573: role-private filter/test plugin dirs of every role LOADED this run join the search
  path (ansible-core's add_all_plugin_dirs at Role.load) - a meta dependency's filters serve
  the depending role (nephelaiio.plugins' sorted_get for nephelaiio.i3).
- 0.9.1574: state=link's relative src is existence-checked against the DEST's directory like
  real, not the module process's cwd (baztian.joplin).
- 0.9.1575: block:/rescue:/always: children inherited a hardcoded ignore_errors=true - a block
  whose ignore_errors resolved False silently ignored member failures and kept executing tasks
  on a host real had already halted (exphost.mysql; the no-context ignore_errors resolution
  sites got the real scope too).
- 0.9.1576: a loop_control.label that cannot template fails the item on module loops like real
  (the veselahouba.openvpn module-loop half).

Confirm rounds: 5260000 (cans.package-install, opsta.graylog, veselahouba.ufw CLEAN;
sscheib.openwrt_extroot still divergent), 5270000 (sscheib.openwrt_extroot, nephelaiio.i3,
baztian.joplin, exphost.mysql all CLEAN), 5280000 (veselahouba.openvpn still DIVERGENT - the
remaining shape is the block-skipped label templating edge in Open gaps).

Dispositioned without a fix: gbraad.docker-registry and JohnPreston.awslogs (real refuses the
playbook rc=4 on unresolvable modules - host-lacks-the-collection / removed-module class, not
a krikri bug), mmagonde.jenkins-swarm (win_* unsupported community modules, by design),
bodsch.influxdb (bodsch.* collections, by design), warhorse.gophish_docker (crystal cold died
in the known plugin-upload UNREACHABLE race; warm CLEAN identical), xanmanning.kubectl (cold
identical; warm kubectl `--short` host-state timing). Still open with root causes noted:
lifeofguenter.nginx (krikri `unexpected token '<EOF>'` on the role's multi-line shell command),
l3d.dotfiles (template for item=root ran here, skipped in real),
mbaran0v.ansible_role_prometheus_redis_exporter (deploy_helper fact not visible after the
module runs), chris1984.motd (real itself
crashes on the role's default - parity would mean emulating real's own crash), kkolk.mssql
(removed-collection-module abort, Open gaps).

## Round 5240000/5241000 (confirm round: 0.9.1540s fixes, flake re-runs, docker_nginx, 2026-10-09)

Ten-role confirm round (five 0.9.1540s fixes + three round-5210000 infra flakes +
clouddrove.ansible_role_docker_nginx), 0.9.1567: **7 CLEAN, 2 py-side infra flakes, 1 queue-file
role-name typo re-run CLEAN as 5241000**.

All five 0.9.1540s fixes are now live-confirmed CLEAN with identical recaps: package-deb install
(rchouinard.mysql-community-repo), hostvars play-magic vars (bilalcaliskan.redis), template
owner/group (gokev.motd-splash), the removed-module exit-1 (sorrowless.prometheus_server and
sorrowless.victoriametrics, rc=1 both engines), and first_found errors=ignore
(lotusnoir.apps_consul_exporter).

The two earlier flake roles flaked AGAIN, but this time on the PYTHON side - strong evidence of
host noise, not engine bugs: mtze.docker_swap_grub's own reboot handler left the py host's SSH
unreachable after reboot (crystal finished cold; 5240006), and bodsch.dnsmasq's py warm run hung
in `apt update` to the harness timeout (rc=124; its COLD run was CLEAN with identical counters).
webarchitect609.php_versions came back CLEAN with identical counters cold and warm (5240007).

clouddrove.ansible_role_docker_nginx: the round-5210000 "wait_for timed out at 305s" divergence
was never a wait_for problem - the role's `with_fileglob: ../templates/config/site.d/*.*`
resolved to NOTHING under krikri (cwd-relative pattern), all four config-transfer tasks skipped,
and nginx ran without its config. Fixed in 0.9.1566 (search-stack dwim, each shape live-verified
byte-identical against 2.19.11); confirm round 5241000 came back CLEAN with identical counters
cold and warm, crystal 9.4s vs py 72.3s cold.

0.9.1565 (same session): the non-boolean conditional error's value origin now covers every
defining layer real annotates - role defaults/vars, vars_files, set_fact values (recorded at
merge time), registered results and gathered facts (real reports the when: token itself for
those), and CLI -e values (`at "<CLI option '-e'>"`) - each shape live-verified byte-identical
against 2.19.11; the layer resolution reuses var_origin_for so a shadowed value is never
mislabeled. 0.9.1567: build.sh links a hidden fmod shim pinning libm's fmod to the pre-2.38
symbol version - the v0.4.31 engine bump's float `%` had made every binary built on this glibc
2.41 machine refuse to start on the Ubuntu 22.04 targets (round 5230000's four instant
ok=0 failed=2 crystal runs were this, not engine bugs; that round is discarded).

## Round 5210000 (357 roles re-run after invalid 5200000, 2026-10-08; per-role triage)

The previous overnight batch (round 5200000, 391 roles) measured nothing: it was launched against a
bare binary copy at `~/scratch/batch5/` with no `bin/plugins/` beside it, so every crystal run died
in ~0.02s with "Plugin binary not found: <module>" (278 rounds; its 69 "CLEAN" were both-engines-
fail-identically parse errors). Re-ran the 357 Galaxy-installable roles with the standard build as
round 5210000: **318 CLEAN, 29 DIVERGENT, 10 Galaxy-missing**.

Fixes landed for 19 of the 29 (git log is the record, each verified against a local
`ansible-playbook` 2.19.11 repro before landing): fail-not-skip for undefined args on unported
modules; the `not(...)` strict-probe false "is undefined" and `when:` slice-index parsing; apt/
apt_repository GPG-failure retry parity plus the `ansible.builtin.sysctl` redirect and
apt_repository's failure `changed=false`; pip proceeding with a null `version:` at `state=latest`;
`package: deb:` actually installing (the deb machinery extracted to a shared `AptDebInstall`);
play-magic vars on every hostvars entry (`group_names` in templates); template: ownership applied
through the resolving helper instead of blind shell-outs; exit 1 (not 4) for a removed module with a
custom removal message; `first_found errors='ignore'` returning None with `length`'s TypeError
wrapped in Ansible's filter-plugin wording. Real-host confirm rounds 5212000/5213000/5216000/
5217000 came back CLEAN for centralpayment.rhel-subscription, rubyisbeautiful.proxy-common,
sdarwin.nagios, artem_shestakov.nginx and rolehippie.mongodb; the later fixes (package deb,
hostvars, template owner/group, rc=1, first_found) are only verified locally/container so far and
still owe a confirm round.

What's left, tracked as bullets in Open gaps: six divergences (facts-gather crash, conditional-on-str
per-item failure, `failed_when:`, copy missing dest dir, docker_nginx readiness timing,
`version(..., strict=True)` kwargs), three suspected infra flakes pending re-run
(mtze.docker_swap_grub, webarchitect609.php_versions, bodsch.dnsmasq), and this round's
`ROLES_TESTED.md` rows (with both engines' cold/warm timings).

Follow-up session (2026-10-08/09, 0.9.1560-0.9.1564): four of the six divergences above are closed.
copy/template's missing dest directory is created like real when the dest is directory-signaled
(0.9.1560, confirmed CLEAN on round 5219000 with Azulinho.azulinho-yum-repo-epel). The
`version(..., strict=True)` kwargs parse is fixed with the full validation matrix byte-pinned
against 2.19.11 (0.9.1561; krikri passes bodsch.icingaweb2's previously-fatal conditional on
rounds 5220000/5221000 - that role's remaining round-level difference is the missing
`bodsch.core` collection real hard-fails on while krikri skips unported collection modules by
design, out of scope). The conditional-on-str split is fixed: an import's when: and the child's own when: are separate strict
conditionals now (0.9.1563; rounds 5222000/5223000 abort the import at the same task on both
engines). The `failed_when:` bullet was a misattribution - a four-case `command:` + `failed_when:`
repro plus the role's own block/rescue shape are byte-identical to real; call_learning.moodle's
divergence is the role-private action-plugin limit. The confirm rounds also found and fixed two
new krikri bugs: a raising changed_when:/failed_when: overwrote the module result's msg where real
records it in changed_when_result/failed_when_result (0.9.1562), and apt_repository's PPA fetch
failures weren't wrapped in real's "failed to fetch PPA information, error was: ..." wording
(0.9.1564, live-confirmed on 5223000's cold run). Two message-only gaps were opened instead
(PEP440 version_type approximated as loose; the missing `at '<origin>'` suffix for role-sourced
values in non-boolean conditional errors). Still owed after this paragraph was written: all of
it got closed by the round 5240000/5241000 confirm round above (docker_nginx's root cause was
the with_fileglob skip, fixed 0.9.1566; the 0.9.1540s fixes confirmed CLEAN; php_versions clean,
the other two flakes re-flaked on the py side; this round's `ROLES_TESTED.md` rows are in).

## Round 2300000 (800 clean roles re-checked, 2026-10-07; per-task status diff)

800 roles drawn at random from the clean rows (no postgres), cold + warm on both engines, static release
build 0.9.1527: 777 CLEAN, 16 DIVERGENT, 7 Galaxy-missing. The harness also diffed per-task
ok/changed/skipping/failed status (not just the PLAY RECAP counters): 79 of 1586 role-phases differed,
most of them diff-script artifacts (list-repr quoting, per-item skip lines, host names in banners). All
16 divergences were traced; the krikri bugs found were fixed and re-confirmed on Atlantic.net
(rounds 2400000-2800000): role-local `test_plugins` (`is list`), `mysql_user` on MariaDB (default
`localhost` -> unix socket, password compare, `USAGE`/`append_privs` diff, `GRANT PROXY`), the `timeout:`
task keyword and `role_path` in static imports inside blocks, `cron` folded `job:`, `synchronize`
pull dest dir, `apt` virtual-package version pin, `lineinfile` terminator handling, per-expression error
markers in task banners and role vars on skipped `always:` children, and the PostgreSQL blackhole
`connect_timeout` wording. Not krikri bugs: `adarnimrod.ca-store`/`apache` (missing community.crypto),
`ansible-pip` (host pip and upstream `get-pip`), both `ubuntu22_cis` roles (900 s cap), `dellos-*`
(unsupported network modules), `fact_inventory` (cold SSH flake), and `andrewrothstein.emacs-build`'s
one cold `dnf` stall (not reproducible in podman with the same commands, treated as a mirror/host flake;
the only ceiling on a stalled package-manager child is the 3600 s transport timeout, above the harness
cap - revisit only if it recurs).

Follow-up fixes found while closing that round out (all re-run on Atlantic.net or against real
`ansible-playbook` 2.19.11 before landing): MySQL 8.0/8.4 `mysql_user` parity (message wording, errno
reconstruction, bare `REVOKE GRANT OPTION` rejected on 8.4); the template-error warning block and banner
markers (an independent 25-case re-verification found the first pass was only 2/25 correct - fixed to
25/25, then a 30-role real-host regression of the evaluator change came back 29 clean + 1 Galaxy
download failure); a mid-play SSH death or auth-phase disconnect is now UNREACHABLE (rc=4) instead of a
failed/skipped task - on the default batch path it had been silently `skipped` with exit 0; connection
passwords without `sshpass` fall back to OpenSSH `SSH_ASKPASS` like real 2.19's default
`password_mechanism`; and tasks inside a block skipped by `when:` print one `skipping` line per loop item.


## Deliberate limits (decided, not defects)

Do not re-litigate without new evidence - and if new evidence turns up, move the entry to
"Open gaps" rather than arguing with the note in place.
### `password_mechanism=sshpass` is not implemented (askpass is always the fallback)

ansible-core 2.19 defaults `password_mechanism` to `ssh_askpass` and only needs the `sshpass` program when
the option is set to `sshpass` explicitly (without it installed, real fails the host with `to use the
password_mechanism=sshpass, you must install the sshpass program`). krikri has no such option: with a
connection password it uses `sshpass -e` when the program exists and otherwise OpenSSH's `SSH_ASKPASS`
(helper in a fresh 0700 directory, password via `SSHPASS` in the environment only), so a play that sets
`ansible_ssh_password_mechanism: sshpass` without `sshpass` installed succeeds here where real fails.
Decided 2026-10-08: lenient direction, not worth emulating.

### `timedout.frame` deprecation warning is not printed

Real ansible-core 2.19.11 prints a stderr `[DEPRECATION WARNING]: The `timedout.frame` task result key is
deprecated` (with an Origin block) when a registered timed-out result is templated. krikri enforces
`timeout:` and matches the result values and key order but does not emit that warning: stderr only, no
effect on task status or stdout. Decided 2026-10-07: not worth matching.


### Console-output differences from ansible-core 2.19.11 that cannot be matched

krikri aims for byte-for-byte identical stdout/stderr/exit code to `ansible-playbook`
2.19.11 (checked with `scripts/output_parity.sh` and the per-module
`krikri-playbook-generator`). The known exceptions:

- Python interpreter-discovery warnings (`Host ... is using the discovered Python interpreter ...`):
  krikri has no interpreter to discover.
- Random per real run: temp file/dir names, string-set order (`union`/`intersect`/... on lists of
  strings), and the order of several invalid options in one error message. Integer set order *is*
  reproduced.
- `community.general.filesystem`'s `value of fstype must be one of: ...` is built by real from a
  Python set of strings, so **Python string-hash randomization** reorders it per process -
  unmatchable by design; the generator masks it (`FSTYPE-SET-ORDER` in masks.cr).
- `-vvv` module-execution mechanics lines (`ESTABLISH LOCAL CONNECTION ...`, `EXEC`/`PUT`,
  `Using module file ...`, `Pipelining is enabled.`): no interpreter, module file or staged tmp dir
  exists here, and those lines embed per-run random `ansible-tmp-<epoch>-<pid>-<random>` paths. Masked
  in `scripts/output_parity.sh`.
- `copy:`/`template:` at `-vvv` carry Ansible's `invocation.module_args` block naming its random staged
  Python module file; krikri emits none (the deterministic check-mode content-copy shape IS
  reproduced). Masked in `scripts/output_parity.sh`.
- Malformed `-e '{...'` JSON: Ansible prints a multi-part stderr chain and exits 4; krikri prints one
  line and exits 1.
- `--version`: Ansible's block names Ansible's version, config file and Python paths - facts a non-Python
  engine cannot truthfully reproduce.
- `--help`/unknown option: Ansible's listing comes from its own option set (including options krikri
  lacks) and an unknown option is argparse's `usage: ...` + `error: unrecognized arguments: ...` with
  exit 2; krikri prints its own usage, exit 1. Matching it would mean embedding Ansible's help text.
- Multi-host task-line ordering: Ansible's order for 2+ hosts comes from hash-randomized set iteration
  and fork scheduling (two Ansible runs already disagree byte-for-byte); krikri uses inventory/pattern
  order, so `scripts/cli_output_parity.sh` runs its execution cases against single-host play
  patterns and sorts the `hosts (N):` block in `--list-hosts`.
- `group_vars/`/`host_vars/` adjacent to the PLAYBOOK: Ansible 2.19.11 does NOT load them (only
  inventory-adjacent ones), krikri loads both, so such playbooks see variables real leaves undefined.
- Quote-soup task arguments (single-quoted Jinja with embedded escaped quotes as YAML quote soup):
  krikri's YAML/arg split keeps backslashes verbatim where Ansible's splitter unescapes them, so both
  "succeed" with different bytes; clean quoting is identical.
- Broken `with_*` loop source (`with_subelements:` missing its subkey term): Ansible fails with the
  lookup-plugin error plus a bare `Origin: <unknown>` / `invoke_lookup()` block; krikri degrades the
  loop to a failed task with the finalization chain.
- `template:` with `output_encoding:` as a YAML list of plain strings (`[a, b]`) reports Ansible's
  `unknown encoding: a,b` instead of the Python type error: the params wire comma-joins such a list,
  making it indistinguishable from STRING `"a,b"`, which real itself reads as a codec name.
- `include_role`/`import_role` with SEVERAL of `defaults_from`/`handlers_from`/`tasks_from`/
  `vars_from` wrong-typed: real picks which to report by Python set order (the same playbook
  alternates), so krikri cannot match it. Masked in `scripts/output_parity.sh` and the generator;
  message text and type still have to match.
- String-list or dict literal where Ansible's module crashes on the type, on a param the wire flattens:
  `debconf` with a plain-string-list or dict `value:`, and the Python `repr` of an all-string list in
  `copy`'s `remote_src` missing-source message. Only non-string scalars and lists with a non-string
  member are reproduced.
- Python-set iteration order in results: `openssl_csr`/`openssl_certificate` `public_key_fingerprints`
  and `postgresql_privs`'s multi-privilege list come from a Python set/frozenset in real
  (nondeterministic across Ansible runs themselves); krikri keeps the declared order. Other
  `ansible-core` releases may differ; 2.19.11 is the reference.

### Differential-fuzz residual leniency between the two Jinja evaluators

- What remains after triaging `bin/differential_fuzz` is deliberate, not defect: two-raw-string and
  numeric-string-vs-number orderings, per-filter argument type leniency (`| sum`/`| abs` on strings,
  `| split(dict)`), the unimplemented `%` modulo, `not (...)` around an unimplemented inner construct,
  bare-callable attributes (`str.count`), and the lenient chain off a lenient undefined for bracket
  indexing (`missing_var[9]` stays the "undefined" sentinel - the load-bearing shape behind
  `x | default(other.thing.y)`). These live as tight predicates in
  `src/krikri/differential_fuzz/runner.cr` (`KNOWN_DIFFERENCES`); the fixed-seed CI slice is
  `test/unit/differential_fuzz_test.cr`.

### Unsafe-data taint is a provenance-closed registry, not an AnsibleUnsafe type

- Real marks host-controlled strings with a type (`AnsibleUnsafeText`) that survives every
  operation; krikri registers the hostile TEXTS in a global registry closed under derivation -
  once a render decision establishes (by resolved name, expression provenance or substring
  containment) that an output was fed by execution data, the transformed output is registered too,
  so every later re-render refuses it by text. Same verdict as the type for every shape tested,
  but structurally approximate: a NEW re-render path must extend the hostile matrix in
  `test/integration/unsafe_data_test.cr`, not be assumed safe.

### `fetch:` refuses a destination that escapes `dest`, stricter than Ansible

- A `src` whose `..` components carry the composed `dest/<host>/<src>` path outside `dest`
  fails with "Detected directory traversal, expected to be contained in ..." instead of writing
  there. Ansible 2.19.11 writes through: its CVE-2019-3828 traversal guard never fires in this case
  (observed behavior). Deliberate: `src` can come from host-controlled data (e.g. `find:` results) and a
  controller-side write outside `dest` is exactly that CVE. Non-escaping paths match real
  byte-for-byte.

### `ansible_version` is pinned to a fixed ansible-core release, not this project's own version

- `ANSIBLE_VERSION_MAGIC_VAR` reports `2.19.4` regardless of which `ansible-playbook` is
  installed on the machine running krikri. Deliberate: version-gated role features expect a
  2.x-shaped comparison target, and this project's sub-1.0 version would make every such min-version
  check fail unconditionally. It will not drift to match whatever is locally installed.

### `aem_design.aem_license`'s `no_log`-vs-fail-hard divergence is a human security judgment call

- A `no_log: true` task masking a license-key value diverges from Ansible in a way that is
  borderline security-sensitive (fail hard vs. silently proceed on a masking edge case), not a
  clear-cut behavioral bug. Deliberately left unfixed - a human should decide, not an automated pass.

### Role-private custom `action_plugin`s are not supported (module execution is; action plugins are not)

- Found via the `amtega.*` Galaxy collection (~28 roles), which depend on `amtega.check_platform`'s
  role-private `action_plugins/_check_platform.py` - a real `ActionBase` subclass running on the
  controller with access to `action_loader`, `templar` and `connection` internals. Role-private
  `library/*.py` custom **modules** already run here; custom **action plugins** are different in kind -
  controller-side Python reaching into Ansible's own plugin-loading/templating/connection APIs, meant
  to run inside a `ansible-core` process rather than be dispatched to a target.
- Supporting them means either embedding a real Python interpreter with equivalent internal APIs or
  building a bespoke API surface with no other use, for an extension point most Galaxy roles never
  ship. Decision: krikri reports the plugin name as an unimplemented module rather than skipping.

### Unimplemented community.general filter long tail (usage-audited, watchlist not backlog)

- Unimplemented: the dict-key filters (`keep_keys`, `remove_keys`, `replace_keys`, `dict_kv`,
  `groupby_as_dict`), the `lists_*` family (`lists_union`, `lists_difference`, `lists_intersect`,
  `lists_symmetric_difference`), `accumulate`, `counter`, `crc32`, `version_sort`, `random_mac`,
  `unicode_normalize`, `from_csv`, `from_ini`/`to_ini`, `from_toml`/`to_toml`, `json_diff`,
  `json_patch`, `hashids`, `reveal_ansible_type`, the `to_<time-unit>` family and `to_prettytable`.
- They ARE reachable by a role (that is how `lists_mergeby` was found), but a Sourcegraph audit of
  public GitHub YAML showed real usage is almost nil: hits are dominated by the collection's own
  docs/tests and third-party tutorial/vendored copies. The only real-role hits were one `version_sort`,
  one `keep_keys`, one `counter` and zero for `dict_kv`/`groupby_as_dict`/`remove_keys`/`replace_keys`/
  `lists_*`, while the same search for `dict2items` matches hundreds of genuine roles. Decision: none
  go in a backlog on spec; each is implemented on first live hit by a benchmark role.
- **ansible-core builtins** are effectively fully covered - the only absent names are `random`,
  `rejectattr` (deliberately excluded from `KNOWN_FILTER_NAMES`), `groupby`, and the Windows-only
  `win_basename`/`win_dirname`/`win_splitdrive`.

### ansible.netcommon IP filters are implemented even where the Ansible host lacks the collection

- krikri implements the `ansible.netcommon` filter family (`ipaddr`, `network_in_usable`, ...)
  natively, so a role using one renders fine here while `ansible-playbook` on a host without the
  `ansible.netcommon` collection installed fatals with `No filter named 'ansible.netcommon.<filter>'`.
  `jtprogru.hosts` is the precedent: such roles diverge BY DESIGN - the collection gap is on the
  Ansible side, and krikri having the filter is not a defect.

### Init systems and package managers

- **`service:` on an upstart host** - detection covers systemd, OpenRC and SysV (Ansible's own branches,
  in its own precedence order), so such a host is never silently driven as SysV, but upstart itself is
  not implemented: its enable path writes an `/etc/init/<name>.override` whose contents depend on the
  initctl version. Fails with a clear "not supported" rather than guessing.
- **`service_facts:` upstart / chkconfig / OpenRC scans** - systemd and SysV (`service --status-all`)
  are implemented and merged Ansible's way; the other three branches are not. On such a host the systemd
  scan still runs and an empty result is correctly reported *skipped*, not as an empty
  `ansible_facts.services` dict.
- **`package:` backends beyond apt/dnf/yum** - detection uses the same path table and priority as
  `ansible_pkg_mgr`, so the module and the fact a role gates on cannot disagree, but only apt/dnf/yum
  have backends; zypper/pacman/apk/pkgng fail by name ("package manager 'pacman' is not supported by
  this engine"). Out of scope: this engine targets Ubuntu and RHEL-family hosts only. apk is doubly
  out of reach - Alpine is musl and this engine's glibc-linked plugin binaries cannot execute there, so
  the upload fails before any module runs; a musl plugin build is the prerequisite, not an apk backend.

### Arbitrary Python

- **Role-private custom `lookup_plugins/*.py` lookups run on the controller**
  (`PythonLookupRunner`): `lookup('name', ...)`/`query('name', ...)` for a plugin the role ships in
  its own `lookup_plugins/` (or the playbook-adjacent one) dispatches to the controller's own python3
  and runs the plugin's `LookupModule.run(terms, variables, **kwargs)`; a lookup plugin's name IS its
  file name, so no introspection pass is needed. Wired into BOTH templating engines separately: the
  hand-rolled `{{ }}` evaluator's `evaluate_custom_python_lookup` and the krikri-jinja side
  (`krikri_jinja_lookups.cr`, which also serves `query()`/`q()`). Unhelpable cases (no python3,
  `ansible` not importable, no `LookupModule` class) degrade to undefined/`[]`; a plugin that RAN
  and raised fails the task with its own error, like real.
- **Arbitrary-Python-module support is scoped to role-private `library/*.py` sources** (plus the
  playbook-adjacent `library/`): a module with a resolvable source RUNS on the target with the
  target's own python3 through the py_module plugin. Still cut: a module reference with NO library
  source anywhere (parse-time warning, and exit 4 for a reachable one - Ansible's own code for refusing
  a playbook it can't resolve a module for) and every THIRD-PARTY COLLECTION module (next bullet),
  which lives inside installed collections rather than in the playbook tree the runner can see. The
  exit-status half stays divergent for source-less modules: WHICH TASKS RUN differs (Ansible refuses at
  parse time and runs nothing; this engine runs the rest of the play), not the exit status a caller
  sees.
- **Third-party COLLECTION modules and filters, same cut** (e.g. the `bodsch.*` author's
  `bodsch.core`/`bodsch.systemd` collections): Ansible runs these as ordinary Python, so a MODULE
  reference reports "unavailable modules" and skips the task while a FILTER reference fails with
  Ansible's own "No filter named 'x'." rather than silently passing the operand through un-filtered.
  Every `bodsch.*` role calls at least one of these, so that author's roles keep diverging by design.

### SELinux security-context relabeling is not implemented

- The `file:`/`copy:`/`template:`/`getent:` family manage Unix mode, owner/group and (where `libacl`
  is present) POSIX ACLs, but not SELinux contexts - krikri carries no `libselinux`/`matchpathcon`
  equivalent and never relabels. On an SELinux-*enforcing* host, Ansible's `file:` can flip `changed`
  based on a context it would fix up even when mode/owner already match. This is the one candidate
  source of `juju4.adduser`'s `~/.ssh` extra-`changed` report, never reproduced with SELinux enabled.
  Accepted scope cut - closing it means vendoring a real SELinux policy query for a single
  unreproduced, host-flavored report.

### Fact caching

- **Only the `jsonfile` backend** (`src/krikri/fact_cache.cr`): by far the most common real-world
  choice, and the only one worth a from-scratch implementation without a client library to lean on.
  `redis`/`memcached` would need real client libraries this project doesn't carry; the built-in
  `memory` backend needs no support at all (this engine's in-run `@facts` store already IS that).
  Revisit only if a real role needs a non-jsonfile backend.

### Templating

- **A tuple-bearing value stored in a var, then `| string`'d later, renders as a bracketed list
  instead of a parenthesized tuple.** Ansible's native-types finalization converts a Python tuple to a
  list at every rendered-output position EXCEPT when `| string` applies Python's own `str()` first;
  krikri replicates that for the inline case (`{{ d1 | dictsort | string }}`), but a tuple crossing
  INTO a var first (`t1: "{{ (1, 2) }}"`) loses its tuple-ness when stored, since krikri's vars
  world is JSON. Recovering that means carrying a real tuple type through the whole vars pipeline,
  for a shape nothing in the role corpus hits.

### `replace:` pattern syntax is checked by a targeted Python-re scanner, not a full re._parser port

`ansible.builtin.replace` compiles `regexp:`/`after:`/`before:` with Python's own `re`
module, outside its `except re.error` - so a pattern Python rejects kills the module ("Task
failed: Module failed: <re.error text>"). PCRE2 (krikri's engine) accepts a superset of Python's
syntax, so krikri runs a left-to-right Python-re scanner over each pattern first
(`plugins/replace.cr`, `PythonPattern`) and translates PCRE2 compile errors to Python's
wording/position where the mapping is exact.

Covered with real-verified messages: the PCRE group-name spellings `(?<name>...)`/`(?'name'...)`
and every other extension char Python rejects (`(?R)`, `(?&`, `(?|`, `(?1`, ...), the inline-flag
section rules, PCRE-only escapes (`\e`, `\z`, `\K`, `\h`, `\G`, `\C`, `\c`, `\o`, `\p`, `\Q`,
`\x{...}`) with the class-context rules for `\A`/`\B`/`\Z`/`\g`, and `\uXXXX`/`\Uhhhhhhhh` (Python
accepts, PCRE2 does not - rewritten to `\x{...}`).

Deliberately left unchecked (they surface with PCRE2's wording inside the same crash wrapper, or
accept where Ansible rejects): `\N{...}` character names; `\8`/`\9` group-reference semantics; `(?P=name)`
resolution and `(?P<>`-shape name errors; Python's semantic inline-flag checks (`(?iLmsxua)`'s
"cannot use 'L' flag with a str pattern", `a`/`u` negation, global-flags placement);
character-class ranges over escapes (`[\d-e]`).

The surrogateescape twin for undecodable bytes under `encoding:` is the private-use codepoint
U+F780+(byte-0x80) rather than Python's U+DC80+(byte-0x80), because PCRE2 aborts a match whose
subject holds raw surrogates; one undecodable byte is one character to the regex either way and the
byte round-trips on write. The collision risk is the one real carries itself, just in a different
range.

### Cosmetic differences (both engines fail; only the wording differs)

These change no outcome and no recap. Listed so they aren't re-reported as bugs, not
because anyone intends to fix them.

- **A `hostvars[host].<missing>` attribute names the wrong type.** Ansible fails with
  `object of type 'HostVarsVars' has no attribute 'x'`; krikri fails the same task (and
  `is defined`/`default()` behave the same) but says `object of type 'dict'`, since each
  host's vars reach the template engine as a plain dict.
- **`version_compare` was removed in ansible-core 2.19**: a role using that filter fails on
  both engines (the role is broken against 2.19 either way), only the wording differs -
  Ansible's `No filter named 'version_compare' found.` vs krikri's
  `unknown filter "version_compare"`.
- **An erroring task NAME prints an inline marker instead of Ansible's warning.** When a task's
  `name:` itself fails to template (e.g. it reads an undefined `_latest_release.json`), Ansible emits
  `[WARNING]: Encountered 1 template error` and the task runs on; krikri runs it too but renders an
  inline `<< error ... >>` banner marker in the task header instead of the warning line. No outcome or
  recap changes (found via `coopdevs.backups_role`).

### Everything else

- **`ansible-playbook`'s CLI flag surface is fully covered by name, and all but one flag is
  behavioral.** `--help` lists every flag ansible-core 2.19.4 does, including its own long
  aliases (`--inventory-file`, `--vault-pass-file`).
  * `-M`/`--module-path` is accepted and ignored, a scope cut rather than an oversight: real searches
    those directories for PYTHON modules while every module here is a compiled binary, and faking it
    would silently look for a same-named compiled binary in a directory of `.py` files this can never
    execute.
  * `--scp-extra-args` extends the scp command lines in `SSHManager#upload_file`/`#download_file`,
    alongside `--ssh-common-args` (which real applies to scp as well - only `--ssh-extra-args` is
    ssh-only). `PluginManager` also falls back to scp for the plugin-binary push when rsync is missing.
  * `--sftp-extra-args` is accepted and inert (nothing here ever invokes `sftp`); `--flush-cache` is
    correct (facts live only in a run-scoped store, so no on-disk cache exists).
  * Short forms match Ansible: `-C` is `--check`, `-D` is `--diff`, `-c` is `--connection`.
    **`-c` previously meant `--check` in this engine and no longer does**, a deliberate breaking change
    so a copied command line behaves the same here. `-d` is kept as an extra alias for `--diff`.
- Cloud provider modules (`amazon.aws`/`community.aws`, `azure_rm_*`) - not implemented, not planned:
  controller-side HTTP calls to a cloud API needing real request signing/auth, i.e. a real API client
  built from scratch, not "another module that shells out to a CLI tool". Revisit only if a specific
  need justifies it. (The inventory half of this is implemented; see below.)
- YAML-defined inventory plugins (`plugin:` sources): `host_list`, `ini`, `yaml`, `constructed` and
  `amazon.aws.aws_ec2` are implemented via `src/krikri/inventory_plugins.cr`; aws_ec2 talks to the real
  EC2 API with SigV4 through the vendored `awscr-signer` shard, credentials from the standard `AWS_*`
  environment variables. Deliberate approximations: default `hostnames` order is `ip-address`,
  `private-ip-address`, `instance-id`; constructed `filters` are AND-combined `key=value` / bare-key /
  `*` / `!`-negation entries, not Ansible's richer condition syntax; keyed_groups with a dict value make
  one group per key; a non-empty group-name prefix defeats `leading_separator: false`. Other collection
  inventory plugins (azure, gcp, openstack, ...) are unimplemented and follow the cloud modules' rule.
- More of the same "genuinely unimplemented plugin, referenced only in a task this platform never
  actually reaches" class - same root cause each time (this engine's eager parse-time module check
  counts a reference regardless of a gating `when:`, matching real, but the local comparison side has
  the collection installed and never hits the check): `zypper` (`weareinteractive.docker` - SUSE-only)
  and `community.general.clustering.consul.consul_acl` (`mrlesmithjr.consul` - also showing the "WHICH
  TASKS RUN differs" side: Ansible refuses at parse time with zero tasks run, this engine runs the whole
  play first before the same rc=4 - covered by the role-private-custom-modules entry above).
- The legacy free-form `action: "<templated module name> key=val ..."` syntax is implemented (free-form
  string, its `{module: ..., args: {...}}` dict form, and a runtime-templated module name via
  `TaskExecutor#resolve_templated_action`); `weareinteractive.users_oh_my_zsh`'s shape is covered by
  `playbook_parser.cr`'s `ACTION_DIRECTIVE_KEYS` branch.
- `docker_*`'s `api_version:` pin - not implemented, not planned: `docr` uses unversioned endpoint URLs
  throughout, and they negotiate fine against current Docker/Podman.
- `meta:` - every action in Ansible's `meta` choices list is supported (`clear_facts`, `flush_handlers`,
  `end_host`, `end_play`, `clear_host_errors`, `noop`, `refresh_inventory`, `end_batch`, `end_role`,
  `reset_connection`), each matched to Ansible's observed behavior. Non-obvious ones: `end_play` and
  `clear_host_errors` are genuinely GLOBAL (every currently-active / every-failed host, even one whose
  `when:` skipped the meta task), while `end_host` is per-host only; `clear_host_errors` exempts a host
  from later plays and from the run's exit code but does NOT resume it in the CURRENT play;
  `refresh_inventory` re-reads a dynamic script's output in place but does NOT add newly-discovered
  hosts to the CURRENT play's host loop, only a LATER play's; `end_batch` behaves like `end_play` while
  `serial:` batching isn't modeled.
- `config`/`inventory_hostnames` lookups are implemented; `inventory_hostnames` needed no inventory
  plumbing - Ansible's plugin builds its throwaway InventoryManager purely from `variables['groups']` and
  runs the standard host-pattern machinery over THAT (`ExpressionEvaluator#lookup_inventory_hostnames`,
  spec in `inventory_hostnames_lookup_spec.cr`); `groups` also gained its missing `ungrouped` key.
  Known shared limitation: a wantlist/query list result renders `["a","b"]` in debug msg where real
  prints Python's `['a', 'b']` repr.
- `win_*` filters - Windows-only, irrelevant to this project's targets.
- `community.crypto`'s remaining modules. Implemented: `openssl_dhparam`, `openssh_keypair`,
  `openssl_privatekey`, `openssl_csr`, `openssl_pkcs12` (`action: export`/`parse`), `x509_certificate`
  (providers `selfsigned` and `ownca`) and the info/read-only half (`openssl_privatekey_info`,
  `x509_certificate_info`, `openssl_csr_info`, `openssl_publickey`, `openssl_publickey_info`,
  `get_certificate`) - what the role corpus touching this collection calls. Built on the `openssl` CLI
  rather than the `dirless/x509-crystal` shard, which has no CSR-based issuance. Still unimplemented,
  none seen in a role yet: `luks_device`, the `acme`/`entrust` providers, `openssl_pkcs12` export's
  `encryption_level: compatibility2022`, and the CRL/revocation family - all fail with a clear "not
  supported" message.
- `community.general.vdo` - unimplemented; untestable so far, no real role sets a non-empty
  `vdo_devices`.
- `gluster.gluster.gluster_volume` - unimplemented; causes a cosmetic parse-time task-drop vs. Ansible's
  "skipping" recap line, not a runtime crash.
- `community.general.zypper_repository` - unimplemented; same cosmetic parse-time-drop class, no
  zypper/openSUSE host ever tested.
- `community.general.homebrew`/`homebrew_tap` - unimplemented; reachable in practice via the
  linuxbrew roles (`ctorgalson.linuxbrew`, `markosamuli.linuxbrew`), which then diverge by design:
  krikri skips those tasks, ansible runs them (and the Linux brew path fails on this hardware
  anyway - Homebrew's x86_64 build needs an SSSE3 CPU).
- `ansible.posix.firewalld` - `zone:` defaults to the system default zone (`firewall-offline-cmd
  --get-default-zone`) and Ansible's `permanent`/`immediate`/`offline` validation is matched to Ansible's observed behavior, so
  `offline: true, permanent: true` isn't required explicitly. A running firewalld daemon (auto-detected
  via `firewall-cmd --state`) plus a requested or defaulted `immediate:` change is serviced through
  `firewall-cmd` (the D-Bus client CLI), and a `target:` operation in the immediate context fails with
  the Ansible module's "Zone operations must be permanent..." rather than being silently serviced offline.
  Still unimplemented: bare defaults against a host with no firewalld daemon.

---

For the fixed-bug history (150+ rounds of real-host benchmarking against production
Ansible roles), see `git log`.
