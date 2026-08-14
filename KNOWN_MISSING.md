# Known Missing / Known Gaps

The goal is 100% behavioral compatibility with `ansible-playbook`,
verified against real runs rather than assumed - not "cover the common
cases." This file tracks what's actually missing today. It intentionally
does **not** carry implementation history or root-cause narrative for
fixed bugs - that detail lives in `git log` commit messages, written at
the same level of detail per commit; search there (e.g. `git log --all
--grep=auth_socket`) rather than in a second, easily-stale copy here.

**Currently at `0.9.346`.**

---

`0.9.346` (round 23 - `geerlingguy.phpmyadmin` goes from ❌ Not testable to
✅ Clean; two real engine bugs fixed live):

- **`~/.my.cnf` option-file fallback in `MysqlConnection.build_uri`**
  (`src/crystal_play/plugin_helpers/mysql_connection.cr`) - the shared
  `mysql://` URI builder now parses the `[client]` section of a MySQL
  option file (`config_file`, default `~/.my.cnf`) for `user`/`password`/
  `socket`, and merges them under explicit `login_*` params (explicit wins,
  matching community.mysql's `mysql_connect`). This was a hard requirement
  for the geerlingguy role family and any real playbook whose `mysql_db`/
  `mysql_user`/`mysql_info`/`mysql_query` tasks pass NO login params and
  rely on the option file the role itself writes. Before, crystal connected
  with an empty password and every such task failed `Access denied for user
  'root'@'localhost' (using password: NO)`. `mysql_db.cr`/`mysql_user.cr`/
  `mysql_info.cr`/`mysql_query.cr` now pass `config_file:
  \@params["config_file"]? || "~/.my.cnf"`. Two subtleties worth keeping:
  (a) Crystal's `File.expand_path` does NOT expand a leading `~` (it treats
  `~` as a literal relative component), so `~/.my.cnf` is resolved by an
  explicit `resolve_option_file_path` that expands `~`/`~user` exactly like
  `BasePlugin#expand_tilde` (via `ENV["HOME"]`/`System::User`); (b)
  `login_host`/`login_port` are deliberately NOT taken from the option file
  (upstream keeps `localhost:3306` unless `config_overrides_defaults: true`
  is set) - only user/password, plus socket as a fallback when no
  `login_host` was given. Unit specs in `spec/unit/mysql_connection_spec.cr`.
- **`lineinfile` (state=present) last-match semantics**
  (`src/crystal_play/plugin_helpers/line_editor.cr`) - `ensure_present`
  found the FIRST line matching `regexp`; real Ansible's lineinfile replaces
  only the LAST matching line. Switched `lines.index` -> `lines.rindex`.
  Live divergence that surfaced it: geerlingguy.phpmyadmin's "Add default
  username and password for MySQL connection." tasks regex `^.+\[['"]host
  ['"]\].+$` matches BOTH the package's active `...['host'] = $dbserver;`
  line and a commented template `// ...['host'] = 'localhost';` near EOF;
  real ansible rewrites the final (commented) occurrence and leaves the
  active one alone, crystal rewrote the first, producing a byte-divergent
  `config.inc.php`. Regression spec in
  `spec/unit/line_editor_spec.cr`.
- **Live verification** on a fresh 2-node `G3.2GB` Atlantic.net pair
  (`geerlingguy.mysql` + `geerlingguy.phpmyadmin`, pulled through the local
  `roles/` copy whose `geerlingguy.phpmyadmin` had the legacy `include:`
  directive patched to `include_tasks:` so current ansible-core parses it;
  that patch was synced to the baseline host so BOTH engines ran the SAME
  role). Cold: crystal ok=80/changed=31/failed=0 vs baseline
  (ansible-core 2.17.14 + community.mysql 3.10.0) ok=96/changed=30/
  failed=0. Warm (idempotency): crystal changed=1 and baseline changed=1,
  the SAME single task (`Ensure MySQL users are present.` - the role's
  `update_password: always` re-asserts the user password every run; real
  Ansible behaves identically, so this is role-side, not a divergence).
  `config.inc.php` byte-identical between the two hosts; both run apache2 +
  mysql active and serve phpmyadmin HTTP 200 on port 8080. The residual
  cold ok-count gap (80 vs 96) is the include_tasks/`included:` accounting
  difference in display, not a functional divergence (changed counts match).

---

`0.9.345` (hostname module completion):

- **`hostname` module** (`plugins/hostname.cr`) - implements
  `ansible.builtin.hostname`. Sets the system hostname persistently via
  systemd's `hostnamectl set-hostname`, falling back to writing
  `/etc/hostname` + running `hostname(1)` on non-systemd hosts. Idempotent:
  compares `System.hostname` against the desired `name` before acting, and
  re-reads afterward to report the actual resulting hostname (hostnamectl may
  normalize it). `--check` reports would-change without touching the system.
  Returns `ansible_facts` (`ansible_hostname`, `ansible_nodename`,
  `ansible_fqdn`, `ansible_domain`) at the result top level, mirroring the
  facts plugin's `gather_hostname` fact shape (FQDN taken live from
  `hostname -f`, falling back to the short name when that fails). Registered
  in `build.sh`'s PLUGINS array and `playbook_parser.cr`'s
  AVAILABLE_PLUGINS (so both bare `hostname` and
  `ansible.builtin.hostname` resolve). Integration spec in
  `spec/integration/hostname_spec.cr` (4 examples, read-only + check-mode
  only so it never mutates the live hostname).
  Previous (pre-existing) work on this file compiled only with `Socket`,
  which Crystal stdlib doesn't expose - switched to `System.hostname`; added
  the missing `check_mode` property + private `capture` helper; `failed: false`
  is now present on every success result (PluginResult requires it). Also
  fixed the hostnamectl -> legacy-fallback logic: the previous version relied
  on `capture` raising to trigger the fallback, but `capture` swallows errors
  and returns `""` - added an explicit `run_succeeds?` status check so a
  failed/missing `hostnamectl` actually falls back to `/etc/hostname` +
  `hostname(1)` (`set_hostname` is never exercised by the spec, which is
  read-only + check-mode only, but the fallback must be correct for real
  use).

`0.9.343`-`0.9.344` (deferred-item follow-up on the auth_socket / signed_by
work from the previous round, all closure of the gaps that round explicitly
left open):

- **mysql_user `plugin:`/`plugin_hash_string:`/`plugin_auth_string:` params**
  now implemented in `plugins/mysql_user.cr` - account creation/update with
  non-password auth. Auth clause precedence matches real Ansible's own
  community.mysql `module_utils/user.py` exactly: password, then
  plugin+hash (`IDENTIFIED WITH p AS hash`), then plugin+auth_string
  (`IDENTIFIED WITH p BY auth`, with MariaDB pam->USING and ed25519->USING
  PASSWORD() special cases), then bare plugin (`IDENTIFIED WITH p`).
  `plugin: unix_socket` -> `CREATE USER ... IDENTIFIED WITH unix_socket`,
  the auth_socket account pattern. The update path is idempotent: it diffs
  the account's current plugin (and authentication_string when a hash/auth
  string was given) *server-side* (`SELECT plugin = ? FROM mysql.user ...`
  as an Int32 0/1), because the vendored crystal-mysql driver has no `read`
  for the `plugin`/`authentication_string` columns - the same
  "not supported read" limitation `password_already_matches?` already
  documents for LONGTEXT. Validation rejects password+plugin together,
  hash+auth_string together, and hash/auth_string without a plugin.
- **Shared `http_download` helper** - factored the redirect-following,
  binary-safe download loop out of `get_url.cr` and `deb822_repository.cr`
  into `src/crystal_play/plugin_helpers/http_download.cr`
  (`PluginHelpers::HTTPDownload.download`), so the two plugins (which both
  hand-rolled near-identical copies) share one implementation. get_url.cr
  maps its extra knobs (timeout, validate_certs, basic auth, custom
  headers) onto the helper's `Options`; deb822 keeps the plain default.
  No behavior change - both compiled through `./build.sh`, `crystal spec`
  (1091 examples, 0 failures) still green.
- **End-to-end auth_socket container verification** - added
  `testing/test-mysql-auth-socket.sh`: spins up a throwaway MariaDB
  container, connects all four `mysql_*` plugins over the Unix socket as
  OS root with NO login_password (the previously-broken auth_socket
  shape), and asserts each step's PASS/FAIL, including mysql_user
  `plugin: unix_socket` account creation + idempotent rerun + removal.
  All PASS. Doesn't touch the shared `ca-mysql`/`ca-pg` test containers.

`0.9.340`-`0.9.343` (crystal-mysql fork fix for auth_socket/unix_socket authentication, plus deb822_repository signed_by improvements — both long-standing scope cuts closed):

`0.9.340`-`0.9.343` (crystal-mysql fork fix for auth_socket/unix_socket authentication, plus deb822_repository signed_by improvements — both long-standing scope cuts closed):

- **crystal-mysql auth_socket/unix_socket**: The vendored crystal-mysql driver fork (`github.com/weirdbricks/crystal-mysql`, commit `a91a592`, tag `crystal-ansible-0.9.340`) now advertises `CLIENT_PLUGIN_AUTH` unconditionally in `HandshakeResponse41` (not gated by `@password`), writes the auth plugin name even when no password is given, and returns an empty auth response for `auth_socket`/`unix_socket`/`mysql_clear_password` plugin names. This allows roles connecting via `login_unix_socket:` with no `login_password:` to authenticate to servers where the account uses socket peer-credential auth (the common MariaDB/Debian-packaging pattern for root). See `lib/mysql/src/mysql/packets.cr`, `git log --oneline --grep="0\.9\.34[0-3]"`, and the fork's own `PATCHES.md` for the three changes made to `Auth.scramble`/`HandshakeResponse41`.

- **deb822_repository `signed_by` improvements** (`plugins/deb822_repository.cr`): The `resolve_signed_by` method now implements real Ansible's full four-way branching: local path (`File.exists?`), URL (redirect-aware download, stored as `<name>.asc` or `<name>.gpg` matching real Ansible's naming convention with no `gpg --dearmor` step), inline ASCII-armored key text (Deb822 folded multi-line format with indented continuation lines), and key fingerprint (space-normalized). `check_mode` no longer triggers network I/O (key download guarded behind check_mode check). The rendered file now includes `X-Repolib-Name: <name>` matching real Ansible's output. Keyring files get explicit mode `0644`. `download_binary` follows HTTP redirects up to 5 hops (many real key URLs redirect). Verified via `crystal spec` (1085 examples, 0 failures) and `./build.sh`.

---

`0.9.339` (first slice of CRINJA.md step-5's live-host verification of
constructs 4-9 - the whole `#evaluate_expr` dispatch now routes through
Crinja first - run against `dev-sec.os_hardening` on a real 2-node
Atlantic.net pair. Found LIVE and fixed two real mode-integrity bugs, the
kind unit specs alone never surface):

- `plugins/set_fact.cr`'s `coerce` was decimal-parsing a leading-zero
  octal-style *string* (`"0755"`) into the int `755` via `.to_i64?` -
  Crystal's decimal int parsing ignores leading zeros. os_hardening's own
  dynamic `set_fact: "{{ item.key }}": "{{ item.value }}"` (with_dict over
  `os_vars`) decimal-parses every `os_mnt_*_dir_mode`/`os_*_perms` STRING
  this way, and a downstream `file: mode:` fed the int straight to a chmod
  syscall applied it as octal `01363` instead of `0755`, corrupting real
  directory permissions on `/dev`/`/run`/`/var`/`/home`/`/tmp`/`/dev/shm`/
  `/var/tmp`. Fix: a leading `0` followed by more digits is never a genuine
  decimal literal (Python 3 itself rejects `0755`), so exclude it from int
  coercion and fall through to the plain-string case. `"0"` and a real
  float like `"0.5"` still coerce normally (regression spec in
  `spec/integration/set_fact_spec.cr`).
- `src/crystal_play/task_executor/executor.cr`'s mode reformatting - the
  `{{ var }}`-whole-span-to-`Int64` path in `substitute_task_params` - was
  re-expressing the int via `"0" + raw.to_s(8)`, under the assumption the
  int was always a YAML-octal-derived DECIMAL (like `02770` -> decimal
  1528, whose digits contain an `8` and so never look octal-valid). But a
  value decimal-coerced from an already-octal-style STRING (`"1777"` -> int
  1777, the set_fact case above) has decimal digits that ALREADY look like
  a valid octal mode - reformatting treated 1777's decimal value as needing
  re-expression in octal and produced `"3361"`. Live-confirmed: `/dev/shm`,
  `/tmp`, `/var/tmp` all ended up mode `3361` instead of `1777` on the
  crystal host. Fix: if the int's plain decimal digits already match
  `\A[0-7]{3,4}\z` (the same regex `file.cr`'s mode parser uses), use them
  as-is; otherwise reformat via `to_s(8)` as before (regression spec in
  `spec/integration/mode_octal_via_variable_spec.cr`).
- The second regression spec originally reproduced os_hardening's exact
  `loop: "{{ os_vars | dict2items }}"` shape, but `dict2items` is itself
  still unimplemented in `FilterEngine` (it passes the dict through
  unchanged), so the loop never actually set the fact and the spec silently
  tested nothing (dir left at default mode 775). Rewritten to reproduce the
  decimal-coercion directly with a plain `set_fact: my_mode: "1777"`.
- Verified: full `crystal spec` (1065 examples, 0 failures), `./build.sh`.
  **Then closed out with the clean fresh-host re-verify**: a NEW 2-node
  Atlantic.net pair (same plan/OS), full `dev-sec.os_hardening` cold run
  on both engines and a warm idempotency pass. Cold recap crystal
  ok=101/changed=35/failed=0 vs python ok=102/changed=36/failed=0; the
  pre-fix "changed=43" inflated mount-dir count is gone. Warm pass:
  crystal `changed=0` (fully idempotent), python `changed=1`. Every
  remaining cold-run diff was traced to a documented non-engine cause:
  the `Harden permissions for directory of mount /var/log` status flip
  is the known systemd-tmpfiles 755<->775 environmental flake (verified:
  both engines apply `mode="0775"` byte-identically in a controlled
  standalone test; python's OWN warm run re-flipped its `/var/log` back
  to 755 mid-run after a manual `chmod 0775`, live proof it's not the
  engine) and the two account-loop diffs (`Extract root account(s)`/
  `Lock passwords`) are the known loop-hash iteration-order display
  artifact. Service/config parity verified byte-identical: auditd active
  on both, ASLR=2, suid_dumpable=0, same password-aging policy, and
  `/etc/sysctl.d/90-dev-sec.conf` / audit rules / limits.conf identical
  content. **CRINJA.md step 5's live-host verification is now DONE** for
  os_hardening.

---

`0.9.338` (CRINJA.md step 5, eighth and ninth constructs: `|`-filter
chains and the leading-paren wrapper - the last two pieces of
`#evaluate_expr`, both now converged. **Step 5's `ExpressionEvaluator`
side is essentially complete**: every dispatch branch in
`#evaluate_expr`/`#evaluate` tries Crinja first except `lookup()`
bare-calls, which have no Crinja equivalent, and `dict()`'s single
positional-iterable form, which Crinja's own `dict()` silently mishandles
(see `0.9.337`'s entry)):

- `evaluate_with_filter` (the ~1400-line `FilterEngine`'s entry point)
  now tries Crinja first via the raw-value path, falling back to the
  exact previous logic (renamed to `#evaluate_with_filter_fallback`) on
  any failure. Verified via extensive probing across real chain shapes
  from this codebase's own history: `combine`, `selectattr` + `list` +
  `first`, parenthesized/`range()`/`lookup()`-headed chains, `default()`,
  `to_json`, `regex_replace`/`regex_search`, `hash`/`password_hash`,
  register-result tests (`is changed`), and recursive re-templating
  (a variable whose value is itself unrendered `{{`/`{%` text) - all
  matched. Found one more real, pre-existing gap along the way (not a
  regression - Crinja is MORE correct): the hand-rolled `FilterEngine`
  has no `round` filter at all (silently passes the value through
  unchanged) - now fixed for free on the Crinja-success path.
- `evaluate_leading_paren` (`(expr).attr[idx] | filter`) converged the
  same way, at its call site in `#evaluate_expr` rather than the method
  itself - the fallback path still recurses through `#evaluate`, so it
  keeps benefiting from every other converged construct even when Crinja
  itself fails on the outer wrapper.
- Verified: `crystal spec` (1063 examples, 0 failures), `./build.sh`.
  Not yet live-host verified - given the scope of everything converged
  in this round (constructs 4-9, essentially the entire `#evaluate_expr`
  dispatch), a dedicated live-host round is recommended before treating
  this as done the way constructs 1-3 got their own (round 22,
  `0.9.327`-`0.9.332`, which found 7 more bugs unit specs/the harness
  alone never would have).

---

`0.9.337` (CRINJA.md step 5, seventh construct: solved the general
filter-chain dispatch's architectural blocker from the previous entry,
then converged literal array/dict expressions, `range()`, dotted/simple/
indexed variable lookups, and Python slice syntax to Crinja-first - only
filter chains themselves remain unconverged):

- **The architectural fix**: added `CrinjaRenderer#evaluate_value!`,
  which evaluates a bare expression and returns Crinja's RAW structured
  result as `JSON::Any?` (parsing directly via `Crinja::Parser::
  ExpressionLexer`/`ExpressionParser` and `Crinja::Environment#evaluate
  (ast_node, bindings) : Value`, bypassing `Template#render`'s
  always-a-String output entirely) instead of a pre-stringified String.
  Feeding that through `VariableLookup#format_value` (unchanged, still
  JSON-compact) instead of trusting Crinja's own `Finalizer` (Python-repr
  style) keeps the internal render-then-`JSON.parse`-back round trip
  intact for every existing call site, while still using Crinja for the
  actual evaluation. `ExpressionEvaluator` gained `#render_via_crinja_value`/
  `#render_via_crinja_string` wrapping it with the same delegation-depth
  guard `#render_via_crinja` already has.
- Converged (all via the new raw-value path): literal array/dict
  expressions, `range()` (bare-call form), dotted/simple/indexed variable
  lookups, and Python slice syntax. `dict()`'s single positional-iterable
  form and `lookup()` remain unconverged - `dict()` because Crinja's own
  `dict()` function silently ignores a positional argument and succeeds
  with an EMPTY dict (a silent-wrong-value risk the fallback pattern
  can't catch, unlike a clean raise); `lookup()` because Crinja has no
  equivalent function at all.
- **Real bug found and fixed along the way, independent of the
  convergence itself**: `var[1:3]`-style slicing (BOTH bounds present)
  never worked through the plain `evaluate()` entry point at all -
  `expr.includes?("[:") || expr.includes?(":]")` only matches an empty
  start or end (`items[:3]`, `items[2:]`), not a slice with digits on
  both sides of the colon, so it fell through to indexed-access handling
  (no slice support) and always resolved to `"undefined"` even though
  `ArraySlicer#slice` itself handled the same input correctly when called
  directly. Broadened the trigger check to match what `ArraySlicer`
  itself actually requires.
- Verified: `crystal spec` (1063 examples, 0 failures), `./build.sh`, and
  extensive empirical probing (nested dict/array traversal, `.get(key,
  default)`, Python string methods, `hostvars[...]`, missing keys/
  attributes, negative indices).

---

`0.9.336` (CRINJA.md step 5, sixth construct: `#evaluate_expr`'s
`*`/`/`/`//` arithmetic now tries Crinja first too, same pattern as
constructs 1-5; converged at the single shared `#evaluate_mult_div`
implementation so both call sites - the bare top-level case and the
nested case inside a `+`/`-` operand - benefit uniformly):

- **Real crash bug found and fixed**, independent of the convergence
  itself (pre-existing, not a regression): `10 // 0` raised an uncaught
  `OverflowError` crashing the whole process - `(10.0 / 0.0).floor` is
  `Float64::INFINITY`, and converting that to `Int64` overflows. `/`'s
  own division-by-zero case already degraded leniently to `"Infinity"`
  rather than raising; `//` now matches that same convention (renders
  empty/"undefined") instead of crashing.
- Verified via `crystal spec` (1062 examples, 0 failures), `./build.sh`,
  and empirical probes across int/float mixes, chained `*`, both
  directions of negative floor division, and error cases (type
  mismatches, division by zero) - Crinja either matched exactly or
  raised cleanly (safely caught by the existing fallback), never a
  silent misrender.

---

`0.9.335` (CRINJA.md step 5, fifth construct: `#evaluate_expr`'s `~`
string-concatenation operator now tries Crinja first too, same pattern
as constructs 1-4):

- **Real bug found and fixed in the `weirdbricks/crinja` fork** before
  trusting this convergence: both `~`'s and `+`'s non-numeric fallback
  branch stringified operands via raw `Value#to_s`, bypassing
  `Finalizer` entirely - a Bool operand rendered lowercase `"true"`/
  `"false"` instead of Python-parity `"True"`/`"False"`, and an
  Array/Hash operand leaked its raw `Crinja::Value<...>` wrapper inspect
  text (`"[Crinja::Value<1>, Crinja::Value<2>]"`) instead of a real
  stringified list. `~` is already used directly in real Ansible role
  templates (version-string concatenation); `+`'s identical bug isn't
  yet reachable from any converged construct but is fixed too. Fixed in
  the fork (`crystal-play-0.9.3`), `shard.yml`/`shard.lock` repinned.
- Verified via `crystal spec` (1061 examples, 0 failures), `./build.sh`,
  and empirical probes across strings/numbers/booleans/arrays/undefined/
  multi-segment `~` chains, all matching the hand-rolled fallback
  post-fix.

---

`0.9.334` (investigated converging `#evaluate_expr`'s `lookup()`/
`range()`/`dict()` bare-call branches - CRINJA.md step 5's next planned
sub-piece after bare literals - found a real fork bug along the way,
fixed it, but decided NOT to converge these three constructs themselves;
see CRINJA.md for full reasoning):

- **Real bug found and fixed in the `weirdbricks/crinja` fork** (not
  crystal-ansible itself): `Finalizer#stringify(Hash)` rendered
  `{'a' => 1}` (Crystal's own `Hash#to_s` separator) instead of real
  Python/Jinja2's dict repr `{'a': 1}`. Already live and reachable
  through every PREVIOUSLY converged construct (`or`/`and`/`is`, the
  ternary, comparisons) whenever the selected/returned value happens to
  be a dict - not a hypothetical gap tied to this investigation. Fixed
  in the fork (`crystal-play-0.9.2`), `shard.yml` repinned; two of the
  fork's own vendor specs had pinned the wrong `=>` output and are now
  corrected (net effect: 2 fewer fork spec failures, not more).
- **Decision: `lookup()`, `range()`, and `dict()`'s bare (unfiltered)
  call forms are NOT converged to try-Crinja-first.** `lookup()` is
  entirely Ansible-specific (`first_found`/`env`/`url` lookup types) with
  no Crinja-side equivalent at all - trying Crinja first would just cost
  a guaranteed-to-fail render+rescue on every call for zero benefit.
  `range()`/`dict()` return array/hash VALUES that Crinja's own (now
  correctly Python-repr-matching) stringification renders with `, `/`: `
  spacing (`[0, 1, 2]`, `{'a': 1}`), while this codebase's own
  `VariableLookup#format_value` - used for EVERY array/hash-valued
  expression elsewhere in the hand-rolled evaluator, not just these two -
  renders the JSON-compact form instead (`[0,1,2]`, `{"a":1}`), which
  itself diverges from real Ansible/Jinja2 output. Converging just these
  two bare-call forms would create a one-off inconsistency (spaced
  output only for `range()`/`dict()`, unspaced everywhere else) rather
  than fix anything - the real fix is a codebase-wide `format_value`
  correction, which is squarely the highest-risk, "general filter-chain
  dispatch" final sub-piece of the `#evaluate_expr` swap already flagged
  in CRINJA.md, not a quick win here. No spec today pins the current
  compact array/hash-to-string format (checked), so the blast radius of
  eventually fixing this is smaller than it might look, but it's still
  deferred rather than done opportunistically.

---

`0.9.333` (CRINJA.md step 5, fourth construct: `#evaluate_expr`'s bare
literals - boolean, numeric, quoted-string - now try Crinja first, same
render-then-fallback pattern as constructs 1-3; audit-only, no-code-change
work done first, see CRINJA.md's own next-steps #2/#3 write-ups):

- Found (not a live bug, a latent inconsistency caught auditing the
  swap): the old bare-boolean-literal branch unconditionally returned
  `expr.downcase` - lowercase `"true"`/`"false"` - at odds with every
  other boolean-producing path in this codebase (comparisons,
  `is`-tests, `ConditionalEvaluator`), which all produce capitalized
  `"True"`/`"False"` (real Python/Jinja2 convention). Never observed in
  practice because Crinja was always available and already produced the
  correctly-capitalized form for a bare `{{ true }}`/`{{ false }}` - the
  buggy fallback path was simply never exercised. Fixed for free by the
  convergence; the old (buggy) behavior is kept only as the fallback for
  if Crinja itself is ever unavailable.
- Also found: the bare quoted-string-literal path never unescaped
  anything (`'quote\'s here'` came back with the backslash still
  attached); Crinja's real string-literal parser does unescape, so a
  successful Crinja render is strictly more correct, not just
  equivalent - same fallback-only-on-failure treatment.
- Verified via `crystal spec` (1061 examples, 0 failures) and empirical
  probes confirming Crinja rejects (raises `Crinja::TemplateSyntaxError`,
  not a silent misrender) numeric forms the hand-rolled path currently
  accepts more loosely (`1e10`, `1_000`, `0x1F`) - those safely fall back
  to unchanged prior behavior.

---

`0.9.327`-`0.9.332` (live real-host re-verification of the CRINJA.md
step-5 dual-evaluator convergence work - the three constructs converged
in `0.9.324`-`0.9.326` - `or`/`and`/`is`, the inline ternary, and
`==`/`!=`/`<`/`>`/`<=`/`>=` comparisons - had only been checked against
`crystal spec` and the differential harness, never a real host. Re-ran
`prometheus.prometheus.node_exporter` again on a fresh 2-node Atlantic.net
pair; found 7 more real bugs, one of them a genuine hang):

- **Real infinite-recursion hang, not just a wrong value.** `_common_
  dependencies`'s own vars/main.yml default is pure `{% if %}...{% endif
  %}` block-tag Jinja (no `{{ }}`). Re-templating it re-entered
  `CrinjaRenderer#prepare_crinja_vars`, which re-walks ALL of `@vars` -
  including deeply nested `ansible_facts` - and since `@vars` never
  changes, found the same block-tag var still raw and recursed again.
  The existing `@@block_tag_escalation_depth` guard (cap 50) bounded the
  RECURSION DEPTH but not the WORK PER LEVEL (a full var-context re-walk
  each time), pegging a CPU core indefinitely in practice - observed
  >30s with zero progress, well before the depth cap was ever reached.
  Fixed with a second, much tighter depth guard (cap 3) specifically on
  `prepare_crinja_vars` re-entrancy.
- `ansible.builtin.uri`'s `dest:` file-writing was entirely unimplemented
  (the plugin's own doc comment said so) - `_common`'s own binary
  download task uses `uri:` with `dest:`, not `get_url:`; it reported
  "OK (N bytes)" and `changed: false` while silently never writing
  anything.
- No-argument `.splitlines()` Python string method - entirely missing
  from the plain `{{ }}` hand-rolled evaluator (Crinja's own copy in the
  forked shard already had it, but only reachable via `{%`/`{#`
  block-tag escalation, not a bare `{{ }}` expression).
- `flatten` and `regex_findall` filters were entirely missing from the
  hand-rolled `FilterEngine` (Crinja-only before) - `map('regex_findall',
  ...)` and `map('flatten')` both silently passed items through
  unchanged.
- `map('filtername', 'string arg')`'s own reconstruction of the inner
  filter call destructively stripped quote characters from string
  arguments (needed for a bare variable reference, wrong for a string
  literal that gets RE-PARSED as an expression) - a regex pattern
  argument with its own parens/`+`/`.` was misread as a bare expression
  instead of a literal, degrading to an effectively empty pattern.
- `dict(iterable_of_pairs)` - real Ansible's Templar exposes actual
  Python's `dict` builtin (not Jinja2's own `**kwargs`-only `dict`
  global), which also accepts a single positional argument. Entirely
  unhandled in both the Crinja fork and the hand-rolled evaluator.
- A bare-identifier INDEX KEY (`dict[some_var]`) had no recursive
  re-templating guard in `VariableLookup#resolve_index_key` - a role var
  computed from another template (`__common_binary_basename`) used as an
  index key resolved to the literal unrendered `"{{ ... }}"` text instead
  of its real value. A THIRD independent copy of the same gap existed in
  `ComparisonEvaluator#evaluate_simple_value` (no `[` branch at all, so a
  bracket-indexed comparison operand fell through to a literal-name
  lookup that could never match).
- `unarchive:`'s `extra_opts:` parsing only understood the comma-joined
  text a LITERAL YAML list produces at parse time - a `{{ }}`-templated
  expression that resolves to an array at runtime instead renders as a
  JSON-array string (`VariableLookup#format_value`'s own `Array ->
  value.to_json` convention), a completely different, unhandled text
  shape. Splitting that on `,` produced one garbage element still
  wrapped in brackets/quotes, corrupting the `tar` command line so badly
  that `tar --compare` silently reported no changes and extraction never
  ran - the archive downloaded and passed its checksum check, but
  nothing was ever unpacked.

`prometheus.prometheus.node_exporter` runs clean end-to-end again
(idempotent, `changed=0` on rerun, service verified live via `systemctl`/
`curl :9100/metrics`) - see `ROLES_TESTED.md`.

---

`0.9.312`-`0.9.320` (not a fresh-role benchmark round - a differential-
harness-driven Crinja convergence pass (see `CRINJA.md`), followed by a
live real-host re-verification of round 21's `prometheus.prometheus.
node_exporter` specifically to confirm the fixes held end-to-end, which
found 6 MORE real bugs beyond what the harness alone could catch (loop/
control-flow interactions and a non-Crinja executor bug, neither the kind
of thing a standalone-expression differential harness exercises):

- `and`/`or` returned a stringified bool instead of the actual
  short-circuited operand (`'' or 'fallback'` rendered `"True"`, not
  `"fallback"`) - the single most common Ansible defaulting idiom, broken
  in Crinja independently of the same bug class fixed in the hand-rolled
  evaluator back in round 19.
- `in`/`not in` was entirely absent from Crinja's grammar outside
  `{% for x in y %}`'s own fixed keyword - not a narrow gap, any use of
  the operator failed outright regardless of what was on either side.
- `first`/`list`/`join`/`trim`/`replace` raised on an Undefined target
  instead of the lenient empty-result real Jinja2 gives; `unique` filter
  wasn't registered at all.
- `namespace()` builtin (round 21's own blocker) plus `{% set ns.attr =
  ... %}` dotted-target assignment - both entirely missing.
- Filter/test parity audit against the hand-rolled `FilterEngine` found
  11 more gaps: `basename`, `dirname`, `combine`, `intersect`, `max`,
  `min` (the last two are standard Jinja2 CORE filters, missing from
  Crinja entirely), `regex_search`, and the `match`/`search`/`ne`/
  `truthy` tests.
- Crinja's string lexer dropped unrecognized backslash escapes entirely
  instead of passing them through literally - `{{ '\1' }}` rendered
  `""`, breaking real Ansible's `'\1'`-style regex backreference syntax.
- Live re-verification found 6 more: a ternary/`{% for x in y if COND %}`
  parsing collision (the round-21 inline-ternary patch's `parse_expression`
  override swallowed the for-loop's own `if` filter clause, evaluating the
  filter condition before the loop variable was ever bound); `.startswith(
  )`/`.endswith()` Python string methods missing; role defaults not
  crossing an `include_role:` boundary (a real `task_executor/
  variable_context.cr`/`role_loader.cr` bug, NOT Crinja - a role invoked
  via `include_role:` from inside another role's tasks, like
  `prometheus.prometheus`'s own `_common` shared-logic role, couldn't see
  the CALLING role's own `defaults/main.yml`, discarding the whole
  ancestor-role chain); `{% set a, b = expr %}` tuple-target assignment
  unsupported; postfix `[index]`/`.attr`/`(call)` trailer after a
  parenthesized expression (`(expr)[0]`) unsupported; and `not X is Y`
  parsed as `(not X) is Y` instead of `not (X is Y)` (the same
  misplaced-precedence bug class as the `not X in Y` fix above, but for
  `is` tests - found because this exact round's own doc comment
  incorrectly claimed it "already worked correctly" without testing it).

`prometheus.prometheus.node_exporter` now runs clean end-to-end
(idempotent, service verified live) - see `ROLES_TESTED.md`.

---

`0.9.291`-`0.9.311` (a twenty-first real-host round, and the first ever to
exercise a real Ansible **Collection** rather than a plain Galaxy role
install: `prometheus.prometheus`, specifically its `node_exporter` role and
the shared internal `_common` role every exporter role in that collection
delegates its actual install/configure logic to. This turned into by far
the deepest single-role investigation of any round so far - 16 distinct real
engine bugs found and fixed, several of them entirely new engine features,
not just bug fixes, because collection-role invocation had never been
exercised at all before this round:

- Collection-role `namespace.collection.role` FQCN resolution was entirely
  unimplemented - `resolve_role_dir` only ever searched a playbook's own
  `roles:/` directory. Implemented against the real locations `ansible-
  galaxy collection install` and real Ansible itself search:
  `ANSIBLE_COLLECTIONS_PATH`, a playbook-adjacent `collections/` dir, and
  the two real default install locations.
- `include_role:`'s `tasks_from:` param (loading `tasks/<name>.yml` instead
  of `tasks/main.yml` - the standard way a collection's shared/generic role
  exposes several distinct entry points from one role directory) was
  entirely unimplemented.
- `ansible_parent_role_names` (the ancestor role-name chain leading to an
  `include_role:` call - several real collections guard a shared role
  against direct invocation with it) was entirely unimplemented, and once
  added, needed fixing at TWO separate layers: `execute_include_tasks`
  never propagated `role_name`/`role_parent_names` onto tasks loaded via a
  role's own `include_tasks:` step (so a role reaching `include_role:`
  indirectly, through an intermediate `include_tasks:`, lost its own parent
  chain entirely), and a related pre-existing bug where `include_role_dir`
  itself got anchored to whatever tasks file was currently being parsed
  instead of staying anchored to the original playbook root - any
  `include_role:` called directly from within a role's own `tasks/main.yml`
  (not just reached via a further `include_tasks:`) was already silently
  broken by this before this round, just never previously exercised by any
  role tested in 20 prior rounds.
- `ansible_collection_name` (the invoking role's own `namespace.collection`
  - used by several real collections to strip their own namespace prefix
  back off `ansible_parent_role_names`) was entirely unimplemented.
- Real Ansible searches a role task's ENTIRE parent-role chain (not just
  the currently-executing role's own `files:`/`templates:` dir) for a
  relative `copy:`/`template:` `src:` - entirely unimplemented, needed for
  `_common`'s own shared service-unit template task, whose `src:` resolves
  to a file in the CALLING role's own `templates/` dir, not `_common`'s own.
- The `listen:` handler keyword (declaring a topic a handler responds to)
  wasn't in the task-keyword exclusion list the parser scans when picking a
  task's module name - a handler whose YAML happened to list `listen:`
  before its real module key had "listen" itself picked as the module name
  ("Plugin not available: listen").
- `unarchive:`'s real Ansible default (`remote_src: false` - `src:` names a
  file on the CONTROLLER, transferred to the target before extraction) was
  entirely unimplemented; this plugin always just read `src:` from wherever
  it was actually executing. Fixed the same way `copy:`'s identical gap was
  already solved (SCP-staging a controller-side `src:` to a remote scratch
  path before the plugin ever runs), not by touching the plugin itself.
- Jinja2's native inline ternary (`X if COND else Y`, distinct from
  Ansible's own `| ternary(...)` FILTER, which already worked) was entirely
  unimplemented in the vendored Crinja shard's own parser - fixed by
  reopening `Crinja::Parser::ExpressionParser`/`Crinja::AST`/`Crinja::
  Evaluator` from this codebase (the sanctioned way to extend vendored
  Crinja without editing the gitignored, shards-managed `lib/crinja`
  directly) to add a real `parse_condexpr` grammar layer.
- A `-`/`{{-`/`-}}` whitespace-trim marker on an EXPRESSION tag (as opposed
  to a `{% %}` block tag, which already worked) mistokenized inside
  Crinja's own parser, corrupting the expression into a dangling arithmetic
  minus operator (`'x' -}}` parsed as `'x' - <undefined>`, rendering the
  literal text "undefined"). Worked around via template-text preprocessing
  in `CrinjaRenderer` (stripping the marker and its adjacent whitespace
  before Crinja ever parses it) rather than a real lexer fix; the same
  narrower gap existed independently in this codebase's own hand-rolled
  `{{ }}` mustache-span scanner too (fixed there directly, simpler since
  that scanner never did real whitespace-control to begin with).
- `select`/`reject` (testing bare list elements directly against a named
  test, as opposed to `selectattr`/`rejectattr`, which already existed)
  were entirely unimplemented - fell through to the unknown-filter
  passthrough, silently returning the list completely unchanged regardless
  of the test.
- Real Python/Jinja2 string LITERAL backslash-escaping (`\\` -> `\`, the
  standard way a regex pattern like `\d+` gets written as a string literal
  `'\\d+'` when the surrounding YAML itself does no escaping of its own,
  e.g. inside a `>-` folded scalar) was never applied when extracting a
  quoted filter argument - a `reject('match', '.+:\\d+$')` pattern arrived
  as the two raw characters `\\d` instead of the real escaped-backslash-
  plus-digit-class `\d`, so the regex only ever matched a literal `\d`
  substring, never a real digit run.
- Python's `dict.get(key, default)` method-call syntax on a literal dict
  base (`{'x86_64': 'amd64', ...}.get(key, default)`, a common architecture-
  name-mapping idiom) was entirely unimplemented, and needed fixing at TWO
  separate layers once implemented: `VariableLookup#resolve`'s own
  top-level dispatch checked `expr.includes?("[")` for the WHOLE
  expression before checking for a `.` - a `[` anywhere (even nested
  inside the `.get()` call's own key ARGUMENT, e.g. `ansible_facts
  ['architecture']`) always routed the whole expression to indexed-access
  handling instead of the dotted method-call dispatch its own top-level
  structure actually needed; the identical bug existed independently one
  layer up in `ExpressionEvaluator#evaluate_bracket_or_dict_expr` too (same
  blunt any-position `[` check, fixed the same way: only a top-level `[`
  that comes BEFORE any top-level `(` means "this whole expression is
  itself indexed"). A downstream consequence: this exact bug corrupted a
  GitHub release binary's download URL into a 404 (wrong architecture
  segment), so it was found and fixed before the `dict.get()` feature
  itself could even be verified working end-to-end.
- `regex_replace`'s pattern/replacement arguments never got the same
  `~`-concatenation delegation `default()`'s own argument already had -
  `regex_replace(ansible_collection_name ~ '.', '')` (stripping a role's
  own collection-namespace prefix off its FQCN, used to compute a short
  systemd service name) left the pattern as the literal unparsed text
  "ansible_collection_name ~ '.'" instead of the real computed
  "prometheus.prometheus.", so nothing ever matched.

`node_exporter` ended the round NOT fully clean: it got all the way through
role resolution, the full binary download/checksum-verify/unpack/install
pipeline, and correctly locating its own service-unit template in the
CALLING role's `templates/` dir - but the template itself uses Jinja2's
`namespace()` builtin (mutable state that survives across `{% for %}` loop
iterations, computing a systemd `ProtectHome=` setting from whether any
mount is under `/home`), which is likely entirely unimplemented in Crinja
and wasn't investigated further this round. See `CRINJA.md` (not committed,
a handoff document of Crinja-specific findings from this round) for full
detail on this and the other Crinja-specific bugs above.

Full `crystal spec` suite (1050 examples) passes clean throughout. All
fixes short of the final `namespace()` blocker verified live against a real
Atlantic.net host pair, real ansible-playbook as the correctness baseline
throughout (confirmed clean/idempotent on the real py host before treating
any divergence as a crystal-ansible bug).

---

`0.9.289`-`0.9.290` (a twentieth real-host round: `weareinteractive.nginx`/
`mysql`/`redis`/`users` and `Stouts.iptables`/`timezone`, two more new
authors, all 6 role names confirmed to exist via the GitHub API up front.
5 of the 6 turned out to be external blockers, confirmed by reproducing
each one on real `ansible-playbook` before treating it as such: `nginx`'s
own nginx.org apt-key setup fetches a now-invalid/stale GPG key
(`NO_PUBKEY`, apt refuses the unsigned repo); `mysql`/`redis`/`iptables`/
`timezone` all share the exact same `tasks/main.yml` template using the
legacy `include:` directive, removed entirely from current ansible-core
(same failure mode already documented repeatedly for `phpmyadmin`/`gogs`/
pre-patch `glusterfs`) - real `ansible-playbook` refuses to even parse any
of the four. `users` was also initially blocked by a related but distinct
issue - real ansible-core 2.19's own stricter conditional-result
enforcement rejects the role's aging `when: users_group is defined and
users_group` pattern (a non-boolean `when:` result) outright; routed
around via the documented `ANSIBLE_ALLOW_BROKEN_CONDITIONALS=true` escape
hatch rather than skipping the role, since it's a real ansible-core knob
for exactly this scenario, not a workaround specific to this benchmark.

`weareinteractive.users` found and fixed 2 real bugs:

- `default(a ~ b ~ c)` - a Jinja2 `~`-concatenation expression as the
  `default()` filter's own argument - was unhandled; only `+`/`-`-
  concatenation defaults had already been fixed to delegate to the full
  ExpressionEvaluator. Hit by the role's own `user.home | default(
  users_home ~ '/' ~ user.username)` (computing a user's home path) -
  the whole default argument resolved to nil, collapsing the home path
  to an empty string and failing the next task outright ("File does not
  exist: .").
- `authorized_key:` wasn't idempotent for an empty `key:` value (a
  legitimate real-world case: the role's own `key: "{{ user.
  authorized_keys | default([]) | join('\n') }}"` renders empty for any
  user with no keys configured) - an empty key's signature is nil, and
  blank lines get filtered out of the existing-lines comparison list
  before the signature check runs, so it could never recognize its own
  previous no-op write and reported `changed: true` on every single run
  forever. Real Ansible's own module treats an empty key as a true
  no-op and doesn't even create the file - verified live, fixed to
  match exactly.

Verified live: idempotent (`changed: 0` on rerun, matching real
ansible-playbook exactly), `id alice`/`id bob` confirming real user/group
state. Full `crystal spec` suite (1025 examples) passes clean throughout.

---

`0.9.279`-`0.9.288` (a nineteenth real-host round, back on `robertdebock.*`
plus one new author: `nginx`, `mysql`, `docker_ce`, `users`, `phpmyadmin`,
and `Oefenweb.fail2ban` - this time every role name was confirmed to exist
via the GitHub API up front, avoiding round 18's 4 Galaxy-404 misses. Real
`ansible-playbook` was the correctness baseline throughout, run on a
separate host from crystal-ansible via the same terraform pair pattern.
`nginx`/`docker_ce` came back clean with zero engine bugs (nginx's first
run hit a false-alarm apt 404 purely from uneven apt-cache freshness
between the two benchmark hosts, not a real divergence). The other four
roles found 9 real bugs:

- `community.general.ini_file` was entirely unimplemented (`mysql`) -
  hit by robertdebock.mysql's own `Configure mysql server`/`Configure
  mysql client` tasks, which silently skipped (warning, not failure),
  cascading into a missed `Restart mysql server` handler notification
  since the task that would have notified it never ran at all.
- `include_tasks:`/`include_role:` with a scalar-template `loop: "{{
  var }}"` (as opposed to a literal YAML list) never resolved at all
  (`users`) - the include ran exactly once with no item bound, so a
  custom `loop_control.loop_var` (`group`/`user`) resolved as
  "undefined" throughout the included file. The general per-task
  execution path already had the full loop-template fallback chain;
  `execute_include_tasks`/`execute_include_role` (and their own
  parser-side loop parsing) never did.
- `or`/`and` inside a plain `{{ }}` span always coerced to the literal
  text "True"/"False" regardless of operand type (`users`) - correct
  only when every operand is itself a boolean condition (comparisons/
  is-tests), but real Jinja2's `or`/`and` are value-selectors: `X or Y`
  returns X itself when truthy, not the word "True". Hit by
  robertdebock.users' own `groups: "{{ user.groups | default([]) |
  join(',') or omit }}"` - `useradd: group 'True' does not exist`.
- `getent:` never failed a single-key lookup that isn't in the database
  (`users`) - real Ansible's own default (`fail_key: true`) fails
  outright, which robertdebock.users' own `block:`/`rescue:` (falling
  back to `/home` for a to-be-removed user) depends on to trigger its
  rescue path at all.
- `password_hash` filter was entirely unimplemented in both evaluators
  (`users`) - `password: "{{ plaintext | password_hash('sha512') }}"`
  (the standard way any role sets a user's password) silently passed
  the plaintext straight through, landing verbatim in `/etc/shadow`.
- `type_debug` filter was entirely unimplemented in both evaluators
  (`phpmyadmin`, via its `robertdebock.httpd` dependency) - failed
  `httpd_additionnal_modules | type_debug == "list"`'s own sanity
  assert regardless of the variable's actual (correct) type.
- `unarchive:`'s `extra_opts:` param was documented as unimplemented and
  silently dropped (`phpmyadmin`) - `extra_opts:
  ['--strip-components=1']` (the standard way to unpack a GitHub-
  release-style tarball with one wrapping top-level directory) had no
  effect, so `dest/index.php` was actually one level deeper and
  missing entirely.
- Implementing `extra_opts` then exposed a second, independent bug:
  the tar-based idempotency check used `tar --compare`'s raw exit code,
  which GNU tar always makes nonzero under `--strip-components` (a
  benign "Cannot stat: No such file or directory" warning for the
  now-empty stripped root path) - every rerun re-extracted and reported
  `changed: true` forever. Real Ansible's own `TgzArchive#is_unarchived`
  never trusts the raw exit code either; it parses `--compare`'s output
  line by line against a specific regex allowlist (owner/group/mode/
  mod-time/missing-file/symlink diffs) and explicitly ignores this
  exact warning pattern - reimplemented the same way, verified
  byte-for-byte against the real module's own source.
- Python's `SEP.join(iterable)` STRING-METHOD-CALL syntax (the reverse
  argument order of the `list | join(sep)` Jinja FILTER) was entirely
  unimplemented (`fail2ban`) - `' '.join(fail2ban_dependencies).split()`
  (building an apt package list) resolved to nil/"undefined" outright,
  since the receiver of `.join()` here is a quoted string LITERAL, not
  a variable name, and the existing dotted-path resolver only ever
  looked up `parts[0]` as a variable. Fixing this exposed one more
  independent recursive-re-templating copy: each list element handed to
  `.join()` needed its own re-render before joining (fail2ban_
  dependencies' 2nd element is itself a ternary-computed template), not
  just the list variable as a whole.

All fixes verified live: mysql/users/phpmyadmin/fail2ban all ended
idempotent (`changed: 0` on rerun) with real service health confirmed
(`systemctl is-active`, `mysql -u root -p... -e 'select 1'`, `curl` 200 on
phpmyadmin's own index.php, `fail2ban-client status` showing the sshd
jail). Full `crystal spec` suite (1023 examples) passes clean throughout.

---

`0.9.271`-`0.9.278` (an eighteenth real-host round: `robertdebock.*`, a
different, prolific role author than every prior round - chosen
specifically to exercise different code idioms. Of the 6 roles on the
shortlist, 4 (`grafana`, `minio`, `bind`, `postgresql`) turned out not to
exist on Galaxy or GitHub at all under those names - confirmed via both
the Galaxy API and a full listing of robertdebock's ~300 GitHub repos,
not just a single lookup miss. The remaining 2, `zabbix_server` and
`zabbix_agent`, pulled in 8 more robertdebock roles as real dependencies
(`bootstrap`, `selinux`, `container_docs`, `mysql`, `ca_certificates`,
`zabbix_repository`, `core_dependencies`) per the roles' own
`molecule/default/prepare.yml`, all installed and orchestrated together
in one playbook - real `ansible-playbook` ran the whole chain clean and
idempotent from the start, used as the correctness baseline throughout.
crystal-ansible found and fixed 8 real bugs getting there, several of
real functional consequence, not just cosmetic:

Jinja2's own type tests (`is boolean`/`is number`/`is string`/`is
integer`/`is float`/`is iterable`/`is none`) were entirely unimplemented
- only `is mapping`/`is sequence` existed before (from an earlier
round). Failed multiple roles' own defaults-sanity `assert:` blocks
(`bootstrap_wait_for_host is boolean`, `mysql_bind_address is not
none`), a pattern robertdebock's roles use pervasively that no prior
round's author happened to exercise.

The engine's own internal "undefined" sentinel string (used pervasively
as this codebase's stand-in for a real Undefined type, per many prior
fixes in this file) wasn't recognized by the `default()` filter's own
undefined-check, so a chained dict-lookup miss (`_bootstrap_packages[key]
| default(...) | default(...)`) resolved to the literal text "undefined"
instead of falling through to the real default - `bootstrap_facts_
packages` ended up as the single string "undefined", used directly as a
`loop:` value, so `package:` tried (and failed) to install a package
literally named "undefined".

Python-style `.split()` with NO arguments (whitespace-run split) wasn't
handled at all in the string-method-call code path (only the quoted-arg
form, `.split('x')`, was - fixed in an earlier round for a different
role). And a dotted-access BASE variable that's itself still-unrendered
`{{ }}` text (a role var computed from another var/dict lookup) wasn't
re-rendered before `.split()`/`.attr` walked off of it - one more
independent copy of the "recursive re-templating" bug class this file
has documented repeatedly, this time at the dotted-access base-fetch
call site specifically (every other call site already had this guard;
this one didn't).

`ansible.builtin.systemd`'s `daemon_reexec: true` param (distinct from
`daemon_reload`) wasn't recognized at all, failing outright instead of
running `systemctl daemon-reexec` - robertdebock.mysql's own handler
uses exactly this, with no other params.

`apt:`'s `deb:` parameter (install a local/URL .deb file directly,
distinct from `name:`) was entirely unimplemented - this closes out a
"looks unimplemented, unverified" flag left in `ROLES_TESTED.md` since
an earlier round (puppet/munin-node/phpmyadmin/adminer), now confirmed
real via robertdebock.zabbix_repository's own repo-install task.
Implemented: downloads a URL if given one, reads the .deb's own name/
version via `dpkg-deb -f` for idempotency, installs via `apt-get
install` (not a bare `dpkg -i`) so apt resolves the .deb's own
dependencies too.

`ansible.builtin.meta: flush_handlers` was rejected at parse time
entirely (a previously-documented scope cut - only `clear_facts`
parsed). Implemented for real, and NOT just a display-order cosmetic
fix here: several robertdebock roles (mysql, selinux,
zabbix_repository, zabbix_server, core_dependencies) use it
deliberately mid-role - flushing an apt-cache-update handler BEFORE a
later task that needs the freshly-added repo's package list, in
particular. Skipping it silently deferred every notified handler to the
very end of the play instead, which caused a genuine functional
divergence from real ansible-playbook for zabbix_server specifically: a
package install task failed "Unable to locate package" because the
repo-add handler's own cache refresh hadn't run yet by the time it was
needed.

Implementing flush_handlers immediately exposed a second, separate
latent crash: `meta:` tasks (both `clear_facts` and the new
`flush_handlers`) were never excluded from the plugin pre-upload path,
so any playbook using `meta:` against a genuine remote SSH host
crashed the whole process outright trying to look up a nonexistent
"_meta" plugin binary. Every prior use of `meta:` in this engine's own
specs ran against `localhost` only, which skips that whole pre-upload
path entirely - this bug could only ever be found by a real multi-host
SSH round exercising `meta:`, exactly what this one is.

Finally, an idempotency bug in `mysql_user`'s `update_password: always`
(real Ansible's own default, which the role leaves unset): previously
issued `ALTER USER ... IDENTIFIED BY` unconditionally on every run and
reported `changed: true` even when the password already matched - a
real divergence from real ansible-playbook, which stayed fully
idempotent (`changed=0` on rerun) throughout. Fixed by comparing
password hashes entirely server-side
(`authentication_string = PASSWORD(?)`, a boolean 0/1) rather than
pulling the raw hash value back through the driver - discovered
mid-fix that the vendored `crystal-mysql` driver's type table has no
`read` implementation at all for the LONGTEXT wire type that column
actually is (`MySql::Type::LongBlob`), so a first attempt at reading it
directly always raised and silently fell back to "assume it needs
updating," defeating the fix before the server-side-comparison rewrite.

Final state, re-verified end to end on a completely fresh host pair
(not the one used for the debugging iterations above): full playbook
run succeeds, rerun reports `changed=0` (fully idempotent),
`zabbix-server`/`zabbix-agent`/`mysql` all `systemctl is-active` =
active, ports 10050/10051 both listening. One apt-mirror 404 hit during
verification (a stale Ubuntu archive snapshot for an old mysql-8.0
`libmysqlclient21` build) - confirmed external/transient via `apt-get
update` + retry, the same failure mode already documented elsewhere in
this file, not a crystal-ansible issue.

---

`0.9.269`-`0.9.270` (a seventeenth real-host round, at the user's
explicit request: `geerlingguy.glusterfs`, single-instance first, then
a genuine 3-node cluster - real `ansible-playbook` orchestrating one
cluster, `crystal-ansible` orchestrating a separate one, both via real
SSH to 3 real nodes each, both forming actual replicated GlusterFS
volumes rather than just installing the daemon). Single-instance
install passed clean on the first try. Two external blockers hit and
patched locally (not crystal-ansible bugs, confirmed by reproducing on
real ansible-playbook too): the role's own tasks/main.yml uses the
legacy `include:` directive, removed from current ansible-core -
patched to `include_tasks:` (same failure mode already documented for
`geerlingguy.phpmyadmin`/`geerlingguy.gogs`); and `glusterfs_ppa_
version`'s own default ("7") has no PPA release for Ubuntu jammy -
overridden to "9".

The 3-node cluster phase (a hand-written peer-probe + volume-create/
start play, not part of the role itself - the standard shape every
real multi-node Ansible playbook uses) found two real engine bugs.
`hostvars[<name>]`, Ansible's magic variable for looking up any
OTHER inventory host's own vars, was entirely unimplemented - any
`hostvars['node2'].ansible_host` lookup silently resolved "undefined",
so `gluster peer probe {{ hostvars['node2'].ansible_host }}` probed a
bogus hostname instead of the real peer's IP, breaking cluster
formation outright. Implemented, sourced from the whole inventory (not
just the current play's own target hosts, since the peer-probe play
here only targets node1 but needs node2/node3's hostvars too).
Separately, `evaluate_in`'s own naive string split on " in " wasn't
quote-aware, so a quoted literal that itself contains the word "in" as
its own word (`'already in peer list' not in probe2.stdout` - `gluster
peer probe`'s own real idempotency-check message for an
already-connected peer) split at the "in" INSIDE the quotes instead of
the real operator, evaluating `changed_when` as true on every single
run regardless of the actual output - a real idempotency bug for any
multi-node cluster playbook. Fixed by reusing the same quote/paren-
depth-aware splitter already used for and/or in the same file.

Final state, re-verified after both fixes: both 3-node clusters fully
idempotent on rerun (`changed=0`), `gluster peer status`/`volume
status gv0` all green on both, and cross-node file replication
functionally verified (a file written through the mount on node1 reads
back correctly from node2).

`0.9.267`-`0.9.268` (a sixteenth real-host round: `geerlingguy.hdparm`,
`geerlingguy.daemonize`, `geerlingguy.svn`, `geerlingguy.blackfire` -
all new). `hdparm` passed clean on the first try (byte-identical
`hdparm.conf`). `daemonize` needed `build-essential` as a pre-task
prerequisite on a bare image (real ansible-playbook needs it too -
not a role or engine bug, an environment gap this benchmark harness's
throwaway hosts don't come with).

`svn` found a THIRD bug in `extract_command_special_params`, this time
over-matching rather than under-matching: with two separate `key={{
x }}`-shaped trailing params on the same command (`chdir={{
svn_repository_home }} creates={{ svn_repository_home }}/testrepo/
README.txt`), the lazy `\{\{.*?\}\}` alternative could backtrack
straight through the entire second param - including the space and
braces separating it from the first - to reach ITS closing `}}`,
silently absorbing it into the first param's value. Two independent
regex-based attempts at this extraction (0.9.261, this file's own
0.9.259-0.9.265 entry) each had a real bug in opposite directions for
the same underlying reason: a bare `\{\{.*?\}\}` can't be trusted to
stop at a single template block's boundary when backtracking is
involved. Replaced the whole regex-matching loop with a proper
brace-depth-tracking tokenizer, reusing the same scanner
`parse_inline_kv_params` already uses for free-form `key=value` args -
splitting on whitespace *outside* any template span gets every param
boundary right regardless of how many `{{ }}` blocks appear anywhere
else in the string, with no backtracking ambiguity to get wrong in
either direction.

`blackfire` found `apt_key:`'s idempotency check only ever ran when an
explicit `id:` param was given - `url:`/`data:` (the overwhelmingly
common real-world shape) always re-ran `apt-key add` and reported
`changed: true` on every single run, never converging. Real Ansible's
apt_key: derives the key's own fingerprint from the fetched key
material itself even without `id:`. Fixed by parsing every fingerprint
out of the fetched key file via a pure dry-run `gpg --import-options
show-only --import` (never touches any real keyring) before deciding
whether to import.

`0.9.266` (a fifteenth real-host round: `geerlingguy.java`,
`geerlingguy.containerd`, `geerlingguy.helm`, `geerlingguy.gogs` -
all new; `geerlingguy.registry`/`.n8n`/`.k3s` don't exist on Galaxy).
`java` and `containerd` both passed clean on the first try (the
latter's own `config.toml` byte-identical to real Ansible's). `gogs`
isn't testable at all - role version 1.4.3 uses the legacy `include:`
directive, removed entirely from current ansible-core (real
`ansible-playbook` refuses to parse the role), the same failure mode
already documented for `geerlingguy.phpmyadmin`.

`helm` found one bug, but a high-value one: `ConditionalEvaluator#
evaluate` checked a leading `not ` prefix BEFORE splitting on any
top-level ` and `/` or ` at all, so `not X or Y` negated the ENTIRE
remaining string as a single unit (`not (X or Y)`) instead of binding
`not` only to the immediate next term (the correct `(not X) or Y`,
matching real Python/Jinja2 operator precedence where `not` binds
tightest and `or` loosest). The role's own "Download helm." task
gates on `when: not helm_check.stat.exists or "..." not in
helm_existing_version.stdout` - with the binary not yet installed,
`not helm_check.stat.exists` alone is already true and real Ansible's
`or` short-circuits there without evaluating the second (undefined-
stdout) clause; here it evaluated false instead, silently skipping the
install. Reordered to split on `or` first (lowest precedence), then
`and`, then handle `not` last - this also fixes mixed `a and b or c`
chains nesting correctly via the same recursive splitting, not just
the specific `not`-prefixed case. Verified this was hand-rolled-
evaluator-only: Crinja's real recursive-descent parser (backing `.j2`
files) already gets `not`/`and`/`or` precedence right by construction.

`0.9.259`-`0.9.265` (a fourteenth real-host round: `geerlingguy.
composer`, `geerlingguy.solr`, `geerlingguy.passenger`, `geerlingguy.
drupal` - all new): `composer` and `solr` both passed clean after
fixes; `passenger` and `drupal` both confirmed external blockers
(reproducing identically on real ansible-playbook), not chased
further - `passenger`'s own apt-key fetch uses a stale key ID no
longer matching the actual repo's signing key, and `drupal`'s
`composer require` task explicitly opts out of `become:` (assumes a
non-root deploy user), which this benchmark harness's always-root
connection violates for both engines equally.

`composer` found two bugs. `get_url:`'s own `native_checksum`
algorithm case only explicitly handled md5/sha256 - every other
algorithm (sha1/sha224/sha384/sha512) silently computed SHA1 instead
regardless of what was requested, so the role's own installer
`checksum: "sha384:..."` verification always reported a mismatch on a
download that was actually correct. Separately, `command:`/`shell:`/
`unarchive:`'s `creates=`/`removes=`/`chdir=` never expanded a leading
`~` before checking the filesystem - the role's own `composer_home_
path` default is the literal string `'~/.composer'`, so the idempotency
check against `~/.composer/vendor/x` could never match a real path and
the task reported changed forever.

`solr` found six bugs, chained across a single 5-task include file -
each fix unblocked the next task rather than the role being "mostly
clean" after the first one. (1) The `creates=`/`removes=`/`chdir=`
trailing-param extraction regex's value alternative only matched a
*single* `{{ }}` brace pair; it happened to keep working when a value
had a second template block further along (the lazy match could
backtrack into it), but failed outright for exactly one template block
followed by trailing literal text with no other `}}` anywhere else in
the string (`creates={{ solr_install_path }}/bin/solr`) - extraction
silently never ran, and the raw untemplated text stayed glued onto the
command. (2) Local-connection `become_user:` plugin execution always
ran the compiled plugin binary straight from wherever crystal-ansible
itself was installed, breaking the moment that install directory
wasn't traversable by become_user (a root-owned `/root/...` install is
a common real-world case) - not actually a sudoers policy denial
despite sudo's own error text reading like one, but a plain EACCES on
the install directory's own restrictive mode; fixed by staging plugin
binaries to the same world-traversable directory the SSH path already
uses. (3) Crinja had no support at all for Python's `.split(...)`
method-call syntax on strings (`solr_version.split('.')[0] < '9'`,
used inside a role default's own `{% if %}`) - and since
`CrinjaRenderer#render`'s blanket exception handler falls back to
returning the entire original template unrendered on ANY failure, this
corrupted every task param built from that variable, not just the one
expression. (4) Crinja's `trim_blocks` (always enabled, matching real
Ansible's own Jinja2 default) incorrectly ate a literal space, not just
a newline, whenever the text right after a block tag had no newline in
it at all - real Jinja2's trim_blocks only ever removes one newline
after a block tag and does nothing otherwise; this glued two adjacent
`cp` command arguments into one. (5) `file:`'s directory creation
applied owner/group/mode only to the final leaf path of a newly-created
nested directory tree, leaving any missing *intermediate* ancestor
directories root-owned - which mattered for real when a later
`become_user:` task needed write permission on one of those ancestors
to modify its own contents and got denied.

`0.9.257`-`0.9.258` (a thirteenth real-host round: `geerlingguy.
filebeat`, `geerlingguy.fluentd`, `geerlingguy.mailhog`, `geerlingguy.
ruby` - all new): `filebeat` and `mailhog` both passed clean (the
latter's real HTTP service verified live via `curl`, not just task
status). `fluentd`'s own td-agent apt repo
(packages.treasuredata.com) has no valid Release file for Ubuntu
jammy, reproducing identically on real ansible-playbook - the same
external-repo failure class already seen with `geerlingguy.varnish`,
not chased further. `ruby` found two real bugs: `ansible.builtin.gem`
(Ruby gem management) had **no plugin at all** - both "Install
Bundler." and "Install configured gems." silently skipped outright
("Plugin not available"). Implemented (`plugins/gem.cr`, shelling out
to the real `gem` CLI, matching real Ansible's own module's approach)
supporting name/state (present/absent/latest)/version/executable
(fluentd's own td-agent-bundled `fluent-gem` needs this)/user_install/
bindir, idempotent via `gem list -i "^name$" [-v version]`. Separately:
`apt:` unconditionally reported `changed: true` whenever `apt-get
install`'s own exit code was 0, without checking whether it actually
did anything - a requested name that's a purely *virtual* package
already satisfied by something else installed (`rubygems` isn't a real
package on modern Debian/Ubuntu at all, only a virtual one `ruby`'s own
package `Provides:` - confirmed via `apt-cache showpkg rubygems`'s own
"Reverse Provides: ruby") has no real `dpkg -l` entry for the
is-it-already-installed pre-check to find, so it always fell through to
"needs install," and apt-get's own exit code is 0 either way regardless
of whether it did real work. Fixed by parsing apt-get's own end-of-run
summary line ("N upgraded, N newly installed") post-execution, the same
"trust the tool's own report of what happened, not just its exit code"
approach `pip:`'s `state: latest` already uses.

`0.9.254`-`0.9.256` (a twelfth real-host round: `geerlingguy.
tomcat6`, `geerlingguy.exim`, `geerlingguy.git`, `geerlingguy.swap` -
all new): `git` (incl. its full download/build-from-source path, not
just the already-installed default) and `exim` both passed clean.
`tomcat6` isn't testable at all - the `tomcat6` package doesn't exist
on Ubuntu 22.04 (only `tomcat9`), and both engines also independently
reject the role's own deprecated `state: installed` before ever
reaching that task, confirmed identical on real ansible-playbook.
`swap` found a chain of real bugs, most severe found in a while: the
`mount:` module never recognized `name:`, real Ansible's own original
(still commonly used, predating `path:`) alias for `path:` - the
role's own "Manage swap file entry in fstab." task (`mount: {name:
none, src: ..., state: ...}`) always failed outright with "missing
required argument: path and state are both required" even though both
were given. Fixing that surfaced a much deeper gap: `*`/`/`/`//`
arithmetic were **entirely unimplemented anywhere in the plain `{{ }}`
evaluator** - even a bare `{{ 10 / 2 }}` rendered the literal string
"undefined" (only `+`/`-`/`~` had top-level operator support before).
The role's own `check-size.yml` does `(stat.size / 1024 / 1024) | int`
to compare an existing swap file's size in MB against the configured
one - the whole division chain resolving undefined meant this
comparison always differed, silently deleting and recreating the swap
file on every single run instead of converging (only caught by
re-running the role twice, per this project's own established
discipline). Implementing `*`/`/`/`//` (verified digit-for-digit
against real Python's own jinja2.Environment: `/` always produces a
float even when evenly divisible, `*` preserves int when both operands
are int, `//` floors to int, and `*`/`/` bind tighter than `+`/`-`)
surfaced two more, each masking the next: the `int` filter always
converted its input to a decimal-point STRING first ("256.0"), and
Crystal's own strict `String#to_i64?` rejects any decimal point
outright, silently defaulting to 0 for ANY float input, not just one
arriving via division (Crinja's own separate `int` filter, for real
`.j2` template files, already had this right); and a bare numeric
literal (`{{ 5 }}`, or a literal float piped straight into a filter
with no variable or arithmetic involved, `{{ 5.7 | int }}`) was never
checked anywhere in the dispatch chain **on its own** - only ever as an
*operand* inside a larger `+`/`-`/`*`/`/` expression - so it fell
through to a plain variable-name lookup on the literal digit text
itself, always undefined. The bare `when:`/`assert:`-condition
evaluator (`ConditionalEvaluator`, entirely separate from the `{{ }}`
one) had its own independent copy of the same `*`/`/`-recognition gap
too - a bare `when: n / 2 == 5` never routed to the arithmetic-capable
evaluator at all.

An eleventh real-host round (`geerlingguy.puppet`, `geerlingguy.
munin-node`, `geerlingguy.phpmyadmin`, `geerlingguy.adminer` - all new)
found **no crystal-ansible bugs at all** - `munin-node` and `adminer`
(the latter including its `geerlingguy.apache` dependency's config-
writing path, functionally verified serving `adminer.php` via `curl`)
both passed byte-identical and idempotent on the first try. The other
two hit real, confirmed-external blockers, not engine gaps: `puppet`'s
own apt-key task fails identically on real `ansible-playbook` too -
Puppet Labs' own published GPG key for the configured `puppet_version`
has expired upstream. `phpmyadmin`'s pinned role version (1.3.3) uses
`include:`, a directive real modern `ansible-core` (2.17) has removed
entirely - real `ansible-playbook` refuses to even parse the role,
making a real-host baseline comparison impossible with current
ansible-core; crystal-ansible is more lenient and still supports the
legacy directive, running the role further before hitting the
already-documented `geerlingguy.mysql` dependency's `unix_socket`/
`auth_socket` auth gap (see the `crystal-mysql` limitation below), not
a new issue.

`0.9.250`-`0.9.253` (a regression-verification round, not a new-role
round - re-running `dev-sec.os-hardening`, previously marked clean back
in an earlier session, specifically to stress-test the truthiness/bool
fixes from `0.9.240`-`0.9.249`): none of the 4 real bugs found were
regressions from that work - all pre-existing gaps this specific role's
own task shapes simply hadn't exercised before. `with_flattened:` (the
short lookup-plugin-name alias real roles actually write - os-
hardening's own "find files with write-permissions for group"/"change
system accounts" tasks both use exactly this spelling, never the FQCN
form) was **entirely unrecognized as a loop keyword** - missing from
both the loop-source extraction and the special_keys allowlist that
decides "is this a keyword or the module name" - so the whole task ran
exactly ONCE, not looped at all, with `item` completely unbound
(rendering the literal string "undefined" into the command). Fixing
that surfaced two more real bugs in the SAME resolver
(`TaskExecutor#resolve_loop_flattened`, also reachable via the FQCN
form) that a misleading, dead, never-called duplicate in
`loop_resolver.cr` had made look already-correct on a first read: every
literal string source (`'/usr/local/sbin'`, not `{{ }}`-templated at
all) was silently DROPPED rather than contributed as one item; and a
filter-chain source (`"{{ x | difference(y) | list }}"`, not a bare
`{{ var }}` reference) rendered to one JSON-array-shaped STRING pushed
as a single item instead of being evaluated and flattened - `user:
name={{ item }}` then tried to `useradd` one literal string containing
every username joined by commas inside brackets. Separately: a real
Jinja2 `in` test against a *variable-bound* list inside `{% if %}`
(`'amd' in ansible_facts.processor`) failed to parse outright -
`TemplateActionPlugin#rewrite_in_expr` (the `in`/`not in`-to-`is
in(...)` rewrite Crinja itself needs, since it has no native infix `in`
operator) only ever recognized a `[...]` literal or a `(...)` tuple as
the right-hand container, never a bare variable/dotted-path reference -
by far the more common real-world shape. `os_hardening` now passes
`failed=0` and is fully idempotent (`changed=0` on rerun);
`geerlingguy.kibana`/`geerlingguy.supervisor` were re-verified clean
end to end too (byte-identical config, idempotent, `supervisorctl
status` functionally authenticating with the `hash`-filter password).
`konstruktoid.hardening` locked itself out of SSH mid-run on the REAL
`ansible-playbook` baseline host (port 22 specifically closed, ICMP
still responding - sshd or ufw, not a network drop) - confirmed not a
crystal-ansible-side issue (only the python host was affected) and not
chased further; abandoned for this round per the user's call, given
`os_hardening` had already produced strong signal.

`0.9.249` (a proactive audit pass, not a real-host round - following
`0.9.244`'s Crinja `Value#truthy?` fix, checked whether the same
empty-container-truthiness bug class had independent copies elsewhere,
the way recursive re-templating turned out to have several): all 24 of
Crinja's own `Value#truthy?` call sites (`{% if %}`, `{% for x in y if
x %}`, `and`/`or`/`not`, `select`/`reject`, `default(fallback, true)`,
etc.) verified correct now that the fix lives in the one shared method -
Crinja centralizes truthiness through a single method, unlike this
codebase's own hand-rolled evaluator, so no further Crinja-side copies
existed. Did find one, though, in a *completely different* evaluator:
`ConditionalEvaluator#evaluate_truthiness`/`#evaluate_value` (the bare
`when:`/`assert:`/ternary-condition path, unrelated to Crinja) had no
`Hash` case at all in its return union (an empty Hash's own `#to_s`,
`"{}"`, is a non-empty *string* - always truthy) and no `Array` case in
its own truthiness `case` either (silently falling through to an
unconditional `else -> true`) - `when: my_list` with `my_list: []` (or
`my_dict: {}`) always ran the task, verified directly against real
Python's own `bool([])`/`bool({})`. Fixed by checking Hash/Array
emptiness directly against the resolved `JSON::Any` (via
`VariableLookup#resolve`, the same simple/dotted/indexed resolver `{{
}}` substitution already uses) before ever going through the lossy
union conversion - covers bare variables, dotted paths, and (since
inline ternary already delegates its own condition to
`ConditionalEvaluator`) `'x' if my_list else 'y'` too, all in one fix.

Separately (not a bug, a redundancy worth knowing about): this file's
own `real_truthy?`/`pytruthy` filter/`TAG_IF_ELIF` tag-rewriting
machinery in `jinja_filters.cr`/`template_action_plugin.cr` was built
specifically to work around the now-fixed `Value#truthy?` gap, on the
(no-longer-true) assumption that `lib/crinja` couldn't be patched from
outside. It's harmless to leave in place - `real_truthy?` and the fixed
`Value#truthy?` now agree on every case - but it's duplicated logic
that could silently drift out of sync if one is ever edited without the
other. `TAG_IF_ELIF`'s rewrite can't be removed outright regardless (it
also handles real Jinja2 `in`/`not in` infix-test rewriting in the same
pass), just the `| pytruthy` suffix it appends is now redundant.
Simplification candidate for a future session, not urgent.

**No known cross-cutting engine gap is open right now** - but that status
is continuously re-earned, not permanent. Each real-host benchmark round
against a new production Ansible role tends to find more (most recently
15 in the `linux-system-roles` round, `0.9.158`-`0.9.171`: depth-unaware
operator parsing that could stack-overflow, block-level `vars:` never
parsed, a missing `d()` filter alias, dict/array literals unsupported
outside a `+` operand, among others - `git log --oneline --grep=
"0\.9\.1[5-7][0-9]" -E` for the full list). Treat "no gap remains open"
as "none is known right now," not as a claim the search is finished.

`0.9.243`-`0.9.248` (a tenth real-host round: `geerlingguy.clamav`,
`geerlingguy.kibana`, `geerlingguy.logstash`, `geerlingguy.gitlab` - all
new): six real bugs, several engine-wide. `clamav` found `.find(substring)`
(Python's `str.find`, returns the match index or -1) was entirely missing
from `VariableLookup#string_method_call` (only `.split(...)` existed) -
`freshclam_result.stderr.find('locked by another process') != -1` in the
role's own `failed_when:` always resolved to undefined, which compared
truthy against `-1`, so the task's real (and, on Debian, expected)
nonzero exit from freshclam's post-install auto-run always propagated as
a genuine failure instead of being suppressed. `kibana` found Crinja's own
`Value#truthy?` (lib/crinja/src/runtime/value.cr) only special-cased
`false`/`0`/`nil`/undefined, leaving an empty String/Array/Hash truthy -
Python/Jinja2 treats all three as falsy too. This silently broke `and`/
`or` (both operators collapse straight to a Bool via `.truthy?`) wherever
both operands could be empty: `{% if kibana_elasticsearch_username and
kibana_elasticsearch_password %}` (both default to `""`) rendered the
`{% if %}` branch - a live, wrong `elasticsearch.username: ""` pair -
instead of real Ansible's own commented-out `{% else %}` placeholder.
Fixed by reopening `Crinja::Value` (crinja_truthy_ext.cr), the sanctioned
way to extend vendored Crinja without editing `lib/crinja` directly (see
crinja_hash_ext.cr's own doc comment) - verified directly against real
Python's own `jinja2.Environment`, not just the real host. `logstash`
found two bugs: the `to_json` filter (wraps Python's `json.dumps()`) was
entirely unimplemented in both Jinja2 evaluators - `hosts => {{
logstash_elasticsearch_hosts | to_json }}` failed the whole template
render outright (implemented to match Python's own `", "`/`": "` default
separators, not Crystal stdlib's compact `,`/`:`, for a byte-identical
diff); and `command:`/`shell:`'s own trailing `chdir=`/`creates=`/
`removes=`/`executable=` extraction (added the firewall round,
`0.9.234`-`0.9.237`) broke on a *templated* value with internal spaces
(`chdir={{ logstash_dir }}`, the near-universal spacing style - the
`chdir={{x}}` no-space form already worked) - `\S+` only matched up to
the template's own leading space, so the whole extraction silently
failed and the untemplated text stayed glued onto the command, which
then ran from the wrong directory and failed outright even though the
target binary existed. `gitlab` found the deepest bug of the round: a
handler's own `register:`/`changed_when:`/`failed_when:` were entirely
unapplied - `execute_handler_plugin_once` (the handler-only dispatch
path already found missing an action-plugin-render step in the jenkins
round) just returned the raw plugin result, so `register:` on a handler
was silently never stored (invisible to anything downstream, including
a same-named `listen:` follow-up) and `failed_when:`/`changed_when:`
could never override a handler's default pass/fail. geerlingguy.gitlab's
own "restart gitlab" handler (`command: gitlab-ctl reconfigure`,
`failed_when: gitlab_restart_handler_failed_when | bool`) depends on
this: the role hits a real, upstream GitLab-version incompatibility
(`git_data_dirs` was removed in GitLab 18.0, but the role's own
`gitlab.rb.j2` still writes it - confirmed identically failing when
`gitlab-ctl reconfigure` is run directly on both hosts, a role/version-
staleness issue, not a crystal-ansible bug) that `failed_when:` is
specifically meant to suppress; real ansible-playbook reports this
handler as "changed", not failed. Chasing why `| bool` didn't suppress
it surfaced a second, independent bug: the plain `{{ }}` evaluator's own
`bool` filter reused the *general* `#truthy?` helper (correct for
`when:`/`{% if %}` truthiness) instead of real Ansible's own `bool`
filter semantics (`ansible.module_utils.parsing.convert_bool.boolean()`,
non-strict) - a small fixed keyword set for true/false, `false` for
anything else - so ANY non-empty, non-"0"/"false" string filtered
through `| bool` came out `true`. `gitlab_restart_handler_failed_when`'s
own default value is the arbitrary expression *string*
`'gitlab_restart.rc != 0'` (not a recognized keyword) - verified
directly against real ansible-playbook that `{{ 'gitlab_restart.rc != 0'
| bool }}` renders `false`, not `true` (the separate Crinja-side `bool`
filter already had this right).

`0.9.240`-`0.9.242` (a ninth real-host round: `geerlingguy.munin`,
`geerlingguy.samba`, `geerlingguy.supervisor`, `geerlingguy.htpasswd` -
all new). `geerlingguy.samba` passed clean on the first try (a mid-round
apt 404 turned out to be a stale package-list cache on the crystal-
ansible host specifically, from never having run `apt-get update` there
- confirmed environmental by reproducing the exact same 404 with raw
`apt-get install` before a cache refresh, then clean after one).
`geerlingguy.munin` and `geerlingguy.htpasswd` both found the same root
cause: `community.general.htpasswd` had no plugin at all (every
`htpasswd:` task - munin's own admin-user setup, the whole point of the
`htpasswd` role - silently skipped with "Plugin not available").
Implemented from scratch: reads/writes the `user:hash` file format
directly, hashes via `openssl passwd -stdin` (password piped over
stdin, never an argv element) rather than hand-rolling apr1/md5-crypt's
bit-level algorithm, supports `apr_md5_crypt` (default)/`md5_crypt`/
`sha256_crypt`/`sha512_crypt`/`plaintext`, and is idempotent by
recomputing the hash with the existing entry's own salt and comparing
byte-for-byte rather than always writing a fresh (unmatchable) random
salt. Verified independently against `openssl passwd -apr1` directly,
not just self-consistently. `geerlingguy.supervisor` found two real
engine bugs from one template file (`supervisord.conf.j2`): the `hash`
filter (`{{ supervisor_password|hash('sha1') }}`, real Ansible's own
`ansible.plugins.filter.core.hash`, wrapping Python's `hashlib`) was
entirely unimplemented in both the Crinja template pipeline and the
plain `{{ }}` evaluator - the whole template render failed outright;
and a bare boolean interpolated into a `.j2` template (`nodaemon = {{
supervisor_nodaemon }}`) rendered Crystal's lowercase "false" instead
of real Jinja2/Python's capitalized "False" (the plain `{{ }}`
evaluator already had this right via `VariableLookup#format_value` -
only the separate Crinja pipeline's own `Finalizer` was missing a Bool-
specific stringify case, another instance of the two independent
evaluators diverging on the same bug class). A third, cosmetic-only
divergence in the same template was found and left open - see the
narrow-scope-cuts list below.

`0.9.239` (a fourth extension of the eighth round, same hosts:
`geerlingguy.postgresql`, new; `geerlingguy.nginx`/`geerlingguy.docker`
re-run as regression checks, both still pass): the recursive-re-
templating bug class's newest sub-case - a role default that's a list
of dicts (`postgresql_hba_entries`), whose own field values are
themselves unrendered Jinja (`auth_method: "{{ postgresql_auth_method
}}"`, a default computed from another default). Every prior fix for
this bug class only ever re-rendered a *top-level* String variable
value; both `CrinjaRenderer#prepare_crinja_vars` and the separate
`TemplateActionPlugin#prepare_template_vars` now recurse into Array/
Hash values too, re-rendering every String leaf.

`0.9.238` (a third extension of the eighth round, same hosts:
`geerlingguy.haproxy`/`geerlingguy.certbot` re-run as regression checks
- both still pass exactly as they did in round 4, no divergence -
plus `geerlingguy.pip`, new): `ansible.builtin.pip` was entirely
unimplemented (no plugin at all) - every real playbook's `pip:` task
silently skipped. Implemented supporting name/version/state (present/
absent/latest)/virtualenv/executable/extra_args/chdir/requirements.

`0.9.234`-`0.9.237` (a second extension of the eighth round, same
hosts: `geerlingguy.ntp`, `geerlingguy.node_exporter`,
`geerlingguy.firewall` - all new; `geerlingguy.golang`/`geerlingguy.
consul` don't exist on Galaxy). `ntp` found `service_facts:` was
missing from `TaskBatcher`'s fact-producing guard list (already had
`getent`/`package_facts`/`set_fact` there) - a task's `when:` reading
the bare `services` fact right after "Populate service facts." always
silently skipped, since batching pre-renders every group member's
params before any of them actually run. `node_exporter` found THREE
bugs from one "download latest release from GitHub and extract it"
task: `is match(...)`/`is search(...)` (real Jinja2's regex tests)
were entirely unimplemented; `regex_replace` (Python's re.sub with
backreferences) was missing from the plain `{{ }}` evaluator entirely
(Crinja's separate pipeline had one, but a bare `{{ }}` span never
reaches it); and `unarchive:`'s `src:` as a URL (with `remote_src:
true`) was never implemented at all - real Ansible's own module
explicitly fetches it first when `src:` contains "://". `firewall`
found `command:`/`shell:`'s own legacy free-form syntax never
extracted trailing `creates=`/`removes=`/`chdir=`/`executable=`
key=value params the way every other module's inline syntax does -
the whole string (options text included) ran as the literal command.

`0.9.233` (an extension of the eighth round, same hosts:
`geerlingguy.nfs` - new; `geerlingguy.php-mysql` was also attempted but
its own repo doesn't ship a `vars/Debian.yml` at all, and real
`ansible-playbook` fails identically on that same task - a role
limitation, not a crystal-ansible gap): found two bugs, both in the
filter engine. `map()` only implemented the `map(attribute='x')` form;
real Jinja2's filter-name positional form (`map('split')`,
`map('first')`) silently no-op'd - `nfs`'s own "Ensure directories to
export exist" task (`nfs_exports | map('split') | map('first') |
unique`, pulling just the directory-path column out of each raw
`"/path *(opts)"` export line) left the WHOLE export line - options
text included - as the target directory path. Separately, `split` with
no delimiter argument passed an empty string to Crystal's own
`String#split`, which splits into individual *characters* for an
empty-string arg rather than matching real Python/Jinja2's
whitespace-run default (Crystal's own no-arg `String#split` overload
already does, and is what's used now).

`0.9.232` (an eighth real-host round: `geerlingguy.memcached`,
`geerlingguy.rabbitmq` - both new; `geerlingguy.varnish` was also
attempted but blocked by an external issue - its packagecloud.io apt
repo currently has no valid Release file for Ubuntu jammy, reproduced
identically on real `ansible-playbook`, not a crystal-ansible gap;
`geerlingguy.mongodb` doesn't exist on Galaxy anymore, skipped):
`geerlingguy.memcached` passed clean on the first try - byte-identical
`/etc/memcached.conf`. `geerlingguy.rabbitmq` found two bugs:
`deb822_repository`'s own `signed_by:` support (added last round) only
handled an already-local path - rabbitmq's own task gives a bare
`keys.openpgp.org` URL directly, previously written completely
literally into `Signed-By:`, which apt rejected outright; now fetched
(binary-safe), dearmored via `gpg` if ASCII-armored, and stored at
`/etc/apt/keyrings/<name>-archive-keyring.gpg` (real Ansible's own
naming convention). Separately, `apt:`'s own `name=version` pinning
syntax (`rabbitmq-server={{ rabbitmq_version }}-1`) was passed straight
to `dpkg -l` for the already-installed check, which doesn't understand
that syntax at all - reported changed on literally every run even once
the exact pinned version was already installed.

`0.9.230`-`0.9.231` (a seventh real-host round: `geerlingguy.jenkins`,
`geerlingguy.elasticsearch` - both new, both required overriding a role
default to work at all in this environment: `geerlingguy.java`'s own
default installs Java 17, which current Jenkins packages refuse to run
on (needs 21) - an environment/role-staleness issue affecting real
`ansible-playbook` identically, not a crystal-ansible gap, fixed by
overriding `java_packages:` for the round). `geerlingguy.jenkins` found
four real bugs: a handler written as `include_tasks: file.yml` (real
Ansible's own shorthand) crashed the whole process outright for any
remote host - the handler-collection loop in `batch_upload_plugins_
for_playbook` had no pseudo-module guard, unlike the regular-tasks
collection path; a handler using an action-plugin module (`template:`)
never ran the controller-side render step at all, since
`execute_handler_plugin_once` (a separate dispatch path from regular
tasks) never checked `ActionPluginManager`; `lineinfile`'s "exact line
already present" idempotency check was gated behind `!regexp`, so ANY
`regexp:` that failed to match - regardless of whether the target line
already existed verbatim - skipped straight to insertion, appending a
fresh duplicate line on every single run; and `get_url`'s `force: true`
unconditionally reported `changed: true` after every download, when
real Ansible's own `force: true` means "bypass freshness checks before
re-fetching," not "always report changed" - it still compares the
downloaded content against `dest:` first. `geerlingguy.elasticsearch`
found that plain-string character indexing (`elasticsearch_version[0]`
on `"7.x"`, matching real Jinja2/Python `str[0]`) was entirely
unsupported - only Array/Hash indexing existed - so the role's own
`elasticsearch_version[0] | int < 7` version-branch `when:` silently
defaulted to comparing against `0`, picking the wrong (pre-7.x) config
file layout and failing to start the service outright.

`0.9.225`-`0.9.226`: a proactive audit pass (not a real-host round -
grepping every remaining `VariableLookup#resolve` call site in the
engine after rounds 2-3 found 5 independent copies of the recursive-
re-templating bug) found and fixed **8 more copies** of the exact same
gap: `ConditionalEvaluator`'s `is mapping`/`is sequence` test and its
dotted-access lookup, two separate `FilterEngine` fallbacks, both of
`ComparisonEvaluator`'s dotted-path counterparts, and `TaskExecutor#
deep_render_item`'s loop-item native-type fast path. Fixing one of
those (a loop item's own re-render) surfaced a **10th, related** copy
in `TaskExecutor#resolve_template_value` (the loop: SOURCE itself, not
just each item) - found while writing a test, not via a real-host
round. That same investigation turned up a genuinely different bug: a
single-element `loop:`/`with_items:` list holding one bare `{{ var }}`
span, where `var` resolves to a scalar rather than a list, silently
produced NO loop items at all instead of one iteration - verified
against real `ansible-playbook` directly (both `loop:` and
`with_items:` treat this identically) before fixing.

`0.9.227` (a fourth real-host round): `geerlingguy.haproxy` passed
clean on the first try - byte-identical rendered config, no bugs.
`geerlingguy.certbot` found that `cron:` required `cron_file:`, a
documented but overly-broad scope cut - the real risk (this test
suite's OWN crontab getting mutated as a spec side effect) doesn't
apply to managing an arbitrary TARGET user's live crontab via `crontab
-u`, which is real Ansible's own default (`cron_file:` omitted) and
exactly what certbot's own renewal-cron task uses. Implementing it
surfaced its own bug: the install path added an extra trailing newline
on top of one `PluginHelpers::CronTable.upsert` already appends,
producing a blank line at the end of the installed crontab that made
every subsequent run see a "changed" diff against itself forever -
caught by testing idempotency explicitly (a second run), not just a
single successful one.

`0.9.229` (a sixth real-host round: `geerlingguy.apache`, `geerlingguy.
nodejs` - both new): `geerlingguy.apache` passed clean on the first try
- byte-identical vhost config, matching enabled mods, healthy service.
`geerlingguy.nodejs` hit the already-flagged `ansible.builtin.
deb822_repository` gap (see the narrow-scope-cuts list below for what's
now implemented) - a SECOND real role independently needing it after
`geerlingguy.docker`, which raised its priority enough to implement
this round rather than defer again. With the repo now actually added,
`apt-get update` sees the NodeSource suite and the role's own
subsequent `nodejs=20.x*` install task reached parity with real
`ansible-playbook` up through that point; the install itself then hit
an external NodeSource-repo/apt-cache inconsistency (`nodejs` briefly
reporting as a virtual package with no installable candidate) that
reproduced identically running the *exact same* raw `apt-get install`
command directly on the real-ansible-playbook host too - confirmed
environmental, not a crystal-ansible-specific divergence, and not
chased further.

`0.9.228` (a fifth real-host round: `geerlingguy.redis`, `geerlingguy.
postfix` - both new): `geerlingguy.postfix` passed clean on the first
try, including a byte-identical `main.cf` (module the two hosts'
hostnames, expected to differ). `geerlingguy.redis` found three real
bugs: `apt:` install/upgrade never passed `--force-confdef`/
`--force-confold` (real Ansible's own `apt` module default
`dpkg_options`), so installing a package whose shipped conffile
differs from a pre-existing one (redis's role templates its config
file before installing the package) hung forever on dpkg's interactive
conffile prompt with no stdin to answer it; the legacy free-form
`key={{ x }} key2=y` inline module-args tokenizer split on every
whitespace character with no awareness of `{{ }}`/`{% %}` as an opaque
span, shattering a templated value's own internal spaces into bogus
tokens and corrupting the expression irrecoverably before templating
ever ran (`service: "name={{ redis_daemon }} state=restarted"`,
real Ansible's legacy syntax, is exactly the shape geerlingguy.redis's
own handler uses); and `mode:` piped through a variable that's itself
an unquoted-octal YAML literal (`redis_conf_dir_mode: 02770`) lost its
octal-ness - Crystal's own YAML parser (like real Ansible's) resolves
that literal to a decimal Int64 at vars-file parse time, and unlike a
*direct* `mode: 0770` task literal (which already recovers its octal
digit text, see the `0.9.210`-`0.9.224` entry below), piping the same
decimal-converted int through a variable and a bare `{{ }}` template
bypassed that recovery entirely - `chmod` received an invalid mode,
silently no-opped, and the directory reported "changed" on every
subsequent run since the never-applied target mode could never match
the real one.

`0.9.198`-`0.9.209` (a second broader-mix round: `openstack.ansible-
hardening`, `githubixx.ansible_role_wireguard`, `ansible-community.
ansible-vault`): the `ansible-vault` role in particular surfaced a
cluster of related bugs all in the same family - real Ansible's
"recursive re-templating" (a variable whose own value is itself more
Jinja gets re-evaluated wherever referenced) turned out to have **four
separate, independently-buggy plain-lookup fallbacks** across the
engine, each fixed on its own: ConditionalEvaluator's bare `when:`
variable check, ExpressionEvaluator's filter-chain head resolution,
FilterEngine's `default()`-argument resolution, and ComparisonEvaluator's
bare comparison-operand lookup - `git log --oneline --grep="0\.9\.19
[9]\|0\.9\.20[0-9]" -E` for the full list. Also fixed in this round:
an else-less inline-if (`'x' if cond`, no `else`) not rendering as ""
like real Jinja2's `Undefined`; a ternary branch that's a bare `true`/
`false` literal (not a quoted string) resolving to "undefined"; a
parenthesized ternary as a `default()` argument not being unwrapped
before its own `if`/`else` was searched for; Jinja2's `~` string-concat
operator being entirely unimplemented anywhere in the engine; `or`/
`and`/`is` boolean logic not understood inside a plain `{{ }}` span
(only inside a bare `when:`); `copy:` embedding a large file's whole
content as a JSON param string then base64-encoding the *entire config*
a second time for SSH transport, overflowing Crystal stdlib's
`Base64.encode_size` (Int32 arithmetic) for a ~530MB file and crashing
the whole engine rather than failing one task; `copy:` not handling an
existing-directory `dest:` (real Ansible appends `src`'s basename); and
`shell:`'s `executable:` (custom-shell) form naively wrapping the whole
command in `'...'` without escaping the command's own embedded single
quotes, corrupting anything using `cut -d' '`/`tr -d 'x'`-style
pipelines.

`0.9.210`-`0.9.224` (a third broader-mix round: `cloudalchemy.
prometheus`, `cloudalchemy.grafana` - both new monitoring-stack roles,
both now reach `failed=0` with genuinely healthy services, not just a
clean exit code): `resolve_plus_operand`'s own plain-lookup fallback
turned out to be the FIFTH independent copy of the recursive-re-
templating bug (a bare identifier used as a `+`/`~` operand, e.g.
`('linux-' + go_arch + '.tar.gz')`) - `git log --oneline --grep="0\.9\.2
1[0-9]\|0\.9\.22[0-4]" -E` for the full list. Two real engine crashes
found and fixed: a bare quoted-literal fix regressed into wrongly
swallowing a `+`-chain (`'a' + var + 'b'` both start/end with `'`,
mistaken for one literal - fixed immediately after, same round); and a
genuine stack overflow when a single variable's value mixes `{{ }}`
and `{% %}` in the same string (`CrinjaRenderer#prepare_crinja_vars`'s
own pre-render step recursing into itself unboundedly - fixed with a
process-wide recursion-depth cap). Also fixed: `lookup('url', ...)`
entirely unimplemented (plus not following redirects, which is how
GitHub actually serves release-asset URLs in practice); `copy:`
directory-`src:` support entirely unimplemented (a documented scope
cut, real Ansible's own rsync-style trailing-`/` convention now
matched); `copy:`'s own `owner:`/`group:` handling was a **dead no-op
stub** the whole time (comments claimed "not available in Crystal
stdlib," which was simply wrong); `apt:`/`package:`'s own `state:
latest` used `apt-get install --only-upgrade`, which silently skips
(doesn't install) a package that isn't already present - two
independent copies of the same bug, in two different plugins;
`with_fileglob:` templating a list variable rendered the JSON-array
TEXT as one glob pattern instead of one pattern per list element;
`mode: 0770` (unquoted - the way most playbooks write it) got silently
decimal-converted by YAML 1.1's own leading-zero-is-octal rule, then
double-octal-reinterpreted downstream; `is mapping`/`is sequence`
Jinja2 type tests and `is (not) defined` on a dotted path
(`x.y is not defined`) both entirely unimplemented; `to_nice_yaml`
(a real Ansible filter) unimplemented; `ansible.builtin.apt_key`
(deprecated in real ansible-core but still shipped and still used)
unimplemented.

`0.9.172`-`0.9.180`: the `geerlingguy.*` role family (docker, mysql,
postgresql, nginx, php, security - none tried before) found 13 more real
bugs in one round, several engine-wide rather than role-specific -
`git log --oneline --grep="0\.9\.1[7-8][0-9]" -E` for the full list.
Highest-value: **`pre_tasks:`/`post_tasks:` play keywords were entirely
unparsed** (a documented-in-comment, but not previously listed here,
simplification) - silently never ran, no warning; and real Ansible's own
recursive re-templating of a variable whose *value* is itself more Jinja
(common in role defaults, e.g. `nginx_worker_processes: '"{{
ansible_processor_vcpus | default(ansible_processor_count) }}"'`) wasn't
applied when that variable was used inside a real `.j2` template file,
only in plain `{{ }}` task-param substitution - the literal unparsed
`{{ ... }}` text landed in the rendered config file itself. Also fixed:
`lookup('first_found', ...)` resolving `paths:` against the wrong
directory (cwd instead of the current role, both when omitted and when
given as an explicit relative path); a `with_items:` single-element-array
item that merely *embeds* a template misparsed as the unrelated "whole
array is a list template" idiom; `.split(sep)[index]` Python-style
dotted method calls; `dirname`/`basename` filters entirely missing; the
`comment` filter's `decoration=` kwarg ignored; a loop item's own bare
`{{ var }}` value losing its native type (int/bool) once rendered;
`default(fallback, true)`'s boolean form not catching a real falsy
(not just undefined) value; and `postgresql_db`'s `encoding:` over-
validated as a strict SQL identifier when it's actually a safely-quoted
string literal.

`0.9.172` (found rebuilding the perf-benchmark playbook, not a role
round): Jinja2/Python's `range(...)` function-call syntax (`loop: "{{
range(1, 11) | list }}"`) was never recognized - routed to a plain
variable lookup on the literal text `range(1, 11)`, always undefined,
silently running the loop body once with `item` undefined instead of
iterating. Fixed generally (bare `range(stop)`, `range(start, stop)`,
`range(start, stop, step)`, negative step, expression/variable
arguments, with or without a following `| list`).

Narrow, deliberately-scoped items:

- **Crinja's `-%}`/`{%-` explicit whitespace-control markers under-trim
  by one blank line across a skipped `{% if false %}...{% endif -%}`
  block immediately followed by another `{%- if %}...{% endif %}`
  block** - found via `geerlingguy.supervisor`'s own supervisord.conf.j2
  (two adjacent `[unix_http_server]`/`[inet_http_server]` conditional
  sections, both false by default): real Jinja2 (verified directly
  against Python's own `jinja2.Environment(trim_blocks=True)`, and
  against the real-host `ansible-playbook` output) collapses the blank
  line between the two blocks' tags to nothing; Crinja leaves one blank
  line behind, a single stray byte in the rendered file. Purely cosmetic
  - INI-style config parsers (supervisord's included) ignore blank
  lines, and the affected service started and passed a real functional
  check (`supervisorctl status` showing the configured program
  running) - not chased further given the fix would need touching
  vendored `lib/crinja`'s own lexer-level trim-distance tracking
  (`lib/crinja/src/parser/template_lexer.cr`'s `check_for_end`/
  `trim_left`/`trim_right` handling), already flagged elsewhere in this
  codebase (`lstrip_blocks` is forced off - see
  `template_action_plugin.cr`'s own comments) as an area with known
  quirks. Revisit if a real template's correctness (not just
  byte-identical output) ever depends on it.
- **`meta:`** supports only `clear_facts`. `end_play`/`flush_handlers`/
  `refresh_inventory`/`clear_host_errors` act on execution-flow machinery
  this engine models differently, and are rejected at parse time rather
  than silently ignored.
- **`docker_*` `api_version:`** is deliberately not planned - the
  underlying `docr` client uses unversioned endpoint URLs throughout, so
  pinning a version means touching every endpoint in a separate shard.
  The unversioned URLs negotiate fine against current Docker and Podman.
  Revisit only if a real playbook actually needs the pin.
- **Cloud plugins** (`ec2`, `s3_bucket`, `azure_rm_*`) and inventory
  *plugins* (`aws_ec2.yml` et al.) remain explicitly lowest-ROI and are
  not planned.
- **Role-private custom modules** (a role's own `library/*.py`, outside
  the `ansible.builtin`/`community.*`/etc. plugin set this engine ships)
  aren't executed - there's no generic arbitrary-Python-module runner. A
  task using one is skipped with "Plugin not available" rather than
  crashing the run, but anything downstream that depends on its result
  sees that value as undefined, which can cascade into broader task-
  status divergence from real Ansible. Seen repeatedly benchmarking
  `linux-system-roles`: `sr_fingerprint`, `timesync_provider`,
  `kernel_settings_get_config`, `blivet`.
- **`crystal-mysql`'s wire-protocol driver** — `auth_socket`/`unix_socket`
  authentication support was added to the `weirdbricks/crystal-mysql` fork
  (tag `crystal-ansible-0.9.340`, commit `a91a592`): `CLIENT_PLUGIN_AUTH`
  now advertised unconditionally, auth plugin name written even without a
  password, and `Auth.scramble` returns an empty response for
  `auth_socket`/`unix_socket`/`mysql_clear_password` plugin names. A role
  connecting via `login_unix_socket:` with no password can now authenticate
  using socket peer-credential auth. `mysql_user.cr` also now implements
  the `plugin:`/`plugin_hash_string:`/`plugin_auth_string:` params for
  *creating/updating* accounts with non-password auth (`IDENTIFIED WITH <p>
  [AS <hash> | BY <auth>]`, matching real Ansible's module_utils/user.py
  precedence; the `plugin: unix_socket`/`auth_socket` case for socket
  accounts is fully idempotent, diffing the account's current plugin
  server-side). Verified end-to-end by `testing/test-mysql-auth-socket.sh`
  against a throwaway MariaDB container (all four mysql_* plugins connect
  over a Unix socket as OS root with no login_password).
- **`to_datetime()`/timedelta arithmetic beyond subtraction** stayed
  narrowly scoped to what real roles have needed so far - revisit if a
  role needs more.
- **`ansible.builtin.deb822_repository`** (fixed `0.9.229`, URL `signed_by:`
  fixed `0.9.232`, inline key/fingerprint/redirects/check_mode `0.9.343`)
  now supports the full four-way `signed_by:` branching matching real
  Ansible's own module: local path (`os.path.isfile`), URL (redirect-
  aware download, stored as `<name>.asc` or `<name>.gpg`), inline
  ASCII-armored GPG key text (Deb822 folded multi-line format), and
  key fingerprint (space-normalized on one line). `check_mode` no longer
  triggers network I/O. Rendered content includes `X-Repolib-Name:`
  matching real Ansible's output.

`postgresql_privs` is the one per-plugin scope-cut list this project
originally tracked that reached **zero open items** (`0.9.84`) - every
`type:` real Ansible's module supports is implemented, including
`function`/`procedure` signatures and `default_privs`. New scope cuts get
found continuously through real-host benchmark rounds against production
Ansible roles instead of from a static pre-planned list; `git log` for
each round's own commits for what it left open, if anything.
