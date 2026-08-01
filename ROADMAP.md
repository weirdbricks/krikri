# Crystal Play - Roadmap to Ansible Parity

**Status as of 2026-08-01:** builds again on Crystal 1.20.3 (fixed `as_i` -> `as_i64`
type mismatch in `comparison_evaluator.cr`). No automated tests exist yet. This
roadmap sequences the remaining work from the two prior analysis docs
([WHATS_MISSING.md](WHATS_MISSING.md), [MISSING_FEATURES_COMPREHENSIVE.md](MISSING_FEATURES_COMPREHENSIVE.md))
into phases, with a test-foundation phase added first since none currently exists.

---

## Phase 0 - Foundation (do this before adding anything else)

There is currently no `spec/` directory, no test framework dependency, and no CI.
Every plugin added past this point needs a regression net or the project will drift
the same way it did between January and now.

1. Add `crystal spec` scaffolding (`spec/spec_helper.cr`).
2. Unit specs for the pure-logic pieces (no I/O): `conditional_evaluator.cr`,
   `variable_substitutor/*` (filters, comparisons, expression eval),
   `playbook_parser.cr` (YAML -> task struct).
3. Integration specs that run the built binary against the existing
   `testing/*.yml` fixtures in `--check` mode and assert exit code + expected
   changed/ok counts. This turns the current manual fixtures into real
   regression tests for free.
4. GitHub Actions workflow: build + `crystal spec` + `ameba` on every push.
5. Bump to `0.2.0` once this lands.

**Every phase below ships plugins/features with specs, not just code.**

---

## Phase 1 - Essential gaps (~2-3 weeks)

- Loop constructs: `with_dict`, `with_fileglob`, `with_nested`, `with_sequence`,
  `with_indexed_items`, `until`/`retries`/`delay`
- Plugins: `user`, `group`, `git`, `cron`, `authorized_key`
- `block` / `rescue` / `always` error handling

**Result:** ~99.95% playbook coverage per prior analysis.

---

## Phase 2 - Organizational (~2-3 weeks)

- Roles: `roles/<name>/{tasks,handlers,vars,files,templates,defaults,meta}`
  directory resolution, variable precedence, `meta/main.yml` dependencies
- `include_tasks` / `import_tasks` / `import_playbook` / `include_role`
- Vault: AES256 encrypt/decrypt, `--ask-vault-pass`, `--vault-password-file`,
  inline `!vault` encrypted values

**Result:** enterprise-ready.

---

## Phase 3 - Extended plugins (~4-6 weeks)

- `apt_repository` / `yum_repository`
- `sysctl`, `mount`
- `ufw` / `firewalld`
- `stat`, `find`, `archive` / `unarchive`
- `docker_container` / `docker_image` / `docker_network`
- `mysql_db` / `mysql_user`, `postgresql_db` / `postgresql_user`

**Result:** ~99.99% playbook coverage per prior analysis.

---

## Phase 4 - Advanced execution features (~4-6 weeks)

- `delegate_to`, `run_once`
- `changed_when` / `failed_when`
- Async execution (`async:` / `poll:`, `async_status`)
- Dynamic inventory support + `group_vars` / `host_vars` directory loading
- Cloud plugins (`ec2`, `s3_bucket`, `azure_rm_*`) - optional, lowest ROI
  per usage stats (~5% of playbooks)

**Result:** full Ansible parity for Linux server automation.

---

## Total estimate

Roughly 12-18 weeks of focused work across Phases 1-4, plus Phase 0 up front.
