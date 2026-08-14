# Roles Tested

Real-host `crystal-ansible`-vs-`ansible-playbook` correctness rounds run so
far, and each role's **current** status (not what was fixed to get there —
see `KNOWN_MISSING.md` and `git log` for that history). Check this before
picking a shortlist for the next round, to avoid re-discovering Galaxy-404s
or already-clean roles as if they were new.

| Role | Status |
|---|---|
| dev-sec.os_hardening | ✅ Clean (re-verified 0.9.253, after fixing `with_flattened:` alias unrecognized, literal/filter-chain loop sources dropped, and `in` against a dotted-path container) |
| konstruktoid.hardening | ⚠️ Not re-verified this round — locked itself out of SSH mid-run on the real-ansible-playbook baseline host (port 22 closed, ICMP still responding); confirmed not crystal-ansible-side (only the python host was affected), not chased further |
| linux-system-roles (various) | ✅ Clean |
| geerlingguy.docker | ✅ Clean |
| geerlingguy.mysql | ✅ Clean |
| geerlingguy.postgresql | ✅ Clean |
| geerlingguy.nginx | ✅ Clean |
| geerlingguy.php | ✅ Clean |
| geerlingguy.security | ✅ Clean |
| openstack.ansible-hardening | ✅ Clean |
| githubixx.ansible_role_wireguard | ✅ Clean |
| ansible-community.ansible-vault | ✅ Clean |
| cloudalchemy.prometheus | ✅ Clean |
| cloudalchemy.grafana | ✅ Clean |
| geerlingguy.haproxy | ✅ Clean |
| geerlingguy.certbot | ✅ Clean |
| geerlingguy.redis | ✅ Clean |
| geerlingguy.postfix | ✅ Clean |
| geerlingguy.apache | ✅ Clean |
| geerlingguy.nodejs | ⚠️ Clean on the engine; final install step blocked by an external NodeSource/apt repo inconsistency (reproduces on real ansible-playbook too) |
| geerlingguy.jenkins | ✅ Clean |
| geerlingguy.elasticsearch | ✅ Clean |
| geerlingguy.memcached | ✅ Clean |
| geerlingguy.rabbitmq | ✅ Clean |
| geerlingguy.nfs | ✅ Clean |
| geerlingguy.ntp | ✅ Clean |
| geerlingguy.node_exporter | ✅ Clean |
| geerlingguy.firewall | ✅ Clean |
| geerlingguy.pip | ✅ Clean |
| geerlingguy.munin | ✅ Clean (after fixing `community.general.htpasswd`, previously unimplemented) |
| geerlingguy.samba | ✅ Clean |
| geerlingguy.supervisor | ✅ Clean (re-verified 0.9.253, byte-identical config, idempotent, `supervisorctl status` functionally authenticates with the `hash`-filter password) |
| geerlingguy.htpasswd | ✅ Clean (after fixing `community.general.htpasswd`, previously unimplemented) |
| geerlingguy.clamav | ✅ Clean (after fixing `.find(substring)` string method, missing from `VariableLookup`) |
| geerlingguy.kibana | ✅ Clean (re-verified 0.9.253, byte-identical config, idempotent) |
| geerlingguy.logstash | ✅ Clean (after fixing the `to_json` filter and `chdir=`/etc. with a templated, space-containing value) |
| geerlingguy.gitlab | ✅ Clean (after fixing handler `register:`/`changed_when:`/`failed_when:`, entirely unapplied, and the `bool` filter's keyword semantics) |
| geerlingguy.munin-node | ✅ Clean |
| geerlingguy.adminer | ✅ Clean (incl. its `geerlingguy.apache` config-writing path, functionally verified via `curl`) |
| geerlingguy.varnish | ❌ Not testable — role's own packagecloud.io apt repo has no valid Release file for Ubuntu jammy (reproduces on real ansible-playbook too) |
| geerlingguy.php-mysql | ❌ Not testable — role's own repo ships no `vars/Debian.yml` at all (reproduces on real ansible-playbook too) |
| geerlingguy.mongodb | ❌ Not testable — role no longer exists on Ansible Galaxy |
| geerlingguy.consul | ❌ Not testable — role no longer exists on Ansible Galaxy |
| geerlingguy.golang | ❌ Not testable — role no longer exists on Ansible Galaxy |
| geerlingguy.registry | ❌ Not testable — role no longer exists on Ansible Galaxy |
| geerlingguy.n8n | ❌ Not testable — role no longer exists on Ansible Galaxy |
| geerlingguy.k3s | ❌ Not testable — role no longer exists on Ansible Galaxy |
| geerlingguy.puppet | ❌ Not testable — Puppet Labs' own published apt GPG key is expired (reproduces on real ansible-playbook too) |
| geerlingguy.phpmyadmin | ❌ Not testable — role version 1.3.3 uses `include:`, removed entirely from current ansible-core (real `ansible-playbook` refuses to parse the role at all); crystal-ansible still supports the legacy directive and runs further, but then hits the already-documented `geerlingguy.mysql` → crystal-mysql `unix_socket`/`auth_socket` auth gap, not a new issue |
| geerlingguy.git | ✅ Clean (incl. the full download/build-from-source path, not just the already-installed default) |
| geerlingguy.exim | ✅ Clean |
| geerlingguy.swap | ✅ Clean (after fixing `mount:`'s `name:` alias, missing `*`/`/`/`//` arithmetic entirely, and the `int` filter's native-float handling) |
| geerlingguy.tomcat6 | ❌ Not testable — the `tomcat6` package doesn't exist on Ubuntu 22.04 (only `tomcat9`); both engines also reject the role's own deprecated `state: installed` identically before ever reaching the package task |
| geerlingguy.mailhog | ✅ Clean (idempotent, service verified live via `curl`) |
| geerlingguy.filebeat | ✅ Clean (byte-identical config; `apt: update_cache: true`'s own always-`changed` quirk on rerun confirmed to match real ansible-playbook exactly, not a bug) |
| geerlingguy.ruby | ✅ Clean (after implementing `gem:`, entirely unimplemented, and fixing `apt:`'s idempotency for a purely virtual package name already satisfied via another package's `Provides:`) |
| geerlingguy.fluentd | ❌ Not testable — the role's own td-agent apt repo (packages.treasuredata.com) has no valid Release file for Ubuntu jammy (reproduces on real ansible-playbook too) |
| geerlingguy.composer | ✅ Clean (after fixing `get_url:`'s checksum algorithm silently using SHA1 for anything but md5/sha256, and `command:`/`shell:`/`unarchive:`'s `creates=`/`removes=`/`chdir=` not expanding a leading `~`) |
| geerlingguy.solr | ✅ Clean (after fixing 6 chained bugs: `creates=` extraction dropping single-template values, local-connection `become_user` plugin staging under a non-traversable install dir, Crinja missing `.split(...)` support entirely, Crinja's `trim_blocks` eating a literal space, and `file:` not chowning newly-created intermediate directory components — idempotent, service verified live via `systemctl`/`curl`) |
| geerlingguy.passenger | ❌ Not testable — the role's own apt-key fetch uses a stale key ID (`561F9B9CAC40B2F7`); the actual repo now signs with a different key (`D870AB033FB45BD1`) (reproduces on real ansible-playbook too) |
| geerlingguy.drupal | ❌ Not testable — its `composer require` task explicitly sets `become: false` (assumes a non-root deploy user); our benchmark harness connects as root throughout, so Composer's own root-safety check aborts regardless of engine (reproduces on real ansible-playbook too) |
| geerlingguy.java | ✅ Clean (idempotent, `java -version` functionally verified) |
| geerlingguy.containerd | ✅ Clean (idempotent, byte-identical `config.toml`, service verified live via `systemctl`/`ctr version`) |
| geerlingguy.helm | ✅ Clean (after fixing `not a or b` evaluating as `not(a or b)` instead of `(not a) or b` — real operator-precedence bug in the hand-rolled `when:` evaluator; idempotent, `helm version` functionally verified) |
| geerlingguy.gogs | ❌ Not testable — role version 1.4.3 uses the legacy `include:` directive, removed entirely from current ansible-core (real `ansible-playbook` refuses to parse the role at all), same failure mode as `geerlingguy.phpmyadmin` |
| geerlingguy.hdparm | ✅ Clean (idempotent, byte-identical `hdparm.conf`) |
| geerlingguy.daemonize | ✅ Clean (idempotent, correct version functionally verified; needs `build-essential` as a pre-task prerequisite on a bare image — real ansible-playbook needs it too) |
| geerlingguy.svn | ✅ Clean (after fixing `creates=`/`chdir=` extraction absorbing a second param's value; idempotent, repository created, `svnserve`/`apache2` verified live) |
| geerlingguy.blackfire | ✅ Clean (after fixing `apt_key:`'s idempotency for `url:`/`data:` with no `id:`, the common real-world shape; idempotent, packages + apache verified live) |
| geerlingguy.glusterfs | ✅ Clean, incl. a real 3-node cluster (own legacy `include:` patched locally to `include_tasks:`, and `glusterfs_ppa_version` overridden to `"9"` - the role's own default `"7"` has no jammy PPA release; both external, not crystal-ansible). Single-instance install clean on the first try. The 3-node cluster (real `ansible-playbook` orchestrating one cluster, `crystal-ansible` a separate one, both via real SSH, forming genuine replicated GlusterFS volumes) found two real engine bugs: `hostvars[<name>]` was entirely unimplemented, and `'x' not in y.stdout` mis-split when the literal itself contained the word "in". Both fixed; final state idempotent on both clusters, `gluster peer status`/`volume status` all green, cross-node file replication functionally verified through the mounted volume. |

| robertdebock.zabbix_server | ✅ Clean (after fixing 8 real engine bugs: Jinja2 `is boolean`/`is number`/`is string`/`is integer`/`is float`/`is iterable`/`is none` type tests entirely missing, the "undefined" sentinel not recognized by `default()`, no-arg `.split()` and a recursive-re-templating gap in dotted-access base fetch, `systemd:`'s `daemon_reexec:` unrecognized, `apt:`'s `deb:` param entirely unimplemented, `meta: flush_handlers` entirely unsupported - a real functional gap here, not cosmetic - plus a crash it exposed in the plugin pre-upload path for any `meta:` task against a real remote host, and a `mysql_user` idempotency bug in `update_password: always`; idempotent, `zabbix-server`/`mysql` verified live via `systemctl`+port checks on a fresh host) |
| robertdebock.zabbix_agent | ✅ Clean (same round/fixes as zabbix_server above; idempotent, `zabbix-agent` verified live via `systemctl`+port check) |
| robertdebock.grafana | ❌ Not testable - role does not exist on Ansible Galaxy or GitHub under this name (confirmed via the Galaxy API and a full listing of robertdebock's ~300 GitHub repos) |
| robertdebock.minio | ❌ Not testable - same (no Galaxy or GitHub role under this name) |
| robertdebock.bind | ❌ Not testable - same (no Galaxy or GitHub role under this name; robertdebock does publish `dns`/`dnsmasq`, but no `bind`) |
| robertdebock.postgresql | ❌ Not testable - same (no Galaxy or GitHub role under this exact name; robertdebock's closest role is `postgres`, a different name than requested) |

| robertdebock.nginx | ✅ Clean (zero engine bugs; idempotent, `curl` verified live) |
| robertdebock.mysql | ✅ Clean (after implementing `community.general.ini_file`, entirely missing, whose absence had also been silently swallowing robertdebock.mysql's own `Configure mysql server`/`client` tasks and cascading into a missed `Restart mysql server` handler; idempotent, `mysql -u root -p... -e 'select 1'` verified live) |
| robertdebock.docker_ce | ✅ Clean (zero engine bugs; idempotent, a real `docker run hello-world` verified live) |
| robertdebock.users | ✅ Clean (after fixing 3 real engine bugs: `include_tasks:`/`include_role:` with a scalar-template `loop:` never resolving at all - custom `loop_var` stayed "undefined" - plain-`{{ }}` `or`/`and` always coercing to literal "True"/"False" instead of real Jinja2 value-selector semantics, `getent:` never failing a missing single-key lookup - breaking a role's own `rescue:` block - and `password_hash` entirely unimplemented, silently storing plaintext into `/etc/shadow`; idempotent modulo `password_hash()`'s own real non-deterministic-salt property, confirmed identical on real ansible-playbook too) |
| robertdebock.phpmyadmin | ✅ Clean (after fixing 3 real engine bugs: `type_debug` filter entirely missing, `unarchive:`'s `extra_opts:` silently dropped - breaking `--strip-components=1`, the standard way to unpack a GitHub-release tarball - and the resulting tar-based idempotency check trusting `tar --compare`'s raw exit code instead of parsing its output the way real Ansible's own `TgzArchive#is_unarchived` does; idempotent, `curl` 200 on phpmyadmin's own `index.php` verified live) |
| Oefenweb.fail2ban | ✅ Clean (after implementing Python's `SEP.join(iterable)` string-method-call syntax, entirely missing - the reverse argument order of the `join` Jinja filter - plus one more recursive-re-templating copy in per-element list rendering; idempotent, `fail2ban-client status` showing the sshd jail verified live) |

| weareinteractive.nginx | ❌ Not testable - the role's own nginx.org apt-key setup fetches a now-invalid/stale GPG key (`NO_PUBKEY`, apt refuses the unsigned repo; reproduces on real ansible-playbook too) |
| weareinteractive.mysql | ❌ Not testable - role's own `tasks/main.yml` uses the legacy `include:` directive, removed entirely from current ansible-core (real `ansible-playbook` refuses to parse the role at all; same failure mode as `phpmyadmin`/`gogs`) |
| weareinteractive.redis | ❌ Not testable - same (legacy `include:`) |
| weareinteractive.users | ✅ Clean (after fixing 2 real engine bugs: `default(a ~ b ~ c)`, a Jinja2 `~`-concatenation `default()` argument, was unhandled - only `+`/`-` had the ExpressionEvaluator delegation - and `authorized_key:` wasn't idempotent for an empty `key:` value, a legitimate real-world case (no keys configured for a user); real Ansible's own module treats an empty key as a true no-op and doesn't even create the file, matched exactly. Also needed `ANSIBLE_ALLOW_BROKEN_CONDITIONALS=true` to get past a real ansible-core 2.19 strictness change unrelated to crystal-ansible, the role's own aging non-boolean `when:`. Idempotent, `id`-verified live) |
| Stouts.iptables | ❌ Not testable - same legacy `include:` issue as weareinteractive.mysql/redis (real ansible-playbook refuses to parse) |
| Stouts.timezone | ❌ Not testable - same |

| prometheus.prometheus.node_exporter | ✅ Clean (re-verified live AGAIN 2026-08-13, round 22 continued - after round 21's 16 bugs and round 22's first pass (6 more, closing out the Crinja convergence prep work), a THIRD live pass specifically to verify the step-5 dual-evaluator convergence (`or`/`and`/`is`, ternary, comparisons routing through Crinja first) found 7 more bugs (0.9.327-0.9.332), incl. a genuine CPU-pegging infinite-recursion hang (`prepare_crinja_vars` re-entrancy, not just a wrong value), `uri:`'s `dest:` file-writing entirely unimplemented, `.splitlines()`/`flatten`/`regex_findall`/`dict(iterable)` missing, `map('filtername', 'arg')` losing string-literal quoting on its inner call, a bare-identifier index-key (`dict[var]`) re-templating gap present in THREE independent evaluator copies, and `unarchive:`'s `extra_opts:` breaking on a templated (JSON-array-string) list value vs. a literal YAML list. Idempotent (`changed=0` on rerun), `node_exporter` service verified live via `systemctl`/`curl :9100/metrics`. See `KNOWN_MISSING.md`/`CRINJA.md` for full detail. |

**Legend:** ✅ Clean = engine matches real `ansible-playbook` (idempotent,
healthy services, config parity) as of the last time it was run. ⚠️ = engine
itself is fine, but the role hit an external/environmental blocker partway
through. ❌ = role could not be run at all (Galaxy removal or a bug in the
role itself, not crystal-ansible).
