# krikri-lint — a plan for an ansible-lint clone

Status: planning document. Phase 0 skeleton and the Phase 1 v1 rule
table implemented (2026-09): `krikri-lint` binary with CLI
(targets, `-p/--parseable`, `--nocolor`, `--list-rules`, `--version`,
exit codes 0/2/3), file discovery, positioned `YAML::Nodes` loader,
task walker, and these rules: `syntax-check`,
`command-instead-of-shell`, `command-instead-of-module`,
`no-changed-when`, `risky-file-permissions`, `risky-octal`,
`name[missing]`, `name[casing]`, `name[template]`,
`fqcn[action-core]`, `yaml[line-length]`. Each rule mirrors the
upstream rule logic fetched from the ansible-lint source at
implementation time (message text, severity, tags, exemptions).
Notes from that pass: upstream's risky-octal suggestion message is
computed from the YAML-decimal mode value (quirky but kept for
parity), and `yaml[document-start]` is disabled in ansible-lint's
bundled .yamllint, so it is deliberately not implemented. Phase 2+
(meta/schema rules, noqa, config, profiles) is not implemented yet.

### Parity harness (testing/lint/parity.py)

Runs real ansible-lint and krikri-lint with `-p` output over the same
targets and diffs (path, line, column, rule-id) triples, separating
real divergences from unimplemented-rule gaps. Parity target is the
installed `ansible-lint 25.6.1+really25.2.1`; rule logic pinned to
what that version does (it differs from upstream main in at least one
place: no-changed-when still fires on async+poll:0 tasks there).

Current status on the `testing/` corpus: 2270 triples matched,
0 upstream-only, and 6 krikri-only, all explained:
- `htpasswd_edge_cases.yml` syntax-check: Crystal's YAML (libyaml)
  rejects `command: awk -F: '...'` (`: ` inside a plain scalar) while
  upstream's ruamel/YAML-1.2 accepts it - parser-strictness gap, not
  a rule bug.
- `py_module_edge_cases.yml` name[missing] x5: upstream aborts a
  file's analysis after its `syntax-check[unknown-module]` failure
  (the fixture intentionally uses nonexistent modules); we don't
  implement that rule yet, so we keep analyzing.

Position conventions learned from the harness (matchtask rules report
at the task line with no column; only fqcn points at the module key;
name[casing]/name[template] point at the name value; name[missing]
has no column). Upstream also classifies files under roles/<name>/
only in tasks/handlers/defaults/vars/meta, and resolves deprecated
redirects like yum → ansible.builtin.dnf, both mirrored here.

## What this is

`krikri-lint` would be a from-scratch reimplementation of `ansible-lint`
in Crystal, sitting next to `krikri-playbook` in this repo. It shares
the same philosophy as the playbook engine: parse real Ansible content
and aim for behavioral parity with the upstream tool — same rules,
same output format, same exit codes — not just "the common cases work."

It is a *sibling* binary, not a mode of `krikri-playbook`: lint is
static analysis with no host connection, no execution, no SSH. It
reads playbooks/roles and reports violations.

## What ansible-lint actually is (reference model)

Upstream `ansible-lint` is ~150 rules in categories, driven by:

1. **File loading & YAML parsing** of playbooks, roles, tasks, handlers,
   vars, and `meta/main.yml`, with line/column position preserved per node.
2. **A rule registry** — each rule has an id (e.g. `risky-file-permissions`),
   severity (LOW/MEDIUM/HIGH/VERY_HIGH), tags, and a file-type scope
   (playbook / tasks / handlers / vars / meta / role / yaml).
3. **Rule matching** — mostly static YAML tree inspection, plus
   Jinja2-aware checks (`name[template]`, `jinja[spacing]`) and module
   argument schema checks.
4. **Profiles** (`min` → `production` / `shared` / `official`) that gate
   which rules run; a rule below the active profile's severity bar is skipped.
5. **Transform** (autofix) — deliberately out of scope for v1; upstream's
   own autofix is partial.
6. **Skip machinery** — inline `# noqa: rule-id`, per-project
   `.ansible-lint` / `ansible.cfg` config, `!unsafe`-aware parsing.
7. **Exit codes**: 0 = clean, 2 = violations found (failure), 3 = crash,
   1 = (upstream uses 1 for config errors / usage). v1 should match these.

Output format to match (one violation per line):

```
roles/foo/tasks/main.yml:12: risky-file-permissions: File permissions unset or insecure: /etc/foo.conf
Read documentation for instructions on how to ignore specific rule violations.
```

and the `-p` (parseable) format:

```
path:line:col rule-id severity message
```

## Feasibility findings (verified 2026-09)

### YAML position data — solved, no fork needed

The Crystal stdlib YAML parser already exposes everything needed:

- `YAML::Nodes.parse` (NOT `YAML.parse`, which returns position-less
  `YAML::Any` — this is what the current `playbook_parser.cr` uses) gives
  every node `start_line`, `start_column`, `end_line`, `end_column`,
  all 1-based, matching ansible-lint's output conventions directly.
- Verified against a real task mapping:

  ```
  YAML::Nodes::Mapping  @ 2:3
    "name"   @ 2:3   -> "install foo" @ 2:9
    "apt"    @ 3:3   -> Mapping @ 4:5
    "become" @ 6:3
  ```

- API notes (easy to trip on):
  - Root of a parsed file is `YAML::Nodes::Document`; descend via `.nodes.first`.
  - Children are accessed via `.nodes` on every container class
    (`Document`, `Sequence`, `Mapping`); mappings store their content
    as a flat list `[key1, value1, key2, value2, …]`, not pairs.
  - `Scalar#value` returns `String | Nil`; mappings/sequences have no
    `.value`. Pattern-match on the node class to traverse.
  - `in_groups_of(2)` compiles but types poorly here; a manual
    index-stepping loop (`i += 2`) over the flat node list is the clean way.

Design decision: lint rules walk `YAML::Nodes` directly (like upstream
walks ruamel nodes). An intermediate positioned-AST is a possible later
refactor if rules get painful, but not for v1.

### Jinja2 awareness — already exists

`krikri-playbook` has two independent Jinja evaluators under
`src/krikri/variable_substitutor/` (hand-rolled `ExpressionEvaluator` +
vendored `Crinja`). Jinja-based lint rules need only *recognition*, not
evaluation, so mostly they need the parsing/lexing side, which is
already battle-tested here — including the recursive-re-templating bug
class this codebase has fixed repeatedly. When writing
`jinja[spacing]`/`name[template]` style rules, check the same traps in
both evaluators as usual.

### Module knowledge — head start exists

- `AVAILABLE_PLUGINS` in `playbook_parser.cr` already distinguishes
  core vs community module names → feeds `fqcn[action-core]` rules.
- `plugin_helpers/ansible_arg_validation.cr` + the ~90 plugin helpers
  give partial argument schemas → feeds arg-validation-style rules.

### What must be built new

Everything else: the binary, CLI, rule base class and registry,
file discovery/loading (roles incl. `meta/main.yml`), `# noqa`
handling, `.ansible-lint` config parsing, profiles, and the rules
themselves. This is the bulk of the work but it is additive code —
very little of `krikri-playbook`'s execution machinery is touched at all.

## Phasing

### Phase 0 — skeleton (binary + output contract)

- `src/krikri_lint/` new source tree; `krikri-lint` binary target
  (build.sh gains a second binary; check whether `PLUGINS`-style
  registration is needed — it is not, lint has no host plugins).
- CLI: positional targets (files/dirs), `--parseable`, `--profile`,
  `--nocolor`, `--list-rules`, exit codes 0/2/3.
- File discovery: given a directory, find playbooks (`*.yml` at
  playbook level), roles (`roles/*/tasks|handlers|defaults|vars|meta|files`),
  standalone task files — mirroring upstream's loader order.
- Positioned YAML load: thin wrapper around `YAML::Nodes.parse`
  returning `(node, filename)` plus helpers to flatten the flat-mapping
  list into usable key/value iteration.

### Phase 1 — first rules (the ~10 that catch the most)

Rule base class:

```crystal
abstract class Rule
  abstract def id : String          # e.g. "risky-file-permissions"
  abstract def severity : Severity
  abstract def tags : Array(String) # e.g. ["opt-in", "risk"]
  abstract def applies_to : FileTypeSet
  abstract def check(node, context, violations)
end
```

Context carries filename, file type, role name, parsed tree.

v1 rule set (high value, all static, no execution):

| Rule | Category | Notes |
|---|---|---|
| `syntax-check` | core | parse errors are violations (reuse YAML parse) |
| `command-instead-of-shell` | command-shell | `shell:` without `executable:`/pipe need |
| `command-instead-of-module` | command-shell | curl/wget/git via `command:` |
| `no-changed-when` | idiom | `command:`/`shell:` tasks without `changed_when`/`creates` |
| `risky-file-permissions` | risk | `file:`/`copy:`/`template:` without `mode:` |
| `risky-octal` | risk | string-quoted octal modes vs numeric |
| `name[casing]` | naming | task/role names start uppercase |
| `name[missing]` | naming | tasks without `name:` |
| `name[template]` | naming | `{{ }}` in task names (needs Jinja recognition only) |
| `fqcn[action-core]` | fqcn | `apt` → `ansible.builtin.apt` |
| `yaml[line-length]` etc. | yaml | port a small yamllint subset — upstream delegates yaml* rules to yamllint; krikri-lint implements a small subset directly |

### Phase 2 — role/meta structure + schema rules

- `meta/main.yml` validation (`galaxy_info` required keys, author/license
  shape) — upstream has ~30 `schema[*]` rules; start with `schema[meta]`.
- `handler-first`, `no-handler` (task used only as a handler),
  `inline-instead-of-file` for `shell: |` blocks that belong in scripts.
- Vars-file rules (`var-naming[no-jinja]`, `var-naming[no-reserved]`).

### Phase 3 — Jinja rules + noqa + config

- `jinja[spacing]`, `jinja[invalid]` (parse the expression via the
  existing evaluator in parse-only mode), `no-jinja-when`.
- `# noqa: rule[,rule]` on the task line — position tracking makes this
  straightforward: violation line + rule id → consult noqa map built
  during load.
- `.ansible-lint` config file (YAML): `exclude_paths`, `skip_list`,
  `warn_list`, `profile`, `kinds`.

### Phase 4 — profiles, then transform (optional, last)

- Profile gating (`min`/`moderate`/`safety`/`shared`/`official`/
  `production`) — severity × tag table.
- `--fix` transform: explicitly deferred; only after the rule set is
  stable and only for a handful of safely-fixable rules
  (`fqcn[action-core]`, `yaml[comments-indentation]`-style).

## Testing strategy

Follow the repo's existing philosophy: unit specs for the rule
machinery, but the real bar is parity runs against real content.

1. **Unit specs** (`spec/lint/…`): each rule gets a spec with a fixture
   YAML snippet asserting violation line/col and message.
2. **Parity corpus**: run both `ansible-lint` (real, if installed) and
   `krikri-lint` against the same corpus — the roles already tested in
   `ROLES_TESTED.md` are a natural corpus of real-world content — and
   diff the violation id sets. Divergences get triaged exactly like
   playbook divergences (upstream may be right; so may the role).
3. **Self-lint**: `krikri-lint` on this repo's own test
   playbooks/roles under `testing/`.

## Relationship to krikri-playbook

- Shares the repo, build script, and (optionally) some parsing helpers.
- Does NOT share the execution path: no SSH, no plugin upload, no
  task executor. `syntax-check` uses the playbook parser's knowledge of
  valid task structure but runs it statically.
- Jinja recognition reuses `variable_substitutor` parsing, read-only.
- Versioning: `src/krikri/version.cr` is shared; either give
  `krikri-lint` its own VERSION constant or keep them in lockstep.
  Suggest: separate `KRIKRI_LINT_VERSION` starting at 0.1.0 to avoid
  entangling the playbook release cadence.

## Open questions

1. **Corpus licensing**: which roles to keep as lint fixtures in-repo
   vs. re-fetch at test time (same pattern as `ROLES_TESTED.md`).
2. **yamllint subset scope**: upstream delegates all `yaml[*]` rules to
   yamllint. How many of those to port before the parity bar is met —
   suggest starting with `line-length`, `truthy`, `comments`,
   `document-start`, `key-ordering`? (or explicitly declaring `yaml[*]`
   a known gap in `KNOWN_MISSING.md`-style docs, since these are
   style-only).
3. **Rule id stability**: upstream rule ids have churned
   (`risky-octal` merged into `risky-file-permissions` etc.). Pin the
   target upstream version in this doc before Phase 1 and record it in
   `krikri-lint --version` output, exactly like the playbook engine pins
   its parity target.
4. **Whether lint runs in CI here**: once `ROLES_TESTED.md` roles are a
   corpus, a weekly parity run would keep the rule set honest the way
   benchmark rounds keep the executor honest.

## Suggested first commit sequence

1. `krikri-lint` skeleton: CLI, exit codes, file discovery, positioned
   YAML loader, `syntax-check` rule, `--list-rules`. Unit specs.
2. Rule registry + severity/scan plumbing + the v1 rule table
   (Phase 1), each rule with fixture specs.
3. `# noqa` + `.ansible-lint` skip config.
4. meta/schema rules (Phase 2).
5. Jinja rules (Phase 3).
6. Profiles.
7. Parity corpus tooling + docs (`krikri-lint` section in README,
   rule docs in-repo like ansible-lint's `docs/`).
