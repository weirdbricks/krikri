# Known Missing / Known Gaps

The goal is 100% behavioral compatibility with `ansible-playbook`,
verified against real runs rather than assumed - not "cover the common
cases." This file tracks what's actually missing today. It intentionally
does **not** carry implementation history or root-cause narrative for
fixed bugs - that detail lives in `git log` commit messages, written at
the same level of detail per commit; search there (e.g. `git log --all
--grep=auth_socket`) rather than in a second, easily-stale copy here.

**Currently at `0.9.258`.**

---

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
- **`crystal-mysql`'s wire-protocol driver has no `unix_socket`/
  `auth_socket` auth support** - only `mysql_native_password`/
  `caching_sha2_password`. A role connecting via `login_unix_socket:`
  with no password (a common, real MariaDB/Debian-packaging pattern)
  fails every `mysql_*` plugin call. Real low-level driver work (raw
  socket fd access, plugin negotiation) - not fixed; see `git log --all
  --grep=auth_socket` for the investigation.
- **`to_datetime()`/timedelta arithmetic beyond subtraction** stayed
  narrowly scoped to what real roles have needed so far - revisit if a
  role needs more.
- **`ansible.builtin.deb822_repository`** (fixed `0.9.229`) now supports
  the shape real playbooks actually write (types, uris, suites,
  components, a *local-path* signed_by, state, mode) - `signed_by:` as
  a URL to fetch-and-dearmor, or inline ASCII-armored key text written
  directly into the field, remain unimplemented (every real playbook
  seen so far, `geerlingguy.docker` and `geerlingguy.nodejs` both,
  downloads the key separately via `get_url:` first and passes the
  local path).

`postgresql_privs` is the one per-plugin scope-cut list this project
originally tracked that reached **zero open items** (`0.9.84`) - every
`type:` real Ansible's module supports is implemented, including
`function`/`procedure` signatures and `default_privs`. New scope cuts get
found continuously through real-host benchmark rounds against production
Ansible roles instead of from a static pre-planned list; `git log` for
each round's own commits for what it left open, if anything.
