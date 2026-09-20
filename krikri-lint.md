# krikri-lint — a plan for an ansible-lint clone

Status: substantially complete as of v0.6.0 (2026-09) - the rule set,
parity harness, config/noqa/profiles, and `--fix` autofix below are all
implemented and parity-verified; the dated sections are newest-first.
Phase 0 skeleton and the Phase 1 v1 rule
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
(meta/schema rules, noqa, config, profiles) landed later - see the
dated sections below.

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

### Phases 2-4 status (2026-09, v0.4.0)

All phases implemented through profiles:
- **CLI**: -p/-f brief|pep8|quiet|json, -L, -P, -T, -q, -v,
  --force-color, --nocolor, --version/-h, exit 0/2/3.
- **Phase 3 machinery**: `# noqa` / `# noqa: id,id` (violation line or
  enclosing task), `.ansible-lint` config discovered cwd-upward
  (exclude_paths, skip_list, warn_list, profile), CLI overrides
  -x/--skip-list, -w/--warn-list, --enable-list, -t/--tags,
  --profile; warn_list rules report but do not fail.
- **Phase 2 rules**: var-naming[pattern]/[no-reserved] (vars-file
  keys are pattern-only upstream; jinja-templated names skip all
  checks; set_fact skips __private/cacheable), no-handler (fires on
  simple changed-referencing whens, skipped for handlers/listen).
- **Phase 3 rules**: no-jinja-when (only `when` triggers upstream),
  jinja[spacing] (inner brace padding), jinja[invalid] (Crinja parse
  errors only; render-time failures are ignored like upstream's
  bypasses).
- **Phase 4 profiles**: min/basic/moderate/safety/shared/official/
  production gating per upstream profiles.yml; "basic" is not
  user-selectable.

Deliberate divergences/known gaps:
- upstream's black-based jinja expression reformat (our jinja[spacing]
  is the narrow inner-padding subset);
- upstream aborts a file after syntax-check[unknown-module] (we keep
  analyzing; that rule is unimplemented);
- Crystal's YAML (libyaml) rejects some plain scalars with ": " that
  ruamel (YAML 1.2) accepts - one fixture in the corpus hits this;
- schema[meta] is not implemented: the installed ansible-lint accepts
  even shape-broken standalone meta files, so adding checks would
  CREATE divergence;
- var-naming[no-role-prefix] and the remaining yamllint yaml[*] subset
  are unimplemented (visible as "unimplemented-upstream" in harness
  output, not counted as divergences).

### args[module] and fqcn[canonical] (2026-09, v0.4.0)

Two new rules plus a risky-shell-pipe bug fix, all verified live
against the installed ansible-lint 25.6.1+really25.2.1:

- **args[module]** (warning-class, VERY_LOW here) validates task params
  against per-module argument specs, mirroring ansible-core's
  AnsibleModule-init validation: unsupported parameters (with the
  alias tail), missing required, required_one_of, required_together,
  required_if ("state is present but any/all of the following are
  missing"), required_by, choices, list choices, and bool conversion.
  Only core (ansible.builtin) modules get specs (see arg_specs.cr);
  community modules are outside krikri's coverage bar, so the ~270
  args[module] hits upstream produces on them stay as expected
  upstream-only gaps, not divergences. Data pinned to the installed
  ansible-core 2.19.11 argspecs via `ansible-doc -j`, including its
  quirks: yum_repository's required_one_of is really required_if on
  state=present (default present applied at init), apt's `upgrade:
  true` passes via ansible-core's bool->'True'->unique-boolean-choice
  remap, package_facts' `manager` is never validated, and getent's
  `split` is a string, not a bool. Templated values skip type/choices
  checks like upstream.
- **fqcn[canonical]** flags FQCNs that redirect to a different
  canonical name (ansible.builtin.acl -> ansible.posix.acl,
  community.mysql.* -> ansible.mysql.*, ansible.builtin.cronvar ->
  community.general.cronvar), message and module-key position matching
  upstream exactly.
- **risky-shell-pipe ignore_errors fix**: the old check was inverted
  (fired when ignore_errors was falsy and skipped when truthy).
  Upstream exempts tasks whose ignore_errors converts to Python-truthy:
  plain YAML true/yes/on/1 exempt, plain false/no/off/0/null/empty
  fire, and quoted or templated values ("false", "{{ x }}") are
  non-empty strings and therefore EXEMPT - implemented via the scalar's
  plain-vs-quoted style.

Parity after this pass: 2856 triples matched, 0 args/fqcn/risky
krikri-only divergences; remaining krikri-only are the two pre-existing
documented classes (syntax-check YAML strictness, py_module
name-checks-after-abort); remaining upstream-only is args[module] on
community modules only.

Correction: `schema[meta]` above is NOT an unimplemented gap - it IS
implemented (`src/krikri_lint/rules/schema_meta.cr`, listed by
`krikri-lint --list-rules`). An earlier revision of this doc's "Deliberate
divergences" list called it unimplemented; that line was stale by the
time schema[meta] actually landed and is corrected here.

### yaml[*] subset and var-naming[no-role-prefix] (2026-09, v0.5.0)

Closes the two items the previous "Deliberate divergences" list called
unimplemented, both live-verified against installed ansible-lint
25.6.1+really25.2.1:

- **yaml[comments]**, **yaml[empty-lines]**, **yaml[hyphens]**,
  **yaml[indentation]**, **yaml[key-duplicates]**,
  **yaml[new-line-at-end-of-file]**, **yaml[octal-values]** join the
  already-shipped yaml[line-length]/[trailing-spaces]/[truthy], porting
  the rest of the yamllint rule set ansible-lint's bundled config
  enables by default. `yaml[document-start]` remains deliberately
  unimplemented - confirmed still disabled in the installed
  ansible-lint's bundled yamllint config, so implementing it would
  itself be a divergence.
- **var-naming[no-role-prefix]** mirrors upstream's
  `VariableNamingRule._parse_prefix`/matchplay/matchtask logic exactly:
  keys in a role's `defaults`/`vars` files, non-keyword keys (and their
  `vars:` mapping) on a playbook's `roles:` entries, and
  vars/set_fact/register on `include_role`/`import_role` tasks must be
  prefixed with the role's own name (`nginx_*` for role `nginx`). FQCN
  role names (containing a `.`) disable the prefix AND pattern checks
  entirely, matching upstream's `is_fqcn_or_name` gate. `file_type.cr`
  gained role-subdirectory detection independent of the `main.yml`
  filename so every file under `roles/<name>/{tasks,vars,defaults,...}`
  classifies correctly, not just `main.yml`.

Parity after this pass: 2865 triples matched, 10 krikri-only (all
pre-existing documented classes - the abort-after-unknown-module py_module
fixtures now also surface yaml[empty-lines] there, same root cause as the
existing name[missing] entries in that class, not a new gap), 267
upstream-only (args[module] on community modules, unchanged), 10
unimplemented-upstream.

### --fix autofix (2026-09, v0.6.0)

`--fix` is implemented for the rules that are safely, mechanically
fixable, calibrated live against the installed ansible-lint's own
`--fix` (its fixable set = every rule carrying the `autofix` tag; of
those, the ones krikri implements: fqcn, name, no-jinja-when,
command-instead-of-shell, yaml):

- **Fixable here**: `fqcn[action-core]` and `fqcn[canonical]` (module
  key rewritten to the resolved/canonical FQCN),
  `command-instead-of-shell` (`shell:` key -> `ansible.builtin.command:`,
  mirroring upstream's transform; the rule only fires on
  metacharacter-free commands so the rename is safe),
  `name[casing]` (first character uppercased, `prefix | name` kept,
  notify references to the old name updated like upstream's
  transform), `no-jinja-when` (`{{ }}` stripped from
  when/changed_when/failed_when string values, quoting preserved -
  upstream's RE_JINJA is exactly `{{ (.*?) }}`),
  `yaml[trailing-spaces]`, `yaml[new-line-at-end-of-file]`,
  `yaml[empty-lines]`.
- **Not fixable here (deliberate)**: `yaml[truthy]` (upstream's own
  fixer leaves yes/off values in place - verified live),
  `yaml[indentation]` and the rest of the yaml[*] set (upstream fixes
  those via its ruamel full-file re-dump, which also rewrites comments
  and inserts `---` document starts; a round-trip re-dumper is out of
  scope - krikri's fixer is line-local and never touches anything
  outside the violated span), `jinja[spacing]` (upstream's fix is the
  black-based reformat, already a documented non-goal).
- **CLI shape matches upstream**: `--fix` = all fixable rules,
  `--fix=rule1,rule2` scopes it (rule ids, family names like `fqcn`/
  `name`/`yaml`, or tags; `autofix` selects all fixable),
  `--fix=none` disables, `--fix=all` is the explicit everything.
  Unknown values exit 3 like upstream's INVALID_CONFIG. Fixable rules
  carry the `autofix` tag, so `--list-rules` shows them (same
  mechanism upstream uses).
- **Mechanism**: `Rule#fixable?` + `Rule#fix(buffer, file, violation)`
  (`src/krikri_lint/fixer.cr` holds `FixBuffer` - line-local edits on
  original coordinates, whole-line deletion, final-newline flag -
  plus `FixSpan` for locating a scalar's written text span including
  quote characters). After fixing, the CLI re-runs the checks on the
  changed files and reports the post-fix state; fixed violations drop
  out and the exit code reflects what remains (0 when everything was
  fixed). Upstream instead drops matches marked fixed and re-runs
  only the yaml rule; the re-run is the honest superset (it also drops
  violations resolved incidentally, e.g. an fqcn hit resolved by the
  shell-key rename).
- **Verified live**: on a mixed fixture (lowercase names, bare apt/
  shell/command/debug keys, quoted jinja when, trailing spaces,
  missing final newline), krikri-lint `--fix` output is byte-identical
  to `ansible-lint --fix`. Divergences, all upstream-fixer quirks we
  do not replicate: upstream's ruamel re-dump inserts `---` document
  starts, rewrites comments (badly - one fixture had a comment line
  mangled into `- name: true`), fixes yaml[indentation], and its
  post-fix report drops all-but-the-first yaml match per file via a
  re-run bookkeeping quirk.

Parity after this pass (no rule logic changed): 2865 matched,
10 krikri-only, 267 upstream-only, 10 unimplemented-upstream.

### Weekly parity runs (2026-09, v0.6.0)

`.github/workflows/lint-parity.yml` runs testing/lint/parity.py on a
weekly cron (plus manual dispatch): installs the pinned upstream
release (`ansible-lint==25.2.1` from PyPI - the local parity target is
Debian's 25.6.1+really25.2.1, i.e. 25.2.1 code), builds, runs the
harness over the testing/ corpus, and uploads the report as an
artifact. The job does not fail on divergences (the documented
pre-existing classes keep the harness exit code at 1); it exists to
surface NEW divergence classes for triage, the lint-side analogue of
the playbook engine's benchmark rounds. Locally the same thing is:

    python3 testing/lint/parity.py [targets ...]

### Version pinning (2026-09, v0.6.0)

`krikri-lint --version` now reports the pinned parity target
explicitly (`ansible-lint parity target: 25.6.1+really25.2.1 (upstream
25.2.1)`), from the `PARITY_TARGET_ANSIBLE_LINT` constant in
`src/krikri_lint/version.cr` next to `KRIKRI_LINT_VERSION`. Rule logic
is pinned to what that release does wherever the two differ from
upstream main (e.g. no-changed-when's async+poll:0 behavior).

### Corpus licensing decision (2026-09, v0.6.0)

The parity corpus is this repo's own `testing/` playbook/role
fixtures, already committed in-repo (559 files under `testing/`,
including every fixture the harness lint-checks). Decision: **lint
fixtures stay committed in-repo** - the harness's default target is
`testing/` itself, there is nothing fetched at test time to re-license
(Galaxy role checkouts under `~/scratch` are never lint targets here),
and the playbook side of the house already commits its testing
playbooks the same way. No third-party content needs to enter the
corpus for parity to be meaningful; if real Galaxy roles are ever
linted as fixtures, they get committed as small hand-copied snippets,
not vendored trees, keeping the corpus unambiguously ours.

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
5. **Transform** (autofix) — implemented in v0.6.0 for the safely
   mechanical subset; upstream's own autofix is partial too. See the
   "--fix autofix" section.
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
- `--fix` transform: implemented (v0.6.0) for the safely mechanical
  subset - see the "--fix autofix" section near the top.

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

All four original open questions are resolved:

1. **Corpus licensing** - decided: lint fixtures stay committed
   in-repo (see the "Corpus licensing decision" section above).
2. **yamllint subset scope** - decided: the full `yaml[*]` set the
   bundled .yamllint enables is ported (v0.5.0), except
   `yaml[document-start]`, which that config disables (implementing
   it would itself be a divergence).
3. **Rule id stability** - decided: the target release is pinned as
   `PARITY_TARGET_ANSIBLE_LINT` and reported by `krikri-lint
   --version` (v0.6.0).
4. **Whether lint runs in CI here** - decided: weekly
   `lint-parity.yml` GitHub Actions workflow plus manual dispatch
   (v0.6.0).

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
