require "../spec_helper"
require "../../src/crystal_play/variable_substitutor/filter_engine"

private def s(value : String) : JSON::Any
  JSON::Any.new(value)
end

describe CrystalPlay::VariableSubstitutor::FilterEngine do
  engine = CrystalPlay::VariableSubstitutor::FilterEngine.new

  it "applies default when value is empty" do
    engine.apply(s(""), %(default('fallback'))).as_s.should eq("fallback")
  end

  it "applies default when value is JSON null (undefined)" do
    engine.apply(JSON::Any.new(nil), %(default('fallback'))).as_s.should eq("fallback")
  end

  it "leaves non-empty values untouched by default" do
    engine.apply(s("present"), %(default('fallback'))).as_s.should eq("present")
  end

  it "parses an unquoted numeric default as a number, not a string" do
    engine.apply(JSON::Any.new(nil), "default(0)").as_i.should eq(0)
  end

  it "default(a ~ b ~ c) evaluates a Jinja2 `~`-concatenation argument, not just `+`/`-`" do
    # Real bug found benchmarking weareinteractive.users' own `user.home
    # | default(users_home ~ '/' ~ user.username)` (building a user's
    # home path from two variables). The existing `+`/`-`-concatenation
    # default() delegation to ExpressionEvaluator never checked for `~`
    # (Jinja2's own distinct string-concat operator), so a `~`-only
    # default argument fell through to a plain #resolve_expression call
    # with no `~` concept at all, resolving to nil - the whole home path
    # collapsed to an empty string.
    vars = Hash(String, JSON::Any).new
    vars["users_home"] = JSON::Any.new("/home")
    vars["username"] = JSON::Any.new("alice")
    scoped_engine = CrystalPlay::VariableSubstitutor::FilterEngine.new(vars)

    scoped_engine.apply(JSON::Any.new(nil), %(default(users_home ~ '/' ~ username))).as_s.should eq("/home/alice")
  end

  it "default(fallback, true) also replaces a real, defined-but-falsy value" do
    # Real bug found benchmarking geerlingguy.php: `pm.max_requests = {{
    # item.pool_pm_max_requests | default(500, true) }}` where the real
    # value is the int 0 (a legitimate, deliberately-set value meaning
    # "unlimited", not a mistake) - defined and non-nil, so `undefined?`
    # alone never caught it, always leaving the real 0 instead of the
    # role's own intended fallback of 500. The 2-arg boolean form must
    # also replace any falsy value (0, false, empty array/hash), not
    # just nil/empty-string.
    engine.apply(JSON::Any.new(0_i64), "default(500, true)").as_i.should eq(500)
    engine.apply(JSON::Any.new(false), "default('yes', true)").as_s.should eq("yes")
  end

  it "default(fallback) without the boolean form leaves a falsy-but-defined value alone" do
    engine.apply(JSON::Any.new(0_i64), "default(500)").as_i.should eq(0)
  end

  it "treats the engine's own internal \"undefined\" sentinel text as undefined for default()" do
    # Real bug found benchmarking robertdebock.bootstrap (round 18):
    # `_bootstrap_packages[key] | default(_bootstrap_packages[other_key])
    # | default(_bootstrap_packages[os_family])` - a missing dict key
    # resolves (via VariableLookup and several ExpressionEvaluator call
    # sites) to the literal string "undefined" rather than a real
    # Undefined type, but `undefined?` only ever recognized nil/empty
    # string, so a non-empty "undefined" string sailed straight through
    # default() unreplaced - the whole chain resolved to the literal
    # package name "undefined", which then failed to install.
    engine.apply(s("undefined"), %(default('fallback'))).as_s.should eq("fallback")
  end

  it "uppercases with upper" do
    engine.apply(s("hello"), "upper").as_s.should eq("HELLO")
  end

  it "lowercases with lower" do
    engine.apply(s("HELLO"), "lower").as_s.should eq("hello")
  end

  it "capitalizes with capitalize" do
    engine.apply(s("hello world"), "capitalize").as_s.should eq("Hello world")
  end

  it "title-cases with title" do
    engine.apply(s("hello world"), "title").as_s.should eq("Hello World")
  end

  it "trims whitespace with trim" do
    engine.apply(s("  hello  "), "trim").as_s.should eq("hello")
  end

  it "reports length of a string" do
    engine.apply(s("hello"), "length").as_i.should eq(5)
  end

  it "reports length of an array" do
    engine.apply(JSON.parse(%([1, 2, 3])), "length").as_i.should eq(3)
  end

  it "replaces substrings with replace" do
    engine.apply(s("hello world"), %(replace('world', 'there'))).as_s.should eq("hello there")
  end

  it "strips a regex-matched prefix with regex_replace and a backreference" do
    # Real bug found benchmarking geerlingguy.node_exporter's own
    # `_github_release.json.tag_name | regex_replace('^v?([0-9\.]+)$',
    # '\1')` (stripping a GitHub release tag's leading "v", e.g.
    # "v1.12.1" -> "1.12.1") - regex_replace was entirely missing from
    # this plain `{{ }}` evaluator (Crinja's own separate pipeline
    # already had one, but a bare `{{ tag | regex_replace(...) }}` span
    # never reaches Crinja at all), so it fell through to the
    # unknown-filter passthrough, returning the value completely
    # unchanged - the still-"v"-prefixed version then built a download
    # URL with a doubled "v" that doesn't exist as a real release.
    result = engine.apply(s("v1.12.1"), %(regex_replace('^v?([0-9\.]+)$', '\\1')))
    result.as_s.should eq("1.12.1")
  end

  it "evaluates a `~`-concatenated regex_replace pattern argument, not just a literal one" do
    # Real bug found benchmarking prometheus.prometheus._common's own
    # `regex_replace(ansible_collection_name ~ '.', '')` (stripping a
    # role's own collection-namespace prefix off its FQCN) -
    # resolve_expression (the general filter-ARGUMENT resolver) never
    # had the same `~`-concatenation delegation resolve_default_arg
    # already has for default()'s own argument, so the pattern stayed
    # the literal unparsed text "ansible_collection_name ~ '.'" instead
    # of the real computed "prometheus.prometheus." - nothing ever
    # matched, and the full FQCN was used verbatim as a systemd service
    # name/template filename that doesn't exist under that name.
    vars = Hash(String, JSON::Any).new
    vars["ansible_collection_name"] = JSON::Any.new("prometheus.prometheus")
    scoped_engine = CrystalPlay::VariableSubstitutor::FilterEngine.new(vars)

    result = scoped_engine.apply(s("prometheus.prometheus.node_exporter"), %(regex_replace(ansible_collection_name ~ '.', '')))
    result.as_s.should eq("node_exporter")
  end

  it "regex_replace replaces every match, not just the first" do
    result = engine.apply(s("a1 b2 c3"), %(regex_replace('[a-z](\\d)', 'X\\1')))
    result.as_s.should eq("X1 X2 X3")
  end

  it "regex_replace with no replacement argument removes every match" do
    result = engine.apply(s("hello123world"), %(regex_replace('\\d+')))
    result.as_s.should eq("helloworld")
  end

  it "hashes with the default sha1 algorithm when no argument is given" do
    # Real bug found benchmarking geerlingguy.supervisor's own
    # supervisord.conf.j2: `{SHA}{{ supervisor_password|hash('sha1') }}`
    # (rendered via Crinja, not this evaluator, but the plain `{{ }}`
    # evaluator had no `hash` filter at all either - checked both per
    # this codebase's usual rule). Value verified against Python's own
    # `hashlib.sha1(b'mysecret').hexdigest()`.
    engine.apply(s("mysecret"), "hash").as_s.should eq("e9fe51f94eadabf54dbf2fbbd57188b9abee436e")
  end

  it "hashes with an explicit algorithm argument" do
    engine.apply(s("mysecret"), %(hash('md5'))).as_s.should eq("06c219e5bc8378f3a8a3f83b4b7e4649")
  end

  it "password_hash produces a real crypt(3) hash, not the plaintext passthrough" do
    # Real bug found benchmarking robertdebock.users: `password: "{{
    # 'secret' | password_hash('sha512') }}"` (the standard way any
    # role sets a user's password) was entirely unimplemented - the
    # plaintext string passed straight through unfiltered and landed
    # verbatim in /etc/shadow instead of a salted hash.
    result = engine.apply(s("AlicePass123!"), %(password_hash('sha512'))).as_s
    result.should start_with("$6$")
    result.should_not contain("AlicePass123!")
    result.split('$').size.should eq(4)
  end

  it "password_hash defaults to sha512 with no argument" do
    result = engine.apply(s("secret"), "password_hash").as_s
    result.should start_with("$6$")
  end

  it "password_hash honors an explicit salt for reproducible output" do
    result = engine.apply(s("secret"), %(password_hash('sha512', 'fixedsalt'))).as_s
    result.should eq("$6$fixedsalt$" + result.split('$').last)
    engine.apply(s("secret"), %(password_hash('sha512', 'fixedsalt'))).as_s.should eq(result)
  end

  it "password_hash supports sha256 and md5" do
    engine.apply(s("secret"), %(password_hash('sha256'))).as_s.should start_with("$5$")
    engine.apply(s("secret"), %(password_hash('md5'))).as_s.should start_with("$1$")
  end

  it "to_json uses Python's own ', '/': ' separators, matching json.dumps" do
    result = engine.apply(JSON.parse(%(["a", "b"])), "to_json")
    result.as_s.should eq(%(["a", "b"]))
  end

  it "splits into a real array, not just the first element" do
    result = engine.apply(s("a,b,c"), %(split(','))).as_a.map(&.as_s)
    result.should eq(["a", "b", "c"])
  end

  it "split with no argument splits on whitespace runs, matching Python's str.split()" do
    # Real bug found benchmarking geerlingguy.nfs: `split` with no
    # delimiter argument (`nfs_exports | map('split')`) passed an EMPTY
    # STRING delimiter to Crystal's own String#split, which splits into
    # individual *characters* for an empty-string arg - not the same as
    # Crystal's own no-arg String#split overload, which already matches
    # Python/Jinja2's whitespace-run default.
    result = engine.apply(s("/srv/nfs/share  *(ro,sync)"), "split").as_a.map(&.as_s)
    result.should eq(["/srv/nfs/share", "*(ro,sync)"])
  end

  it "map('split') applies the filter-name form, not just map(attribute=...)" do
    # Real bug found benchmarking geerlingguy.nfs's own "Ensure
    # directories to export exist" task: `nfs_exports | map('split') |
    # map('first') | unique` (pulling the directory-path column out of
    # each raw export line). Only map(attribute='x') was implemented -
    # the filter-name positional form silently no-op'd, so the whole
    # export line (options text included) got used as a directory path.
    list = JSON::Any.new(["a,b,c", "d,e,f"].map { |s| JSON::Any.new(s) })
    result = engine.apply(list, %(map('split', ','))).as_a.map { |item| item.as_a.map(&.as_s) }
    result.should eq([["a", "b", "c"], ["d", "e", "f"]])
  end

  it "map('split') then map('first') extracts the first whitespace-separated word from each item" do
    list = JSON::Any.new(["/srv/nfs/share  *(ro,sync)", "/srv/nfs/other  10.0.0.0/24(rw)"].map { |s| JSON::Any.new(s) })
    split_result = engine.apply(list, "map('split')")
    result = engine.apply(split_result, "map('first')").as_a.map(&.as_s)
    result.should eq(["/srv/nfs/share", "/srv/nfs/other"])
  end

  it "returns the value unchanged for an unknown filter" do
    engine.apply(s("hello"), "mystery").as_s.should eq("hello")
  end

  it "sorts an array" do
    result = engine.apply(JSON.parse(%(["banana", "apple", "cherry"])), "sort").as_a.map(&.as_s)
    result.should eq(["apple", "banana", "cherry"])
  end

  it "sorts numerically when every element parses as a number" do
    result = engine.apply(JSON.parse(%([10, 2, 33])), "sort").as_a.map(&.as_i)
    result.should eq([2, 10, 33])
  end

  it "dedupes with unique" do
    result = engine.apply(JSON.parse(%(["a", "b", "a", "c", "b"])), "unique").as_a.map(&.as_s)
    result.should eq(["a", "b", "c"])
  end

  it "reverses an array" do
    result = engine.apply(JSON.parse(%([1, 2, 3])), "reverse").as_a.map(&.as_i)
    result.should eq([3, 2, 1])
  end

  it "joins an array into a string" do
    engine.apply(JSON.parse(%(["a", "b", "c"])), %(join(','))).as_s.should eq("a,b,c")
  end

  it "extracts an attribute from each hash in an array via map(attribute=...)" do
    value = JSON.parse(%([{"path": "/a", "size": 1}, {"path": "/b", "size": 2}]))
    result = engine.apply(value, %(map(attribute='path'))).as_a.map(&.as_s)
    result.should eq(["/a", "/b"])
  end

  it "chains map(attribute=...) into sort into join - the exact shape find:'s output needs" do
    value = JSON.parse(%([{"path": "/z"}, {"path": "/a"}, {"path": "/m"}]))
    result = engine.apply_chain(value, %(map(attribute='path') | sort | join(',')))
    result.as_s.should eq("/a,/m,/z")
  end

  it "does not split a | that appears inside a quoted filter argument" do
    chain = CrystalPlay::VariableSubstitutor::FilterEngine.split_chain(%(replace('a|b', 'c') | upper))
    chain.should eq([%(replace('a|b', 'c')), "upper"])
  end

  it "int filter truncates a native Float64 directly, matching Python's int()" do
    # Real bug found benchmarking geerlingguy.swap's own check-size.yml
    # (`(stat.size / 1024 / 1024) | int`) once division itself was
    # fixed - a division result is always a float in real Jinja2. The
    # old implementation always went through #as_string first, turning
    # a Float64 into its own decimal-point STRING repr ("256.0"), and
    # Crystal's strict String#to_i64? rejects any decimal point
    # outright, always falling to the 0 default - `{{ 256.0 | int }}`
    # rendered "0" instead of "256", for ANY float, not just one
    # arriving via division.
    engine.apply(JSON::Any.new(256.0), "int").as_i64.should eq(256)
    engine.apply(JSON::Any.new(5.7), "int").as_i64.should eq(5)
    engine.apply(JSON::Any.new(-5.7), "int").as_i64.should eq(-5)
    engine.apply(s("42.5"), "int").as_i64.should eq(42)
  end

  it "converts to int/float/string/bool" do
    engine.apply(s("42"), "int").as_i.should eq(42)
    engine.apply(s("3.5"), "float").as_f.should eq(3.5)
    engine.apply(JSON::Any.new(7_i64), "string").as_s.should eq("7")
    engine.apply(s(""), "bool").as_bool.should eq(false)
    engine.apply(s("yes"), "bool").as_bool.should eq(true)
  end

  it "bool filter only recognizes real Ansible's own keyword set, not general truthiness" do
    # Real bug found benchmarking geerlingguy.gitlab's own "restart
    # gitlab" handler: `failed_when: gitlab_restart_handler_failed_when
    # | bool`, whose default value is the arbitrary expression STRING
    # 'gitlab_restart.rc != 0' (not a recognized true/false keyword).
    # Previously reused the generic (correct-for-`when:`) #truthy?
    # helper, so any non-empty, non-"0"/"false" string came out true
    # here - verified directly against real ansible-playbook (`{{
    # 'gitlab_restart.rc != 0' | bool }}` renders "false") that an
    # unrecognized string must render false, not true.
    engine.apply(s("gitlab_restart.rc != 0"), "bool").as_bool.should eq(false)
    engine.apply(s("some random text"), "bool").as_bool.should eq(false)
  end

  it "returns first/last/min/max of an array" do
    value = JSON.parse(%([3, 1, 2]))
    engine.apply(value, "first").as_i.should eq(3)
    engine.apply(value, "last").as_i.should eq(2)
    engine.apply(value, "min").as_i.should eq(1)
    engine.apply(value, "max").as_i.should eq(3)
  end

  it "strips the last path component with dirname, and keeps only it with basename" do
    # Real bug found benchmarking geerlingguy.mysql: entirely
    # unimplemented before, so `path | dirname` fell through to the
    # unknown-filter passthrough (the full path unchanged) - a `file:
    # {path: "{{ mysql_log_error | dirname }}", state: directory}` task
    # then created a directory at the *full* log-error path itself
    # instead of its parent, so mysqld found a directory where it
    # expected to open its error log file and failed to start.
    engine.apply(s("/var/log/mysql/mysql.err"), "dirname").as_s.should eq("/var/log/mysql")
    engine.apply(s("/var/log/mysql/mysql.err"), "basename").as_s.should eq("mysql.err")
  end

  it "re-templates a selectattr()-compared attribute that's itself an unrendered template string" do
    # Real bug found benchmarking openstack.ansible-hardening's own
    # package install/removal: `stig_packages_rhel7 | selectattr(
    # 'enabled') | selectattr('state', 'equalto', item) | sum(attribute
    # ='packages', start=[])`, where every entry's `state:` is given as
    # `"{{ security_package_state }}"` rather than a literal "present"/
    # "absent" (real Ansible's usual recursive value re-templating).
    # Comparing that raw, still-`{{ }}`-bearing text against a real
    # "present" value never matched, so `selectattr('state', 'equalto',
    # 'present')` always excluded every such entry - chrony (gated
    # exactly this way) was silently never installed.
    v = Hash(String, JSON::Any).new
    v["security_package_state"] = JSON::Any.new("present")
    engine_with_vars = CrystalPlay::VariableSubstitutor::FilterEngine.new(v)
    value = JSON.parse(%([{"packages": ["chrony"], "state": "{{ security_package_state }}", "enabled": true}]))

    result = engine_with_vars.apply(value, %(selectattr('state', 'equalto', 'present')))
    result.as_a.size.should eq(1)
  end

  it "unescapes a real Python/Jinja2 string literal's own backslash escapes when used as a filter argument" do
    # Real bug found benchmarking prometheus.prometheus._common's own
    # preflight.yml: `reject('match', '.+:\d+$')`, written inside a
    # YAML `>-` folded scalar (not a double-quoted YAML string, so YAML
    # itself does no backslash processing at all) - the regex pattern
    # arrived as the two RAW characters `\\d` instead of the single
    # escaped backslash + digit-class `\d` a real Python/Jinja string
    # literal's own unescaping produces, so the regex matched a literal
    # "\d" substring instead of a digit run and never matched real
    # host:port text.
    engine.apply(JSON.parse(%(["0.0.0.0:9100"])), %(reject('match', '.+:\\\\d+$'))).as_a.should be_empty
  end

  it "select()/reject() test bare list elements directly, entirely unimplemented before" do
    # Real bug found benchmarking prometheus.prometheus._common's own
    # preflight.yml: `[_common_web_listen_address] | flatten | reject(
    # 'match', '.+:\d+$') | list | length == 0` (asserting a listen
    # address is host:port shaped) - select/reject (as opposed to
    # selectattr/rejectattr, which already existed) were entirely
    # unrecognized filter names, falling through to the unknown-filter
    # passthrough and silently returning the list UNCHANGED regardless
    # of the test - reject never actually rejected anything.
    engine.apply(JSON.parse(%(["0.0.0.0:9100"])), %(reject('match', '.+:\\d+$'))).as_a.should be_empty
    engine.apply(JSON.parse(%([":9100"])), %(reject('match', '.+:\\d+$'))).as_a.should eq([JSON::Any.new(":9100")])
    engine.apply(JSON.parse(%(["0.0.0.0:9100"])), %(select('match', '.+:\\d+$'))).as_a.should eq([JSON::Any.new("0.0.0.0:9100")])
  end

  it "select()/reject() default to real Jinja2 truthiness when no test name is given" do
    engine.apply(JSON.parse(%([true, false, 1, 0, "", "x"])), "select").as_a.should eq(
      [JSON::Any.new(true), JSON::Any.new(1_i64), JSON::Any.new("x")]
    )
  end

  it "select()/reject() support the 'equalto' test on bare items too" do
    engine.apply(JSON.parse(%([1, 2, 3])), %(reject('equalto', 2))).as_a.should eq([JSON::Any.new(1_i64), JSON::Any.new(3_i64)])
  end

  it "sums a selected list's own attribute values (list concatenation, not just numeric addition)" do
    # Real bug found alongside the selectattr fix above: `sum(attribute
    # ='packages', start=[])` was entirely unimplemented (fell through to
    # the unknown-filter passthrough, returning the selected items
    # themselves unchanged instead of concatenating their `packages`
    # attribute). With a list-valued start:, real Jinja2's sum()
    # concatenates rather than numerically adds.
    engine_with_vars = CrystalPlay::VariableSubstitutor::FilterEngine.new(Hash(String, JSON::Any).new)
    value = JSON.parse(%([{"packages": ["foo", "bar"]}, {"packages": ["baz"]}]))

    result = engine_with_vars.apply(value, %(sum(attribute='packages', start=[])))
    result.as_a.map(&.as_s).should eq(["foo", "bar", "baz"])
  end

  it "resolves a parenthesized ternary as a default() argument" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `vault_tls_certs_path: "{{ lookup('env', 'VAULT_TLS_DIR') | default(
    # ('/opt/vault/tls' if (vault_install_hashi_repo) else '/etc/vault/
    # tls'), true) }}"` - the outer parens around the ternary put its own
    # " if "/" else " one level deep, so the plain ternary splitter never
    # matched and the whole parenthesized text fell through to an
    # (always-undefined) plain variable lookup, silently resolving to "".
    v = Hash(String, JSON::Any).new
    v["vault_install_hashi_repo"] = JSON::Any.new(false)
    engine = CrystalPlay::VariableSubstitutor::FilterEngine.new(v)

    result = engine.apply(JSON::Any.new(""), %(default(('/opt/vault/tls' if (vault_install_hashi_repo) else '/etc/vault/tls'), true)))
    result.as_s.should eq("/etc/vault/tls")
  end

  it "resolves a bare boolean literal as default()'s own fallback argument" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `vault_tls_gossip: "{{ lookup('env', 'VAULT_TLS_GOSSIP') | default(
    # false, true) }}"` - the bare `false` fallback (not a quoted string)
    # fell through resolve_base_expression to a plain (always-undefined)
    # variable lookup on the literal identifier "false", resolving the
    # whole default() call to JSON null - which stringifies to "" - not
    # the literal false it was supposed to substitute.
    engine = CrystalPlay::VariableSubstitutor::FilterEngine.new(Hash(String, JSON::Any).new)
    engine.apply(JSON::Any.new(""), "default(false, true)").as_bool.should eq(false)
    engine.apply(JSON::Any.new(""), "default(true, true)").as_bool.should eq(true)
  end

  it "audit pass: re-templates default()'s own fallback variable when its raw value is unrendered Jinja" do
    # Proactive audit (2026-08-11): resolve_base_expression's plain-
    # lookup fallback (default()'s first/fallback argument, when it's a
    # bare variable reference) had no re-render guard - found by
    # grepping every remaining VariableLookup#resolve call site in the
    # engine after rounds 2-3 turned up 5 independent copies of this
    # bug class. resolve_default_expression (selectattr/sum's own
    # argument resolver, a DIFFERENT function in this same file) had the
    # identical gap.
    v = Hash(String, JSON::Any).new
    v["fallback_var"] = JSON::Any.new("{{ real_val }}")
    v["real_val"] = JSON::Any.new("resolved")
    engine = CrystalPlay::VariableSubstitutor::FilterEngine.new(v)
    engine.apply(JSON::Any.new(nil), "default(fallback_var)").as_s.should eq("resolved")
  end
end
