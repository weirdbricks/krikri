require "../minitest_helper"
require "../../src/krikri/variable_substitutor"
require "../../src/krikri/krikri_jinja_lookups"
require "../../src/krikri/krikri_jinja_filters"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook_binary(pb : String) : {Process::Status, String, String}
  playbook = File.tempname("config-lookup-typed", ".yml")
  File.write(playbook, pb)
  out_io = IO::Memory.new
  err_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: out_io, error: err_io)
  {status, out_io.to_s, err_io.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# Real divergences found benchmarking buluma.multi (round 29883644, GitHub
# issue #441): the config lookup returned ansible's option values as raw
# strings with no TYPE casting. `lookup('config', 'DEFAULT_ROLES_PATH')`
# handed back the colon-joined default ("~/.ansible/roles:/usr/share/...")
# where real ansible-core 2.19's config manager casts the pathspec-typed
# option to a real list of home-expanded paths (its debug msg renders
# Python list repr), and `q('config', 'remote_tmp',
# plugin_type='shell', plugin_name='sh')` came back as [""] because
# 'remote_tmp' only exists as a connection/shell PLUGIN option (default
# '~/.ansible/tmp'), not a global one.
describe "lookup('config', ...) typed values" do
  def expected_roles_path_entries : Array(String)
    home = ENV["HOME"]?
    first = home && !home.empty? ? File.join(home, ".ansible/roles") : "~/.ansible/roles"
    [first, "/usr/share/ansible/roles", "/etc/ansible/roles"]
  end

  it "resolves a pathspec option as a real list in the hand-rolled evaluator" do
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any).new)
    rendered = evaluator.evaluate("lookup('config', 'DEFAULT_ROLES_PATH')")
    JSON.parse(rendered).as_a.map(&.as_s).must_equal(expected_roles_path_entries)
  end

  it "resolves a pathspec option as a real list in the krikri-jinja engine" do
    renderer = Krikri::VariableSubstitutor::JinjaRenderer.new({} of String => JSON::Any)
    rendered = renderer.render("{{ lookup('config', 'DEFAULT_ROLES_PATH') }}")
    Krikri.parse_json_or_python_literal(rendered).as_a.map(&.as_s).must_equal(expected_roles_path_entries)
  end

  it "renders an embedded pathspec lookup as Python list repr like ansible" do
    sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h1")
    expected = expected_roles_path_entries.map { |entry| "'#{entry}'" }.join(", ")
    # output: true - the task-param finalization route (what a debug msg:
    # goes through), where the list-forcing repr conversion lives.
    sub.substitute("These are the configured role paths: {{ lookup('config', 'DEFAULT_ROLES_PATH') }}", output: true)
      .must_equal("These are the configured role paths: [#{expected}]")
  end

  it "resolves the shell plugin's remote_tmp through its plugin kwargs" do
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any).new)
    evaluator.evaluate("q('config', 'remote_tmp', plugin_type='shell', plugin_name='sh')")
      .must_equal("[\"~/.ansible/tmp\"]")
    renderer = Krikri::VariableSubstitutor::JinjaRenderer.new({} of String => JSON::Any)
    rendered = renderer.render("{{ q('config', 'remote_tmp', plugin_type='shell', plugin_name='sh') }}")
    Krikri.parse_json_or_python_literal(rendered).as_a.map(&.as_s).must_equal(["~/.ansible/tmp"])
  end

  it "keeps a bare remote_tmp lookup on the unknown-option empty fallback" do
    # 'remote_tmp' is not a global ansible.cfg option - real's config lookup
    # fails with "No config definition exists for 'remote_tmp'" without the
    # plugin kwargs. krikri's lookup stays silently lenient for unknown
    # options (its pervasive convention), but must not invent the plugin
    # default for the bare form either.
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any).new)
    evaluator.evaluate("lookup('config', 'remote_tmp')").must_equal("")
  end

  it "keeps scalar config lookups plain strings" do
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(Hash(String, JSON::Any).new)
    evaluator.evaluate("lookup('config', 'COLOR_OK')").must_equal("green")
    evaluator.evaluate("lookup('config', 'DEFAULT_FORKS')").must_equal("5")
    evaluator.evaluate("lookup('config', 'COLOR_OK', 'COLOR_CHANGED', wantlist=True)")
      .must_equal("[\"green\",\"yellow\"]")
  end

  it "prints the buluma.multi msgs byte-identically end to end" do
    expected_roles = expected_roles_path_entries.map { |entry| "'#{entry}'" }.join(", ")
    status, out, _err = run_playbook_binary(<<-YAML
      - name: repro
        hosts: localhost
        connection: local
        tasks:
          - name: Print out role paths
            ansible.builtin.debug:
              msg: "These are the configured role paths: {{ lookup('config', 'DEFAULT_ROLES_PATH') }}"
          - name: Show remote_tmp setting for shell (sh) plugin
            ansible.builtin.debug:
              msg: "{{ q('config', 'remote_tmp', plugin_type='shell', plugin_name='sh') }}"
      YAML
    )
    status.success?.must_equal(true)
    out.must_include("These are the configured role paths: [#{expected_roles}]")
    out.must_include("\"msg\": [\n        \"~/.ansible/tmp\"\n    ]")
  end
end
