require "../spec_helper"
require "../../src/crystal_play/variable_substitutor/filter_engine"
require "../../src/crystal_play/variable_substitutor/expression_evaluator"

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

  it "raises a clean error for first/last on a genuinely empty sequence, matching real Jinja2's do_first/do_last" do
    # Real bug found benchmarking robertdebock.mount_options (round
    # 140): `ansible_mounts | selectattr(...) | first` on an empty match
    # used to silently return nil, letting a corrupted value flow
    # through undetected and fail much LATER in an unrelated task with a
    # confusing message - real ansible-playbook hard-fails immediately
    # at the source with "No first item, sequence was empty."
    empty = JSON.parse("[]")
    expect_raises(Exception, "No first item, sequence was empty.") { engine.apply(empty, "first") }
    expect_raises(Exception, "No last item, sequence was empty.") { engine.apply(empty, "last") }

    # An empty STRING (also a valid Jinja2 sequence) raises the same way.
    expect_raises(Exception, "No first item, sequence was empty.") { engine.apply(s(""), "first") }
    expect_raises(Exception, "No last item, sequence was empty.") { engine.apply(s(""), "last") }
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

  it "regex_findall extracts every non-overlapping match, groups as a nested list" do
    engine = CrystalPlay::VariableSubstitutor::FilterEngine.new(Hash(String, JSON::Any).new)
    result = engine.apply(s("abc123  file1.tar.gz"), %(regex_findall('^([a-fA-F0-9]+)\\s+(.+)$'))).as_a
    result.size.should eq(1)
    result[0].as_a.map(&.as_s).should eq(["abc123", "file1.tar.gz"])
  end

  it "flatten collapses nested lists by default, skipping nulls" do
    v = JSON::Any.new([JSON.parse(%([1, [2, 3]])), JSON::Any.new(nil), JSON.parse("4")])
    engine = CrystalPlay::VariableSubstitutor::FilterEngine.new(Hash(String, JSON::Any).new)
    engine.apply(v, "flatten").as_a.map(&.as_i64).should eq([1_i64, 2_i64, 3_i64, 4_i64])
  end

  it "map('regex_findall', pattern) preserves the pattern's quoting instead of mangling it into an empty match, real bug found live-verifying prometheus.prometheus.node_exporter" do
    # prometheus.prometheus._common's own checksum-file parsing chain -
    # `raw.splitlines() | map('regex_findall', '^([a-fA-F0-9]+)\\s+
    # (.+)$') | map('flatten') | map('reverse')` - is exactly this
    # shape: map()'s filter-name form previously rebuilt its inner
    # filter call via parse_filter_args, which destructively strips
    # quote characters (needed for a BARE value like a variable name,
    # wrong for a string-literal argument that gets RE-PARSED as an
    # expression) - an unquoted regex pattern full of its own parens
    # was misread as a bare expression instead of a string literal,
    # silently degrading to an effectively empty pattern that matched
    # the empty string at every position instead of the real groups.
    v = JSON::Any.new(["abc123  file1.tar.gz", "def456  file2.tar.gz"].map { |s| JSON::Any.new(s) })
    engine = CrystalPlay::VariableSubstitutor::FilterEngine.new(Hash(String, JSON::Any).new)
    result = engine.apply(v, %(map('regex_findall', '^([a-fA-F0-9]+)\\s+(.+)$'))).as_a
    result.map { |m| m.as_a[0].as_a.map(&.as_s) }.should eq([["abc123", "file1.tar.gz"], ["def456", "file2.tar.gz"]])
  end

  it "dict(iterable_of_pairs) builds a dict from a positional iterable, not just kwargs" do
    # Real Ansible's Templar exposes actual Python's `dict` builtin
    # (not Jinja2's own `**kwargs`-only `dict` global) - the full
    # real-world shape (splitlines/regex_findall/flatten/reverse
    # chained into dict()) is covered end-to-end by expression_
    # evaluator_spec.cr; this is the narrower dict()-only case.
    vars = Hash(String, JSON::Any).new
    vars["pairs"] = JSON.parse(%([["a", 1], ["b", 2]]))
    result = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(vars).evaluate("dict(pairs)")
    (JSON.parse(result) rescue nil).should eq(JSON.parse(%({"a": 1, "b": 2})))
  end

  it "dict2items converts a flat dict to a list of {key, value} dicts in insertion order, defaults to key_name='key' value_name='value'" do
    # Real Ansible's own filter (NOT standard Jinja2; the Crinja corpus
    # confirms Python/Jinja2 reject it as "No filter named
    # 'dict2items'"). dev-sec os_hardening's own
    # os_hardening_set_os_variables.yml uses `with_dict` over an
    # os_vars mapping to apply per-mount config; the with_dict loop
    # binding is what the role's `loop: "{{ os_vars | dict2items }}"`
    # equivalent resolves to. Before this implementation, the
    # passthrough meant with_dict bound the WHOLE dict to a single
    # item, every downstream `item.key`/`item.value` was undefined,
    # and a regression spec for the related mode bug had to be
    # rewritten as a plain `set_fact: my_mode: "1777"` (see
    # spec/integration/mode_octal_via_variable_spec.cr, which is now
    # able to use the real os_hardening shape).
    input = JSON.parse(%({"a": 1, "b": 2, "c": 3}))
    result = engine.apply(input, "dict2items").as_a
    result.size.should eq(3)
    result.map(&.as_h).map { |h| {h["key"].as_s => h["value"].as_i} }.should eq([{"a" => 1_i64}, {"b" => 2_i64}, {"c" => 3_i64}])
  end

  it "dict2items honors custom key_name and value_name kwargs" do
    # Real Ansible accepts `dict2items(key_name='k', value_name='v')`
    # for callers that want the field names to be something other
    # than the defaults (prometheus's _common role uses a
    # 'label'/'value' pair elsewhere; the kwarg name itself is the
    # caller's choice, not hardcoded).
    input = JSON.parse(%({"x": "foo", "y": "bar"}))
    result = engine.apply(input, %(dict2items(key_name='name', value_name='data'))).as_a
    result.size.should eq(2)
    result[0].as_h.keys.sort!.should eq(["data", "name"])
    result[0].as_h["name"].as_s.should eq("x")
    result[0].as_h["data"].as_s.should eq("foo")
  end

  it "dict2items returns an empty list for an empty dict input" do
    engine.apply(JSON.parse(%({})), "dict2items").as_a.should eq([] of JSON::Any)
  end

  it "dict2items tolerates non-dict input (returns empty list, matching real Ansible's tolerance)" do
    # Real Ansible's filter returns an empty list for undefined / nil
    # / scalar input rather than raising - the same tolerance the
    # as_array helper provides for list-input filters. This matters
    # in practice for the os_hardening shape: a role that uses
    # `{{ some_dict | default({}) | dict2items }}` always gets a dict
    # in, but a more defensive `{{ some_dict | dict2items | ... }}`
    # without the default() should also work on a missing var.
    engine.apply(JSON::Any.new(nil), "dict2items").as_a.should eq([] of JSON::Any)
    engine.apply(s("not a dict"), "dict2items").as_a.should eq([] of JSON::Any)
  end

  it "items2dict is the inverse of dict2items and produces the original dict for a clean round-trip" do
    # Same Ansible-extension status as dict2items. The Crinja corpus
    # has one usage (postgresql_global_config_options evaluation in
    # community.general's collection form) classified as
    # `[ansible-filter-only]` rather than as a real engine bug, so
    # implementing it here is a natural follow-up to dict2items.
    original = JSON.parse(%({"a": 1, "b": 2, "c": 3}))
    items = engine.apply(original, "dict2items").as_a
    roundtrip = engine.apply(JSON::Any.new(items), "items2dict").as_h
    roundtrip.should eq(original.as_h)
  end

  it "items2dict honors custom key_name and value_name kwargs matching dict2items" do
    input = JSON.parse(%([{"name": "x", "data": "foo"}, {"name": "y", "data": "bar"}]))
    result = engine.apply(input, %(items2dict(key_name='name', value_name='data'))).as_h
    result["x"].as_s.should eq("foo")
    result["y"].as_s.should eq("bar")
  end

  it "items2dict on later-list-wins semantics for key collisions (matches combine()'s precedence)" do
    # Real Ansible's items2dict uses the same later-wins precedence
    # as combine() - if two list elements claim the same key_name, the
    # later one overwrites the earlier. Found this by reading the
    # ansible-core source; a role that depends on first-wins would be
    # a real bug to flag.
    input = JSON.parse(%([{"key": "a", "value": 1}, {"key": "a", "value": 2}]))
    result = engine.apply(input, "items2dict").as_h
    result["a"].as_i.should eq(2)
  end

  it "items2dict silently skips list elements that are not dicts or missing the key_name field" do
    # Real Ansible's filter doesn't crash on a malformed list element;
    # it just contributes nothing. A list mixing dicts, scalars, and
    # partial dicts is a real shape for an os_hardening-style role
    # that composes data from multiple sources before the dict2items
    # / items2dict round-trip.
    input = JSON.parse(%([
      {"key": "a", "value": 1},
      "not a dict",
      {"only_one_field": true},
      {"key": "b", "value": 2}
    ]))
    result = engine.apply(input, "items2dict").as_h
    result.keys.sort!.should eq(["a", "b"])
    result["a"].as_i.should eq(1)
    result["b"].as_i.should eq(2)
  end

  it "b64encode/b64decode round-trip" do
    encoded = engine.apply(s("hello world"), "b64encode").as_s
    encoded.should eq("aGVsbG8gd29ybGQ=")
    engine.apply(JSON::Any.new(encoded), "b64decode").as_s.should eq("hello world")
  end

  it "b64decode raises on invalid input" do
    expect_raises(Exception) { engine.apply(s("not valid base64!!"), "b64decode") }
  end

  it "from_json parses a JSON string into a real structure" do
    result = engine.apply(s(%({"a": 1, "b": [2, 3]})), "from_json")
    result.as_h["a"].as_i.should eq(1)
    result.as_h["b"].as_a.map(&.as_i).should eq([2, 3])
  end

  it "from_yaml parses a YAML string into a real structure" do
    result = engine.apply(s("a: 1\nb:\n  - 2\n  - 3\n"), "from_yaml")
    result.as_h["a"].as_i.should eq(1)
    result.as_h["b"].as_a.map(&.as_i).should eq([2, 3])
  end

  it "to_yaml dumps a structure as a YAML string" do
    result = engine.apply(JSON.parse(%({"b": 2, "a": 1})), "to_yaml").as_s
    result.should contain("a: 1")
    result.should contain("b: 2")
  end

  it "checksum computes a sha1 hex digest" do
    engine.apply(s("hello"), "checksum").as_s.should eq("aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d")
  end

  it "union combines two lists preserving order and dedup" do
    v = Hash(String, JSON::Any).new
    v["other"] = JSON.parse(%([2, 3, 4]))
    vars_engine = CrystalPlay::VariableSubstitutor::FilterEngine.new(v)
    result = vars_engine.apply(JSON.parse(%([1, 2, 3])), "union(other)")
    result.as_a.map(&.as_i).should eq([1, 2, 3, 4])
  end

  it "path_join joins a list of path components, an absolute one resets" do
    engine.apply(JSON.parse(%(["a", "b", "c.txt"])), "path_join").as_s.should eq("a/b/c.txt")
    engine.apply(JSON.parse(%(["a", "/b", "c.txt"])), "path_join").as_s.should eq("/b/c.txt")
  end

  it "splitext splits a path into [root, ext]" do
    result = engine.apply(s("/etc/foo.conf"), "splitext").as_a
    result.map(&.as_s).should eq(["/etc/foo", ".conf"])
  end

  it "urldecode percent-decodes a string" do
    engine.apply(s("hello%20world"), "urldecode").as_s.should eq("hello world")
  end

  it "urlsplit returns the full breakdown dict with no argument" do
    result = engine.apply(s("https://user:pass@example.com:8080/path?q=1#frag"), "urlsplit").as_h
    result["scheme"].as_s.should eq("https")
    result["hostname"].as_s.should eq("example.com")
    result["port"].as_s.should eq("8080")
    result["path"].as_s.should eq("/path")
    result["query"].as_s.should eq("q=1")
    result["fragment"].as_s.should eq("frag")
  end

  it "urlsplit returns a single component when given one" do
    engine.apply(s("https://example.com/path"), "urlsplit('hostname')").as_s.should eq("example.com")
  end

  it "zip combines lists element-wise, truncating to the shortest" do
    v = Hash(String, JSON::Any).new
    v["other"] = JSON.parse(%(["x", "y"]))
    vars_engine = CrystalPlay::VariableSubstitutor::FilterEngine.new(v)
    result = vars_engine.apply(JSON.parse(%([1, 2, 3])), "zip(other)").as_a
    result.map { |row| row.as_a.map(&.to_s) }.should eq([["1", "x"], ["2", "y"]])
  end

  it "zip_longest pads shorter lists with fillvalue" do
    v = Hash(String, JSON::Any).new
    v["other"] = JSON.parse(%(["x"]))
    vars_engine = CrystalPlay::VariableSubstitutor::FilterEngine.new(v)
    result = vars_engine.apply(JSON.parse(%([1, 2])), %(zip_longest(other, fillvalue="-"))).as_a
    result.map { |row| row.as_a.map(&.to_s) }.should eq([["1", "x"], ["2", "-"]])
  end

  it "product computes the Cartesian product with another list" do
    v = Hash(String, JSON::Any).new
    v["other"] = JSON.parse(%([1, 2]))
    vars_engine = CrystalPlay::VariableSubstitutor::FilterEngine.new(v)
    result = vars_engine.apply(JSON.parse(%(["a", "b"])), "product(other)").as_a
    result.map { |row| row.as_a.map(&.to_s) }.should eq([["a", "1"], ["a", "2"], ["b", "1"], ["b", "2"]])
  end

  it "regex_escape escapes regex special characters" do
    engine.apply(s("1.2.3"), "regex_escape").as_s.should eq("1\\.2\\.3")
  end

  it "to_nice_json pretty-prints with sorted keys by default" do
    result = engine.apply(JSON.parse(%({"b": 1, "a": 2})), "to_nice_json").as_s
    result.should eq(%({\n  "a": 2,\n  "b": 1\n}))
  end

  it "human_readable formats a byte count" do
    engine.apply(JSON::Any.new(1024_i64), "human_readable").as_s.should eq("1.00 KB")
    engine.apply(JSON::Any.new(500_i64), "human_readable").as_s.should eq("500 Bytes")
  end

  it "human_to_bytes parses a human-readable size back to bytes" do
    engine.apply(s("1KB"), "human_to_bytes").as_i64.should eq(1024)
    engine.apply(s("2GB"), "human_to_bytes").as_i64.should eq(2_i64 * 1024 * 1024 * 1024)
  end

  it "md5/sha1 compute standalone hex digests" do
    engine.apply(s("hello"), "md5").as_s.should eq("5d41402abc4b2a76b9719d911017c592")
    engine.apply(s("hello"), "sha1").as_s.should eq("aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d")
  end

  it "expanduser expands a leading ~" do
    ENV["HOME"] = "/home/testuser"
    engine.apply(s("~/foo"), "expanduser").as_s.should eq("/home/testuser/foo")
    engine.apply(s("~"), "expanduser").as_s.should eq("/home/testuser")
    engine.apply(s("/already/absolute"), "expanduser").as_s.should eq("/already/absolute")
  end

  it "expandvars expands $VAR/${VAR} from the controller's environment" do
    ENV["CRYSTAL_ANSIBLE_SPEC_EXPANDVAR"] = "hello"
    engine.apply(s("value=$CRYSTAL_ANSIBLE_SPEC_EXPANDVAR"), "expandvars").as_s.should eq("value=hello")
    engine.apply(s("value=${CRYSTAL_ANSIBLE_SPEC_EXPANDVAR}!"), "expandvars").as_s.should eq("value=hello!")
    ENV.delete("CRYSTAL_ANSIBLE_SPEC_EXPANDVAR")
  end

  it "normpath collapses . and .. without absolutizing" do
    engine.apply(s("a/./b/../c"), "normpath").as_s.should eq("a/c")
    engine.apply(s("/a/b/../../c"), "normpath").as_s.should eq("/c")
    engine.apply(s("../a/b"), "normpath").as_s.should eq("../a/b")
  end

  it "relpath computes a path relative to start=" do
    engine.apply(s("/a/b/c"), "relpath('/a')").as_s.should eq("b/c")
  end

  it "commonpath finds the longest common directory prefix" do
    engine.apply(JSON.parse(%(["/a/b/c", "/a/b/d", "/a/be"])), "commonpath").as_s.should eq("/a")
  end

  it "log computes natural log by default, arbitrary base otherwise" do
    engine.apply(JSON::Any.new(Math::E), "log").as_f.should be_close(1.0, 0.0001)
    engine.apply(JSON::Any.new(8.0), "log(2)").as_f.should be_close(3.0, 0.0001)
  end

  it "pow raises value to a power" do
    engine.apply(JSON::Any.new(2.0), "pow(10)").as_f.should be_close(1024.0, 0.0001)
  end

  it "to_uuid produces a deterministic UUID5 for the same input" do
    a = engine.apply(s("hello"), "to_uuid").as_s
    b = engine.apply(s("hello"), "to_uuid").as_s
    a.should eq(b)
    a.should match(/^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
  end

  it "symmetric_difference returns elements in exactly one of the two lists" do
    v = Hash(String, JSON::Any).new
    v["other"] = JSON.parse(%([2, 3, 4]))
    vars_engine = CrystalPlay::VariableSubstitutor::FilterEngine.new(v)
    result = vars_engine.apply(JSON.parse(%([1, 2, 3])), "symmetric_difference(other)").as_a.map(&.as_i).sort!
    result.should eq([1, 4])
  end

  it "combinations generates every n-length combination" do
    result = engine.apply(JSON.parse(%([1, 2, 3])), "combinations(2)").as_a
    result.map { |c| c.as_a.map(&.as_i) }.should eq([[1, 2], [1, 3], [2, 3]])
  end

  it "permutations generates every n-length ordered arrangement" do
    result = engine.apply(JSON.parse(%([1, 2])), "permutations").as_a
    result.map { |p| p.as_a.map(&.as_i) }.should eq([[1, 2], [2, 1]])
  end

  it "rekey_on_member converts a list of dicts into a dict keyed by a field" do
    input = JSON.parse(%([{"name": "a", "v": 1}, {"name": "b", "v": 2}]))
    result = engine.apply(input, "rekey_on_member('name')").as_h
    result["a"].as_h["v"].as_i.should eq(1)
    result["b"].as_h["v"].as_i.should eq(2)
  end

  it "extract indexes into a container using the piped value" do
    v = Hash(String, JSON::Any).new
    v["container"] = JSON.parse(%(["zero", "one", "two"]))
    vars_engine = CrystalPlay::VariableSubstitutor::FilterEngine.new(v)
    vars_engine.apply(JSON::Any.new(1_i64), "extract(container)").as_s.should eq("one")
  end

  it "from_yaml_all parses a multi-document YAML string" do
    result = engine.apply(s("a: 1\n---\nb: 2\n"), "from_yaml_all").as_a
    result[0].as_h["a"].as_i.should eq(1)
    result[1].as_h["b"].as_i.should eq(2)
  end

  it "vault/unvault round-trip through real ansible-vault ciphertext" do
    encrypted = engine.apply(s("plaintext"), %(vault('secret123'))).as_s
    encrypted.should start_with("$ANSIBLE_VAULT;")
    engine.apply(JSON::Any.new(encrypted), %(unvault('secret123'))).as_s.should eq("plaintext")
  end
end
