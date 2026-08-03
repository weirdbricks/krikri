# Crystal Play - What's Missing?

## Comprehensive Analysis of Missing Features

**Current Status:** Phase 0-2 complete, Phase 3 well underway (see [ROADMAP.md](ROADMAP.md) for the live, detailed tracking - this document is a periodic high-level snapshot, not the source of truth).
**Date:** 2026-08-03 (originally written 2026-01-29; most of what it once called "missing" has since shipped)

---

## ✅ **WHAT'S ALREADY IMPLEMENTED**

### **Core Infrastructure (100%)**
- ✅ YAML playbook parser
- ✅ Inventory parser (INI + YAML)
- ✅ SSH connection manager with pooling
- ✅ Task executor with colored output
- ✅ Check mode (--check / dry-run)
- ✅ Diff mode (--diff / show changes)
- ✅ Variable substitution ({{ vars }}), including Jinja2 control structures via Crinja
- ✅ **Handlers (notify/listen)**
- ✅ Tags support (--tags)
- ✅ Conditionals (`when:`) - full expression evaluator (`==`/`!=`/`in`/`not`/`and`/`or`, `is defined`/`is not defined`)
- ✅ Facts gathering (`gather_facts:`, `ansible_os_family`/`ansible_hostname`/etc, `plugins/facts.cr`)
- ✅ Advanced loops: `loop:`, `with_items`, `with_dict`, `with_fileglob`, `with_nested`, `with_sequence`, `with_indexed_items`
- ✅ `until:`/`retries:`/`delay:` (retry a task until a condition passes)
- ✅ `block:`/`rescue:`/`always:` error handling, `ignore_errors:`
- ✅ Roles (`roles:` directory resolution, `meta/main.yml` dependencies, variable precedence, `files:`/`templates:` resolution)
- ✅ `import_playbook:` / `import_tasks:` / `include_tasks:` / `include_role:`
- ✅ Ansible Vault (AES256 encrypt/decrypt, `--ask-vault-pass`/`--vault-password-file`, `vault {encrypt|decrypt|view|encrypt_string|rekey}` CLI subcommands, inline `!vault` values)
- ✅ Docker-based compatibility harness (`compat/`) cross-verifying every feature above against real `ansible-playbook`, not just documented behavior

### **Plugins (30 total)**
1. ✅ **copy** - File copying
2. ✅ **template** - Jinja2 templating
3. ✅ **file** - File/directory management
4. ✅ **service** - Service control
5. ✅ **shell** - Shell commands with pipes/redirects
6. ✅ **command** - Simple command execution
7. ✅ **dnf** - RHEL/Fedora packages
8. ✅ **apt** - Ubuntu/Debian packages
9. ✅ **package** - Meta-plugin (auto-detects OS)
10. ✅ **debug** - Print messages/variables
11. ✅ **facts** - Gather system facts
12. ✅ **user** - User account management
13. ✅ **group** - Group management
14. ✅ **git** - Clone/checkout repositories
15. ✅ **cron** - Manage cron jobs
16. ✅ **authorized_key** - SSH key management (`ansible.posix.authorized_key`)
17. ✅ **lineinfile** - Edit specific lines in files
18. ✅ **stat** - Read-only file/filesystem status
19. ✅ **find** - Recursive file/directory search
20. ✅ **archive** - Compress/archive files and directories (`community.general.archive`)
21. ✅ **unarchive** - Extract an archive into a directory
22. ✅ **apt_repository** - Add/remove a Debian/Ubuntu APT source
23. ✅ **yum_repository** - Write a YUM/DNF `.repo` file
24. ✅ **sysctl** - Manage a sysctl config entry
25. ✅ **mount** - Manage `/etc/fstab` entries (and optionally mount/unmount)
26. ✅ **ufw** - Uncomplicated Firewall rules (`community.general.ufw`)
27. ✅ **firewalld** - firewalld zone configuration, offline mode (`ansible.posix.firewalld`)
28. ✅ **docker_image** - pull/remove Docker images (`community.docker.docker_image`)
29. ✅ **docker_network** - create/remove Docker networks (`community.docker.docker_network`)
30. ✅ **docker_container** - create/start/stop/remove Docker containers (`community.docker.docker_container`)

---

## ⏳ **WHAT'S STILL MISSING (Priority Order)**

Everything that used to be listed here as high/medium priority - conditionals, facts, advanced loops, roles, include/import, vault, blocks/error handling - is done (see above), and Phase 3 is now mostly done too: `stat`, `find`, `archive`, `unarchive`, `apt_repository`, `yum_repository`, `sysctl`, `mount`, `ufw`, and `firewalld` have all shipped. What's left is a narrower slice of Phase 3 plus all of Phase 4. See [ROADMAP.md](ROADMAP.md) for the authoritative, actively-maintained list; the summary below won't be kept as current as that file.

### **🟡 Phase 3 remainder - extended plugins**
- ✅ `docker_container` / `docker_image` / `docker_network` - shipped in
  `0.9.12`, talking to the Docker Engine API directly (like real
  Ansible's own community.docker) rather than shelling out to the
  `docker` CLI - via a fork of the only actively-maintained Crystal
  Docker API shard, [weirdbricks/docr](https://github.com/weirdbricks/docr)
  (upstream had a connection-reuse bug serious enough to make it unusable
  for a multi-call module, now fixed there)
- `mysql_db` / `mysql_user`, `postgresql_db` / `postgresql_user`

**Workaround:** Use `shell`/`command` to call the native tool directly (still applies to the MySQL/PostgreSQL modules).

**Note on `ufw`:** implemented, but uniquely in this codebase, not verified end-to-end against real `ansible-playbook` - `ufw` refuses to run at all without root (even bare status queries), and no available test environment here has working netfilter access even as root. Confirmed real Ansible's own `ufw` module fails identically under the same constraint, so this is an environmental limit, not a crystal-ansible gap - see `ROADMAP.md`'s `ufw` entry for details.

### **🟢 Phase 4 - Advanced execution features**
- ✅ `changed_when` / `failed_when` - shipped in `0.9.7`
- ✅ `delegate_to` / `run_once` - shipped in `0.9.8`
- ✅ `group_vars` / `host_vars` directory loading - shipped in `0.9.9`
- ✅ `async:` / `poll:` / `async_status` - shipped in `0.9.10` (local
  connections only)
- ✅ Dynamic inventory (executable script) - shipped in `0.9.11`
  (Ansible's newer YAML-defined inventory *plugins*, e.g. `aws_ec2.yml`,
  are not implemented)
- Cloud plugins (`ec2`, `s3_bucket`, `azure_rm_*`) - lowest ROI per usage stats (~5% of playbooks) - the only Phase 4 item left

**Workaround:** Structure playbooks with separate plays per host/delegate target.

---

## 📊 **IMPACT ANALYSIS**

### **What Percentage of Playbooks Are Blocked?**

| Missing Feature | Blocks % of Playbooks (est.) | Workaround Exists? |
|----------------|----------------------|-------------------|
| `delegate_to`/`run_once` | ~15% | Yes (separate plays) |
| Async execution | ~10% | Yes (run sync) |
| Dynamic inventory | ~10% (mostly cloud-heavy shops) | Partial |
| DB modules (mysql/postgresql) | ~5-10% | Yes (shell/command) |

Conditionals, facts, loops, roles, include/import, vault, block/error-handling, and now the bulk of Phase 3's extended plugins - previously the highest-impact gaps - are all shipped, so the remaining gaps are narrower, more workaround-friendly, and concentrated in Phase 4 (advanced execution features) plus Docker/DB modules than when this document was first written.

---

## 🎯 **RECOMMENDED NEXT STEPS**

Sequenced in [ROADMAP.md](ROADMAP.md) Phase 3 (extended plugins, nearly done) then Phase 4 (advanced execution features). As of this update, only Docker modules and MySQL/PostgreSQL modules remain in Phase 3; everything else in that phase - `stat`, `find`, `archive`, `unarchive`, `apt_repository`, `yum_repository`, `sysctl`, `mount`, `ufw`, `firewalld` - is done.

---

## 💡 **HONEST ASSESSMENT**

### **What Crystal Play Is TODAY:**

✅ **Production-ready for:**
- Small to large deployments (roles + vault are both done now)
- Standard web applications, database servers, CI/CD pipelines
- Infrastructure as Code with real conditional logic and OS-aware facts
- Multi-play, multi-role playbooks organized via `roles:`/`import_playbook:`/`include_tasks:`
- Encrypted secrets via Ansible Vault, matching real `ansible-vault`'s file format and CLI
- System configuration: package repositories, sysctl, fstab/mounts, and (with the caveats noted above) firewall rules via `ufw`/`firewalld`

⚠️ **Needs work for:**
- Cloud-provider-driven dynamic inventory (script-based dynamic inventory is done; YAML-defined inventory *plugins* like `aws_ec2.yml` are not)
- MySQL/PostgreSQL modules (workaround: `shell`/`command`) - Docker itself is done as of `0.9.12`
- Extensive use of Ansible Galaxy collections beyond what's reimplemented here

---

*Last updated: 2026-08-03, reflecting Phase 3 nearly complete (stat, find, archive, unarchive, apt_repository, yum_repository, sysctl, mount, ufw, firewalld). For current status, always check [ROADMAP.md](ROADMAP.md) first - this file is a periodic snapshot.*
