require "../spec_helper"
require "file_utils"
require "../../src/crystal_play/variable_substitutor/expression_evaluator"
# Pull in the real Ansible-specific Crinja filter registrations (to_datetime
# etc.), as template_action_plugin.cr does for every real template-rendering
# binary - without this the ExpressionEvaluator's Crinja env has none of them.
require "../../src/crystal_play/jinja_filters"

describe CrystalPlay::VariableSubstitutor::ExpressionEvaluator do
  it "dispatches simple lookups" do
    v = Hash(String, JSON::Any).new
    v["name"] = JSON::Any.new("ada")
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("name").should eq("ada")
  end

  it "dispatches nested lookups" do
    v = Hash(String, JSON::Any).new
    v["user"] = JSON.parse(%({"name": "ada"}))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("user.name").should eq("ada")
  end

  it "dispatches indexed access" do
    v = Hash(String, JSON::Any).new
    v["items"] = JSON.parse(%(["a", "b"]))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("items[0]").should eq("a")
  end

  it "dispatches comparisons before filters" do
    # Real Python/Jinja2 stringifies a comparison result as "True"/
    # "False" (capitalized), not Crystal's lowercase - verified directly
    # against real Python's own jinja2.Environment.
    v = Hash(String, JSON::Any).new
    v["rc"] = JSON::Any.new(0_i64)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("rc == 0").should eq("True")
  end

  it "applies a filter to a simple variable" do
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(missing | default('fallback'))).should eq("fallback")
  end

  it "evaluates a filter combined with a comparison in the same expression" do
    # Real, previously-shipped bug: has_comparison? matched before the `|`
    # check, so `mylist | length > 0` routed entirely to
    # ComparisonEvaluator with the filter chain still attached to the
    # operand text, which it had no way to evaluate - this always
    # returned "false" regardless of the actual list, in *any* {{ }}
    # substitution context (debug: msg:, when:, etc.), not just when:'s
    # own bare-conditional path.
    v = Hash(String, JSON::Any).new
    v["mylist"] = JSON::Any.new([JSON::Any.new("a"), JSON::Any.new("b"), JSON::Any.new("c")])
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("mylist | length > 0").should eq("True")

    v["mylist"] = JSON::Any.new([] of JSON::Any)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("mylist | length > 0").should eq("False")
  end

  it "evaluates range(stop) with the | list filter, matching Python's range()" do
    # Real bug found benchmarking a perf playbook: `loop: "{{ range(1, 11)
    # | list }}"` silently resolved to nil (fell through to plain variable
    # lookup on the literal text "range(1, 11)", always undefined),
    # running the loop body once with `item` undefined instead of 10
    # times.
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("range(3) | list").should eq(%([0,1,2]))
  end

  it "evaluates bare range(stop) with no filter at all" do
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("range(3)").should eq(%([0,1,2]))
  end

  it "evaluates range(start, stop)" do
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("range(1, 11) | list").should eq(%([1,2,3,4,5,6,7,8,9,10]))
  end

  it "evaluates range(start, stop, step) including a negative step" do
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("range(0, 10, 2) | list").should eq(%([0,2,4,6,8]))
    evaluator.evaluate("range(5, 0, -1) | list").should eq(%([5,4,3,2,1]))
  end

  it "evaluates range() arguments that are themselves variables" do
    v = Hash(String, JSON::Any).new
    v["n"] = JSON::Any.new(4_i64)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("range(1, n) | list").should eq(%([1,2,3]))
  end

  it "defaults lookup('first_found', ...) with no paths: to the current role's vars/ dir" do
    # Real bug found benchmarking geerlingguy.docker/mysql/postgresql/php,
    # which all share this exact idiom: `include_vars: "{{
    # lookup('first_found', params) }}"` with `vars: params: {files:
    # [...]}` and NO `paths:` at all - relying entirely on first_found's
    # own default search roots to find an OS-specific file living in the
    # role's own vars/ dir. Previously defaulted unconditionally to ".",
    # ignoring role context entirely, so the task always failed with
    # "file not found: undefined" for every role using this pattern.
    role_dir = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "first_found_role_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "vars"))
    File.write(File.join(role_dir, "vars", "Debian.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": ["Debian.yml"]}))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('first_found', params)").should eq(File.join(role_dir, "vars", "Debian.yml"))
  end

  it "still honors an explicit absolute paths: entry, unaffected by role-relative resolution" do
    role_dir = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "first_found_explicit_paths_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "otherdir"))
    File.write(File.join(role_dir, "otherdir", "x.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": ["x.yml"], "paths": [#{File.join(role_dir, "otherdir").to_json}]}))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('first_found', params)").should eq(File.join(role_dir, "otherdir", "x.yml"))
  end

  it "evaluates a quoted string literal piped into a filter chain" do
    # `{{ 'foo' | upper }}` - a literal, not a variable, as the chain's
    # head. Previously the base-value resolution in evaluate_with_filter
    # only understood a bare variable name, `(...)`, `range(...)`, or
    # `[...]` indexing as the chain's head - a quoted literal fell to the
    # plain-lookup fallback, treating the literal text (quotes included)
    # as a variable NAME to resolve, always undefined.
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("'hello' | upper").should eq("HELLO")
    evaluator.evaluate("'/var/log/mysql/mysql.err' | dirname").should eq("/var/log/mysql")
  end

  it "resolves an explicit relative paths: entry against the role dir, not cwd" do
    # The actual real-world spelling that broke geerlingguy.docker/mysql/
    # postgresql: `paths: ['vars']`, an explicit but RELATIVE entry -
    # previously joined straight against the process's cwd
    # ("vars/Debian.yml"), essentially never the role's own vars/ dir a
    # real ansible-playbook run resolves it against.
    role_dir = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "first_found_relative_paths_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "vars"))
    File.write(File.join(role_dir, "vars", "Debian.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": ["Debian.yml"], "paths": ["vars"]}))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('first_found', params)").should eq(File.join(role_dir, "vars", "Debian.yml"))
  end

  it "supports query('first_found', ...) as a real list, not just lookup()" do
    # Real bug found benchmarking buluma.confluence (round 165):
    # `query(...)` (real Ansible's lookup(..., wantlist=True) shorthand,
    # the standard idiom for `loop: "{{ query('first_found', params)
    # }}"`) was entirely unrecognized - only `lookup(` was matched,
    # so `query(...)` fell through to a plain variable-name lookup on
    # the literal call text, always "undefined".
    role_dir = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "query_first_found_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "vars"))
    File.write(File.join(role_dir, "vars", "Debian.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": ["Debian.yml"], "paths": ["vars"]}))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("query('first_found', params)").should eq(%([#{File.join(role_dir, "vars", "Debian.yml").to_json}]))
  end

  it "query('first_found', ...) with no match returns an empty list, not a single undefined item" do
    v = Hash(String, JSON::Any).new
    v["params"] = JSON.parse(%({"files": ["NoSuchFile.yml"], "paths": ["/nonexistent"]}))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("query('first_found', params)").should eq("[]")
  end

  it "resolves a first_found paths: entry relative to the role's tasks/ dir, not just role_path itself" do
    # buluma.confluence's own idiom: `paths: ['../vars']`, meant to be
    # interpreted relative to the INCLUDING TASK FILE's own directory
    # (tasks/main.yml -> tasks/../vars == role_dir/vars) - real
    # ansible-playbook resolves it this way; this engine previously only
    # ever tried role_path itself as the base (role_dir/../vars, one
    # level too far up), never finding the real file.
    role_dir = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "first_found_tasks_relative_spec")
    `rm -rf #{role_dir}`
    Dir.mkdir_p(File.join(role_dir, "vars"))
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    File.write(File.join(role_dir, "vars", "Debian.yml"), "greeting: hello\n")

    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    v["params"] = JSON.parse(%({"files": ["Debian.yml"], "paths": ["../vars"]}))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("lookup('first_found', params)").should eq(File.join(role_dir, "vars", "Debian.yml"))
  end

  it "evaluates lookup('env', 'VAR') for both a set and an unset environment variable" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `vault_version: "{{ lookup('env', 'VAULT_VERSION') | default(
    # '2.0.3', true) }}"` - lookup('env', ...) was entirely unimplemented
    # (only 'first_found' was), always "undefined" regardless of the
    # real env var.
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    ENV["CRYSTAL_ANSIBLE_SPEC_ENV_LOOKUP_TEST"] = "hello"
    evaluator.evaluate("lookup('env', 'CRYSTAL_ANSIBLE_SPEC_ENV_LOOKUP_TEST')").should eq("hello")
    ENV.delete("CRYSTAL_ANSIBLE_SPEC_ENV_LOOKUP_TEST")

    evaluator.evaluate("lookup('env', 'CRYSTAL_ANSIBLE_SPEC_ENV_LOOKUP_TEST')").should eq("")
  end

  it "renders a nested {{ }} span inside a lookup() string argument before using it" do
    # Real Ansible supports (with a deprecation warning) a lookup plugin
    # argument that is itself a quoted string CONTAINING a `{{ }}` span,
    # e.g. `lookup('file', "{{ dir }}/{{ name }}.txt")` - the inner span
    # gets rendered first, then the lookup runs against the real path.
    # Found via bodsch.tomcat's own checksum-file parsing: `lookup(
    # "file", "{{ tomcat_local_tmp_directory }}/apache-tomcat-{{
    # tomcat_version }}.tar.gz.sha512")`. Previously the literal path
    # text (quotes stripped, `{{ }}` markers untouched) was handed
    # straight to File.read, which never found the file - the lookup's
    # own "undefined" fallback then flowed into a real get_url: checksum
    # comparison ("checksum mismatch: expected undefined, got <real
    # sha512>") instead of the actual downloaded file's checksum.
    dir = File.tempname("expr_eval_lookup_spec")
    Dir.mkdir(dir)
    File.write(File.join(dir, "greeting.txt"), "hello there")

    v = Hash(String, JSON::Any).new
    v["mydir"] = JSON::Any.new(dir)
    v["myname"] = JSON::Any.new("greeting")
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate(%(lookup("file", "{{ mydir }}/{{ myname }}.txt"))).should eq("hello there")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "evaluates lookup('vars', name) as an indirect variable lookup" do
    v = Hash(String, JSON::Any).new
    v["env_prod_port"] = JSON::Any.new(8080_i64)
    v["target_env"] = JSON::Any.new("prod")
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate(%(lookup('vars', 'env_' + target_env + '_port'))).should eq("8080")
  end

  it "evaluates lookup('vars', ...) as undefined for a name that doesn't resolve" do
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate(%(lookup('vars', 'no_such_variable'))).should eq("undefined")
  end

  it "evaluates lookup('file', path) reading a controller-side file, trailing newline stripped" do
    path = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "lookup_file_test.txt")
    Dir.mkdir_p(File.dirname(path))
    File.write(path, "secret-content\n")

    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('file', '#{path}'))).should eq("secret-content")
  end

  # Real bug found benchmarking andrewrothstein.ssh-user-keygen (0.9.616):
  # real Ansible's `file` lookup RAISES for a missing file ("Unable to
  # access the file '<path>': File not found"), failing the task's arg
  # finalization - it does NOT fall back to a placeholder the way a
  # genuinely-undefined VARIABLE reference does elsewhere in this
  # evaluator. The previous "undefined" fallback let the literal text
  # "undefined" get written straight into a real target file
  # (`~/.ssh/authorized_keys`, via `lookup('file', ssh_user_pubkey)` on
  # a host with no `~/.ssh/id_rsa.pub`) instead of failing like real
  # Ansible does.
  it "raises (does not silently return 'undefined') for lookup('file', ...) on a missing file" do
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    expect_raises(Exception, /lookup plugin 'file' failed.*File not found/) do
      evaluator.evaluate(%(lookup('file', '/no/such/file/at/all')))
    end
  end

  it "evaluates lookup('pipe', command) running a local shell command" do
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('pipe', 'echo hello-from-pipe'))).should eq("hello-from-pipe")
  end

  it "evaluates lookup('template', path) rendering a local .j2 file against expression vars" do
    path = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "lookup_template_test.j2")
    Dir.mkdir_p(File.dirname(path))
    File.write(path, "value is {{ my_var }}\n")

    v = Hash(String, JSON::Any).new
    v["my_var"] = JSON::Any.new("computed")
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('template', '#{path}'))).should eq("value is computed")
  end

  it "evaluates lookup('password', path) generating and persisting a password across calls" do
    path = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "lookup_password_test.txt")
    File.delete(path) if File.exists?(path)

    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    first = evaluator.evaluate(%(lookup('password', '#{path}')))
    first.should_not be_empty
    File.exists?(path).should be_true

    second = evaluator.evaluate(%(lookup('password', '#{path}')))
    second.should eq(first)
    File.delete(path)
  end

  it "evaluates lookup('password', ...) honoring length=" do
    path = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "lookup_password_length_test.txt")
    File.delete(path) if File.exists?(path)

    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    result = evaluator.evaluate(%(lookup('password', '#{path} length=8')))
    result.size.should eq(8)
    File.delete(path)
  end

  it "evaluates lookup('dict', ...) as a list of {key, value} dicts" do
    v = Hash(String, JSON::Any).new
    v["mydict"] = JSON.parse(%({"a": 1, "b": 2}))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    result = JSON.parse(evaluator.evaluate("lookup('dict', mydict)"))
    result.as_a.map { |item| {item["key"].as_s, item["value"].as_i} }.should eq([{"a", 1}, {"b", 2}])
  end

  it "evaluates lookup('list', ...) returning every term as a list" do
    v = Hash(String, JSON::Any).new
    v["a"] = JSON::Any.new(1_i64)
    v["b"] = JSON::Any.new(2_i64)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    JSON.parse(evaluator.evaluate("lookup('list', a, b)")).as_a.map(&.as_i).should eq([1, 2])
  end

  it "evaluates lookup('items', ...) flattening list terms one level" do
    v = Hash(String, JSON::Any).new
    v["l1"] = JSON.parse(%([1, 2]))
    v["l2"] = JSON.parse(%([3, 4]))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    JSON.parse(evaluator.evaluate("lookup('items', l1, l2)")).as_a.map(&.as_i).should eq([1, 2, 3, 4])
  end

  it "evaluates lookup('together', ...) zipping lists, padding shorter ones with null" do
    v = Hash(String, JSON::Any).new
    v["l1"] = JSON.parse(%([1, 2, 3]))
    v["l2"] = JSON.parse(%(["x", "y"]))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    result = JSON.parse(evaluator.evaluate("lookup('together', l1, l2)")).as_a
    result[0].as_a.should eq([JSON::Any.new(1_i64), JSON::Any.new("x")])
    result[2].as_a[1].raw.should be_nil
  end

  it "evaluates lookup('nested', ...) as a Cartesian product" do
    v = Hash(String, JSON::Any).new
    v["l1"] = JSON.parse(%(["a", "b"]))
    v["l2"] = JSON.parse(%([1, 2]))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    result = JSON.parse(evaluator.evaluate("lookup('nested', l1, l2)")).as_a
    result.map { |row| row.as_a.map(&.to_s) }.should eq([["a", "1"], ["a", "2"], ["b", "1"], ["b", "2"]])
  end

  it "evaluates lookup('lines', ...) splitting command output into a list of lines" do
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    JSON.parse(evaluator.evaluate(%(lookup('lines', 'printf "a\\nb\\nc\\n"')))).as_a.map(&.as_s).should eq(["a", "b", "c"])
  end

  it "evaluates lookup('varnames', ...) returning matching variable NAMES, not values" do
    v = Hash(String, JSON::Any).new
    v["nginx_port"] = JSON::Any.new(80_i64)
    v["nginx_host"] = JSON::Any.new("example.com")
    v["apache_port"] = JSON::Any.new(8080_i64)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    result = JSON.parse(evaluator.evaluate(%(lookup('varnames', '^nginx_')))).as_a.map(&.as_s).sort!
    result.should eq(["nginx_host", "nginx_port"])
  end

  it "evaluates lookup('sequence', ...) generating a numeric range" do
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    JSON.parse(evaluator.evaluate(%(lookup('sequence', 'start=1 end=3')))).as_a.map(&.as_s).should eq(["1", "2", "3"])
  end

  it "evaluates lookup('sequence', ...) honoring the shorthand start-end form and format=" do
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    JSON.parse(evaluator.evaluate(%(lookup('sequence', '1-3 format=web%02d')))).as_a.map(&.as_s).should eq(["web01", "web02", "web03"])
  end

  it "evaluates lookup('indexed_items', ...) as [index, item] pairs" do
    v = Hash(String, JSON::Any).new
    v["l"] = JSON.parse(%(["a", "b"]))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    result = JSON.parse(evaluator.evaluate("lookup('indexed_items', l)")).as_a
    result.map { |pair| {pair[0].as_i, pair[1].as_s} }.should eq([{0, "a"}, {1, "b"}])
  end

  it "evaluates lookup('random_choice', ...) returning one element from the combined lists" do
    v = Hash(String, JSON::Any).new
    v["l"] = JSON.parse(%(["only"]))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate("lookup('random_choice', l)").should eq("only")
  end

  it "evaluates lookup('subelements', ...) yielding [parent, child] pairs" do
    v = Hash(String, JSON::Any).new
    v["users"] = JSON.parse(%([{"name": "alice", "groups": ["a", "b"]}, {"name": "bob", "groups": ["c"]}]))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    result = JSON.parse(evaluator.evaluate("lookup('subelements', users, 'groups')")).as_a
    result.size.should eq(3)
    result[0].as_a[0].as_h["name"].as_s.should eq("alice")
    result[0].as_a[1].as_s.should eq("a")
  end

  it "evaluates lookup('csvfile', ...) finding a row by key and returning a column" do
    path = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "lookup_csvfile_test.csv")
    File.write(path, "alice,30,engineer\nbob,25,designer\n")

    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('csvfile', 'bob file=#{path} delimiter=, col=2'))).should eq("designer")
    File.delete(path)
  end

  it "evaluates lookup('ini', ...) reading a value from a section" do
    path = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "lookup_ini_test.ini")
    File.write(path, "[web]\nport = 8080\n\n[db]\nport = 5432\n")

    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('ini', 'port section=db file=#{path}'))).should eq("5432")
    File.delete(path)
  end

  it "evaluates lookup('unvault', ...) decrypting a file with the session's vault password" do
    path = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "lookup_unvault_test.txt")
    File.write(path, CrystalPlay::Vault.encrypt("top secret", "runpassword"))
    CrystalPlay::Vault.password = "runpassword"

    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(lookup('unvault', '#{path}'))).should eq("top secret")

    CrystalPlay::Vault.password = nil
    File.delete(path)
  end

  it "resolves lookup(...) followed by a filter chain, not swallowing the whole thing as one bare call" do
    # Real bug found alongside the env lookup above: `lookup('env',
    # 'VAULT_VERSION') | default('2.0.3', true)` - the naive `starts_with
    # ("lookup(") && ends_with(')')` check in evaluate_expr matched the
    # *whole* string (default(...)'s own closing paren satisfies
    # ends_with(')') too, not just lookup(...)'s), swallowing the entire
    # filter chain into evaluate_lookup as one garbled, unbalanced
    # argument before top_level_pipe?/evaluate_with_filter ever got a
    # chance to split it properly. An unset env var with no matching
    # default(..., true) call previously stayed the literal string
    # "undefined" (non-empty, so default()'s own falsy check never fired
    # even once reached) instead of "" (real Ansible's own lookup('env',
    # ...) return for an unset var).
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate(%(lookup('env', 'CRYSTAL_ANSIBLE_SPEC_ENV_LOOKUP_TEST_2') | default('2.0.3', true))).should eq("2.0.3")
  end

  it "evaluates an else-less inline if as empty string when the condition is false" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `vault_version_release_site_suffix: "{{ '+ent' if vault_enterprise
    # }}{{ '.hsm' if vault_enterprise_hsm }}"` - real Jinja2 renders the
    # missing else branch as "" (Undefined's default __str__), but this
    # fell through to plain variable lookup on the literal text `'+ent' if
    # vault_enterprise`, always resolving to "undefined".
    v = Hash(String, JSON::Any).new
    v["vault_enterprise"] = JSON::Any.new(false)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%('+ent' if vault_enterprise)).should eq("")

    v["vault_enterprise"] = JSON::Any.new(true)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%('+ent' if vault_enterprise)).should eq("+ent")
  end

  it "resolves a ternary whose branches are bare boolean literals, not quoted strings" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `vault_tls_copy_keys: "{{ false if (vault_install_hashi_repo) else
    # true }}"` - the chosen branch's bare `true`/`false` text (as
    # opposed to a quoted string literal like '+ent') fell through to a
    # plain variable lookup on that literal identifier, always
    # "undefined" - which `| bool` downstream then treated as truthy
    # regardless of the actual condition.
    # Real Python/Jinja2 stringifies a bare boolean as "True"/"False"
    # (capitalized), not Crystal's lowercase "true"/"false" - verified
    # directly against real Python's own jinja2.Environment.
    v = Hash(String, JSON::Any).new
    v["vault_install_hashi_repo"] = JSON::Any.new(false)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("false if vault_install_hashi_repo else true").should eq("True")

    v["vault_install_hashi_repo"] = JSON::Any.new(true)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("false if vault_install_hashi_repo else true").should eq("False")
  end

  it "re-templates a filter chain's own head variable when its raw value is still unrendered Jinja" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `vault_tls_gossip: "{{ lookup('env', 'VAULT_TLS_GOSSIP') | default(
    # false, true) }}"` used later as `vault_tls_gossip | bool` - the
    # filter chain's own head-variable resolution (the plain-lookup
    # fallback in evaluate_with_filter) returned the raw, unrendered
    # template text unchanged, which is a non-empty string - so `| bool`
    # saw it as truthy regardless of what it actually rendered to.
    v = Hash(String, JSON::Any).new
    v["vault_tls_gossip"] = JSON::Any.new(%({{ lookup('env', 'CRYSTAL_ANSIBLE_SPEC_FILTER_ENV_TEST') | default(false, true) }}))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("vault_tls_gossip | bool").should eq("False")

    ENV["CRYSTAL_ANSIBLE_SPEC_FILTER_ENV_TEST"] = "true"
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("vault_tls_gossip | bool").should eq("True")
    ENV.delete("CRYSTAL_ANSIBLE_SPEC_FILTER_ENV_TEST")
  end

  it "concatenates operands with Jinja2's `~` string-concat operator" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `vault_version~('+ent' if vault_enterprise)` (a bare-`~`
    # concatenation whose right operand is itself a parenthesized,
    # else-less ternary) - `~` was entirely unimplemented anywhere in the
    # engine, so the whole expression fell through to a plain (always-
    # undefined) variable lookup on the literal text.
    v = Hash(String, JSON::Any).new
    v["vault_version"] = JSON::Any.new("2.0.3")
    v["vault_enterprise"] = JSON::Any.new(false)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("vault_version~('+ent' if vault_enterprise)").should eq("2.0.3")

    v["vault_enterprise"] = JSON::Any.new(true)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("vault_version~('+ent' if vault_enterprise)").should eq("2.0.3+ent")
  end

  it "renders a bare numeric literal, alone or as a filter chain's own head" do
    # Real bug found in the same investigation as the */÷ arithmetic fix
    # below: a bare numeric literal was never checked anywhere in this
    # dispatch chain on its own (only ever as an *operand* inside a
    # `+`/`-`/`*`/`/` expression) - `{{ 5 }}` alone, or `{{ 5.7 | int
    # }}` (a literal float piped straight into a filter, no variable or
    # arithmetic involved), both fell through to a plain variable-name
    # lookup on the literal digit text itself, always "undefined".
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate("5").should eq("5")
    evaluator.evaluate("5.7").should eq("5.7")
    evaluator.evaluate("5.7 | int").should eq("5")
    evaluator.evaluate("(5.7) | int").should eq("5")
  end

  it "evaluates *, /, and // arithmetic, matching real Jinja2/Python semantics exactly" do
    # Real bug found benchmarking geerlingguy.swap's own check-size.yml:
    # `(swap_file_check.stat.size / 1024 / 1024) | int` (converting a
    # stat'd byte count to MB) - `*`/`/`/`//` were entirely unimplemented
    # anywhere in the engine (only `+`/`-`/`~` had top-level operator
    # support), so even a bare `{{ 10 / 2 }}` rendered the literal
    # string "undefined". The whole file-size comparison this feeds
    # always differed, deleting and recreating the swap file on every
    # single run instead of converging. Values verified directly against
    # real Python's own jinja2.Environment: `/` always produces a float
    # (true division, even when evenly divisible), `*` preserves int
    # when both operands are int, `//` floors to int, and `*`/`/` bind
    # tighter than `+`/`-` (`2 + 3 * 4` == 14, not 20).
    v = Hash(String, JSON::Any).new
    v["n"] = JSON::Any.new(268435456_i64)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate("10 / 2").should eq("5.0")
    evaluator.evaluate("10 / 3").should eq("3.3333333333333335")
    evaluator.evaluate("10 // 3").should eq("3")
    evaluator.evaluate("10 * 2").should eq("20")
    evaluator.evaluate("2.5 * 2").should eq("5.0")
    evaluator.evaluate("2 + 3 * 4").should eq("14")
    evaluator.evaluate("n / 1024 / 1024").should eq("256.0")
  end

  it "doesn't crash on integer floor division by zero" do
    # `10 // 0` previously raised an uncaught OverflowError (`(10.0 /
    # 0.0).floor` is Float64::INFINITY, and `Infinity.to_i64` overflows
    # Int64) - found probing whether */,/// were safe to converge to
    # Crinja-first for CRINJA.md step 5. `/`'s own by-zero case already
    # degrades leniently to "Infinity" rather than raising; `//` now
    # matches that convention (nil/"undefined") instead of crashing.
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("10 // 0").should eq("")
  end

  it "evaluates a full boolean expression (is test, or, comparison) inside a plain {{ }} span" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # `installation_required: "{{ vault_installation is failed or
    # installed_vault_version.stdout != vault_version~(...) }}"` -
    # ConditionalEvaluator (used for bare when:/failed_when:/assert
    # conditions) already understood `is failed`/`or`/comparisons, but
    # this evaluator (used for {{ }} spans, e.g. set_fact: values) had no
    # concept of any of the three - `is failed` alone rendered
    # "undefined", and the whole `or` expression fell through to a plain
    # (always-undefined) variable lookup on the literal text, which
    # formatted as truthy "True" regardless of the real values.
    v = Hash(String, JSON::Any).new
    v["result"] = JSON.parse(%({"failed": false}))
    v["a"] = JSON::Any.new("x")
    v["b"] = JSON::Any.new("x")
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("result is failed or a != b").should eq("False")

    v["b"] = JSON::Any.new("y")
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("result is failed or a != b").should eq("True")
  end

  it "treats a plain-value `or`/`and` as a value-selector, not a boolean coercion" do
    # Real bug found benchmarking robertdebock.users: `groups: "{{
    # user.groups | default([]) | join(',') or omit }}"` - since neither
    # operand is a boolean condition (no comparison/is-test), real
    # Jinja2's `or` must return the joined string itself when truthy,
    # not the literal text "True". The fix above only added boolean
    # coercion for genuine conditions; a plain "X or Y" previously still
    # rendered "True"/"False" regardless of X/Y's actual values -
    # `useradd: group 'True' does not exist` was the resulting failure.
    v = Hash(String, JSON::Any).new
    v["groups"] = JSON.parse(%(["ops", "sudo"]))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("groups | join(',') or omit").should eq("ops,sudo")

    v["groups"] = JSON.parse(%([]))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("groups | join(',') or omit").should eq(CrystalPlay::OMIT_SENTINEL)

    v2 = Hash(String, JSON::Any).new
    evaluator2 = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v2)
    evaluator2.evaluate("'ops,sudo' or 'fallback'").should eq("ops,sudo")
    evaluator2.evaluate("'' or 'fallback'").should eq("fallback")
    evaluator2.evaluate("5 or 'fallback'").should eq("5")
  end

  it "treats a plain-value `and` as a value-selector too" do
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("'first' and 'second'").should eq("second")
    evaluator.evaluate("'' and 'second'").should eq("")
  end

  it "resolves a dict.get() call whose key argument itself contains indexing" do
    # Real bug found benchmarking prometheus.prometheus.node_exporter's
    # own `_node_exporter_go_ansible_arch` default: `{'x86_64': 'amd64',
    # ...}.get(ansible_facts['architecture'], ansible_facts
    # ['architecture'])`. evaluate_bracket_or_dict_expr's own
    # `expr.includes?("[")` was a blunt any-position check - the `[`
    # nested inside .get()'s own argument wrongly routed the WHOLE
    # expression to indexed-access handling instead of the dotted
    # method-call dispatch its own top-level structure actually needs.
    v = Hash(String, JSON::Any).new
    v["ansible_facts"] = JSON.parse(%({"architecture": "x86_64"}))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate(%({'x86_64': 'amd64'}.get(ansible_facts['architecture'], ansible_facts['architecture']))).should eq("amd64")
  end

  it "converges dict(iterable) positional form (0.9.340)" do
    # prometheus.prometheus.node_exporter's `dict(raw.splitlines() |
    # map(...) | map('flatten') | map('reverse'))` builds a checksum
    # lookup from a positional iterable of [key,value] pairs. Previously
    # this routed through hand-rolled evaluate_dict_call. Now try-Crinja
    # first (fork crystal-play-0.9.4 fixed dict()'s kernel-args-only
    # empty-dict bug); the fallback is identical if anything raises.
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%(dict([['a', 1], ['b', 2]]))).should eq(%({"a":1,"b":2}))
    evaluator.evaluate(%(dict({'x': 'y'}))).should eq(%({"x":"y"}))
  end

  it "renders to_datetime(...) - to_datetime(...) .days through Crinja (0.9.341)" do
    # dev-sec os_hardening's password-ageing assert: `( a | to_datetime -
    # b | to_datetime ).days`. The leading-paren construct routes the WHOLE
    # expression to Crinja first; fork Time arithmetic (crystal-play-0.9.5)
    # + jinja_filters.cr's to_datetime (Ansible-specific) make it succeed
    # in one pass instead of falling back to the hand-rolled tagged-JSON
    # path. Either way the answer is the same - this pins it.
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(
      %(( 'Jan 02, 2024' | to_datetime('%b %d, %Y') - 'Jan 01, 2024' | to_datetime('%b %d, %Y') ).days)
    ).should eq("1")
  end

  it "compares a dotted operand against a `~`-concatenated one, full ansible-vault expression" do
    # End-to-end regression for the exact expression benchmarked from
    # ansible-community.ansible-vault's own "Compute if installation is
    # required" task: `installed_vault_version.stdout != vault_version~
    # ('+ent' if vault_enterprise)`. Comparison operators must be
    # detected (has_comparison?) before the `~` split ever runs, or the
    # whole thing gets sliced on `~` first instead of `!=` - covering the
    # dispatch-order interaction directly, on top of the narrower
    # ComparisonEvaluator-only and ExpressionEvaluator-only specs above.
    v = Hash(String, JSON::Any).new
    v["installed_vault_version"] = JSON.parse(%({"stdout": "2.0.3"}))
    v["vault_version"] = JSON::Any.new("2.0.3")
    v["vault_enterprise"] = JSON::Any.new(false)
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("installed_vault_version.stdout != vault_version~('+ent' if vault_enterprise)").should eq("False")
  end

  it "evaluates a bare quoted string literal with no filter/operator at all" do
    # Real bug found benchmarking cloudalchemy.prometheus: a bare
    # literal containing a `.` (routine for a URL or IP address -
    # `lookup('url', '...' + version + '...')`'s own URL argument, once
    # split out and re-evaluated as its own operand) fell through to
    # the `expr.includes?(".")` dotted-lookup branch, which treated the
    # literal text - quotes included - as a dotted variable PATH rather
    # than a plain string value, always undefined. No prior spec covered
    # a bare `{{ '...' }}` span with no `|`/ternary/operator at all.
    v = Hash(String, JSON::Any).new
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%('http://127.0.0.1:8080/some.file.txt')).should eq("http://127.0.0.1:8080/some.file.txt")
  end

  it "does not mistake a `+` chain starting and ending in quotes for one bare literal" do
    # Real regression introduced fixing the bug above: the bare-literal
    # check used #quoted_string_literal (first/last char only), which
    # also matches `'a' + var + 'b'` - both ends are quotes too, just not
    # the SAME literal. Caught immediately via cloudalchemy.prometheus's
    # own `lookup('url', 'https://...v' + prometheus_version + '/...',
    # wantlist=True)` - the URL argument gets re-evaluated as its own
    # bare operand, and the naive check stripped only the outer quotes,
    # leaving " + prometheus_version + " as literal garbage text in the
    # middle of the "URL".
    v = Hash(String, JSON::Any).new
    v["prometheus_version"] = JSON::Any.new("2.27.0")
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate(%('https://example.com/v' + prometheus_version + '/sums.txt')).should eq("https://example.com/v2.27.0/sums.txt")
  end

  it "routes a slice with both bounds present to ArraySlicer, not just an empty-bound slice" do
    # Real bug found probing whether the `[`-dispatch branch was safe to
    # converge to Crinja-first (CRINJA.md step 5): the slice-detection
    # check was `expr.includes?("[:") || expr.includes?(":]")`, which
    # only matches an EMPTY start or end (`items[:3]`, `items[2:]`) -
    # `items[1:3]` (both bounds present) has neither literal substring
    # (a digit sits between `[`/`:` and between `:`/`]`), so it fell
    # through to `@lookup.indexed`, which has no slice handling at all,
    # always resolving to "undefined" even though `ArraySlicer#slice`
    # itself handles this exact input correctly when called directly.
    v = Hash(String, JSON::Any).new
    v["items"] = JSON.parse(%(["a", "b", "c", "d"]))
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("items[1:3]").should eq(%(["b","c"]))
    evaluator.evaluate("items[:2]").should eq(%(["a","b"]))
    evaluator.evaluate("items[2:]").should eq(%(["c","d"]))
  end

  it "re-templates a dotted-access BASE whose Crinja lookup returns nil (not just on a Crinja exception)" do
    # Real bug found benchmarking robertdebock.spamassassin: `vars/
    # main.yml`'s own `spamassassin_service: "{{ _spamassassin_service[
    # ansible_facts['os_family'] ~ '-' ~ ansible_facts[
    # 'distribution_major_version']] | default(...) }}"` stores itself
    # as unrendered `{{ }}` text (a role default computed from a
    # dict-index-with-fallback chain) - `{{ spamassassin_service }}`
    # alone rendered fine (the outer multi-pass re-templating loop in
    # VariableSubstitutor#substitute catches a bare leftover "{{"), but
    # `{{ spamassassin_service.name }}` resolved to the literal string
    # "undefined" instead of "spamassassin". Root cause: the dotted-
    # access dispatch tries Crinja first, and Crinja's own vars are
    # never re-templated - attribute access on the raw `{{ }}` string
    # fails to Crinja's Undefined (not an exception), so `render_via_
    # crinja_value` returned a quiet `nil` - the fallback to `@lookup.
    # nested` (which already had the correct re-templating fix) only
    # ever ran on an actual *exception*, never on this quiet nil.
    v = Hash(String, JSON::Any).new
    v["inner_dict"] = JSON.parse(%({"name":"spamassassin","state":"started"}))
    v["outer_var"] = JSON::Any.new("{{ inner_dict }}")
    evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(v)
    evaluator.evaluate("outer_var").should eq(%({"name":"spamassassin","state":"started"}))
    evaluator.evaluate("outer_var.name").should eq("spamassassin")
  end

  describe "process-wide dispatch-shape cache (SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #4)" do
    # #split_ternary/#split_ternary_no_else/#boolean_logic? are now
    # memoized by literal expr text in a process-wide (not per-instance)
    # Hash, since which of the 4 dispatch shapes a `{{ }}` body's TEXT
    # has is a pure function of that text. These specs are the "does the
    # shared cache generalize correctly" net: the SAME literal expr
    # string, evaluated by DIFFERENT ExpressionEvaluator instances (each
    # with its own @vars), must still produce each instance's own
    # correct result - a broken cache (e.g. one that accidentally
    # memoized a RESULT instead of just the shape) would show the first
    # instance's answer leaking into the second.
    it "evaluates the same literal ternary text correctly across different ExpressionEvaluator instances/values" do
      first = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any){"flag" => JSON::Any.new(true)})
      second = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any){"flag" => JSON::Any.new(false)})

      first.evaluate("'yes' if flag else 'no'").should eq("yes")
      second.evaluate("'yes' if flag else 'no'").should eq("no")
      # Re-check the first AFTER the second ran, on the identical literal
      # text - a cache keyed on the wrong thing (e.g. a memoized RESULT
      # rather than just "this text has ternary shape") would show the
      # second instance's answer bleeding into the first here.
      first.evaluate("'yes' if flag else 'no'").should eq("yes")
    end

    it "evaluates the same literal else-less-ternary text correctly across different values" do
      first = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any){"flag" => JSON::Any.new(true)})
      second = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any){"flag" => JSON::Any.new(false)})

      first.evaluate("'shown' if flag").should eq("shown")
      second.evaluate("'shown' if flag").should eq("")
    end

    it "evaluates the same literal boolean-logic text correctly across different values" do
      first = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any){"a" => JSON::Any.new(true), "b" => JSON::Any.new(false)})
      second = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any){"a" => JSON::Any.new(false), "b" => JSON::Any.new(false)})

      first.evaluate("a or b").should eq("True")
      second.evaluate("a or b").should eq("False")
    end

    it "still falls through to the plain evaluator for text that has no top-level ternary/boolean-logic shape at all" do
      # A cached "no match" (nil/false) result is the common case - most
      # `{{ }}` bodies aren't ternaries or boolean-logic expressions -
      # and is exactly the case a naive `||=`-based cache would fail to
      # memoize at all (nil looks like "not cached yet" to `||=`),
      # silently defeating most of the point of caching. Evaluated twice
      # to exercise both the cache-miss (first call) and cache-hit
      # (second call) path for the SAME "no match" text.
      evaluator = CrystalPlay::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any){"x" => JSON::Any.new(5_i64)})
      evaluator.evaluate("x + 1").should eq("6")
      evaluator.evaluate("x + 1").should eq("6")
    end
  end
end
