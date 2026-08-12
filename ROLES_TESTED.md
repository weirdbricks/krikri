# Roles Tested

Real-host `crystal-ansible`-vs-`ansible-playbook` correctness rounds run so
far, and each role's **current** status (not what was fixed to get there —
see `KNOWN_MISSING.md` and `git log` for that history). Check this before
picking a shortlist for the next round, to avoid re-discovering Galaxy-404s
or already-clean roles as if they were new.

| Role | Status |
|---|---|
| dev-sec.os_hardening | ✅ Clean |
| konstruktoid.hardening | ✅ Clean |
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
| geerlingguy.supervisor | ✅ Clean (after fixing the `hash` filter and Crinja's boolean stringification) |
| geerlingguy.htpasswd | ✅ Clean (after fixing `community.general.htpasswd`, previously unimplemented) |
| geerlingguy.clamav | ✅ Clean (after fixing `.find(substring)` string method, missing from `VariableLookup`) |
| geerlingguy.kibana | ✅ Clean (after fixing Crinja's empty-string/array/hash truthiness) |
| geerlingguy.logstash | ✅ Clean (after fixing the `to_json` filter and `chdir=`/etc. with a templated, space-containing value) |
| geerlingguy.gitlab | ✅ Clean (after fixing handler `register:`/`changed_when:`/`failed_when:`, entirely unapplied, and the `bool` filter's keyword semantics) |
| geerlingguy.varnish | ❌ Not testable — role's own packagecloud.io apt repo has no valid Release file for Ubuntu jammy (reproduces on real ansible-playbook too) |
| geerlingguy.php-mysql | ❌ Not testable — role's own repo ships no `vars/Debian.yml` at all (reproduces on real ansible-playbook too) |
| geerlingguy.mongodb | ❌ Not testable — role no longer exists on Ansible Galaxy |
| geerlingguy.consul | ❌ Not testable — role no longer exists on Ansible Galaxy |
| geerlingguy.golang | ❌ Not testable — role no longer exists on Ansible Galaxy |

**Legend:** ✅ Clean = engine matches real `ansible-playbook` (idempotent,
healthy services, config parity) as of the last time it was run. ⚠️ = engine
itself is fine, but the role hit an external/environmental blocker partway
through. ❌ = role could not be run at all (Galaxy removal or a bug in the
role itself, not crystal-ansible).
