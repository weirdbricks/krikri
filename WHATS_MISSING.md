# Crystal Play - What's Missing?

## Comprehensive Analysis of Missing Features

**Current Status:** Phase 0-2 complete, Phase 3 in progress (see [ROADMAP.md](ROADMAP.md) for the live, detailed tracking - this document is a periodic high-level snapshot, not the source of truth).
**Date:** 2026-08-02 (originally written 2026-01-29; most of what it once called "missing" has since shipped)

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

### **Plugins (20 total)**
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

---

## ⏳ **WHAT'S STILL MISSING (Priority Order)**

Everything that used to be listed here as high/medium priority - conditionals, facts, advanced loops, roles, include/import, vault, blocks/error handling - is done (see above). What's left is genuinely Phase 3/4 territory: extended plugins and advanced execution features. See [ROADMAP.md](ROADMAP.md) Phase 3/Phase 4 for the authoritative, actively-maintained list; the summary below won't be kept as current as that file.

### **🟡 Phase 3 - Extended plugins**
- `apt_repository` / `yum_repository`
- `sysctl`, `mount`
- `ufw` / `firewalld`
- `unarchive` (the `archive` plugin's counterpart is done; `unarchive` itself is not)
- `docker_container` / `docker_image` / `docker_network`
- `mysql_db` / `mysql_user`, `postgresql_db` / `postgresql_user`

**Workaround:** Use `shell`/`command` to call the native tool directly.

### **🟢 Phase 4 - Advanced execution features**
- `delegate_to`, `run_once`
- `changed_when` / `failed_when`
- Async execution (`async:` / `poll:`, `async_status`)
- Dynamic inventory support + `group_vars` / `host_vars` directory loading
- Cloud plugins (`ec2`, `s3_bucket`, `azure_rm_*`) - lowest ROI per usage stats (~5% of playbooks)

**Workaround:** Structure playbooks with separate plays per host/delegate target; run tasks sequentially instead of async.

---

## 📊 **IMPACT ANALYSIS**

### **What Percentage of Playbooks Are Blocked?**

| Missing Feature | Blocks % of Playbooks (est.) | Workaround Exists? |
|----------------|----------------------|-------------------|
| `apt_repository`/`yum_repository` | ~15% | Yes (shell/command) |
| `unarchive` | ~10% | Yes (shell/command) |
| `delegate_to`/`run_once` | ~15% | Yes (separate plays) |
| Async execution | ~10% | Yes (run sync) |
| Dynamic inventory | ~10% (mostly cloud-heavy shops) | Partial |
| Docker/DB modules | ~15-20% combined | Yes (shell/command) |

Conditionals, facts, loops, roles, include/import, vault, and block/error-handling - previously the highest-impact gaps - are all shipped, so the remaining gaps are narrower and more workaround-friendly than when this document was first written.

---

## 🎯 **RECOMMENDED NEXT STEPS**

Sequenced in [ROADMAP.md](ROADMAP.md) Phase 3 (extended plugins, in progress) then Phase 4 (advanced execution features). `stat`, `find`, and `archive` are done as of this update; next up per the roadmap is the rest of Phase 3 (`apt_repository`/`yum_repository`, `sysctl`/`mount`, `ufw`/`firewalld`, `unarchive`, Docker modules, MySQL/PostgreSQL modules).

---

## 💡 **HONEST ASSESSMENT**

### **What Crystal Play Is TODAY:**

✅ **Production-ready for:**
- Small to large deployments (roles + vault are both done now)
- Standard web applications, database servers, CI/CD pipelines
- Infrastructure as Code with real conditional logic and OS-aware facts
- Multi-play, multi-role playbooks organized via `roles:`/`import_playbook:`/`include_tasks:`
- Encrypted secrets via Ansible Vault, matching real `ansible-vault`'s file format and CLI

⚠️ **Needs work for:**
- Playbooks relying on `delegate_to`/`run_once`/async execution
- Dynamic inventory / cloud-provider-driven inventories
- Docker orchestration or MySQL/PostgreSQL modules (workaround: `shell`/`command`)
- Extensive use of Ansible Galaxy collections beyond what's reimplemented here

---

*Last updated: 2026-08-02, reflecting Phase 0-2 completion and Phase 3 progress (stat, find, archive). For current status, always check [ROADMAP.md](ROADMAP.md) first - this file is a periodic snapshot.*
