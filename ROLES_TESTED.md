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

**Legend:** ✅ Clean = engine matches real `ansible-playbook` (idempotent,
healthy services, config parity) as of the last time it was run. ⚠️ = engine
itself is fine, but the role hit an external/environmental blocker partway
through. ❌ = role could not be run at all (Galaxy removal or a bug in the
role itself, not crystal-ansible).
