require "../minitest_helper"
require "../../src/krikri/variable_substitutor/expression_evaluator"
require "../../src/krikri/krikri_jinja_lookups"
require "../../src/krikri/krikri_jinja_filters"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook_binary(pb : String) : {Process::Status, String, String}
  playbook = File.tempname("template-lookup-missing", ".yml")
  File.write(playbook, pb)
  out_io = IO::Memory.new
  err_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: out_io, error: err_io)
  {status, out_io.to_s, err_io.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private MISSING = "/nonexistent/krikri-spec-missing-template.j2"

# Issue #248: ansible-core 2.19.11 (live-verified) hard-fails a task whose
# args resolve through lookup('template', ...) on a file the search paths
# cannot find, while krikri returned nil/"undefined" and let the caller's
# task run on. template.py raises with the term AS GIVEN wrapped as "The
# lookup plugin 'template' failed: the template file <term> could not be
# found for the lookup", plus find_file_in_search_path's "Unable to find
# '<term>' in expected paths (use -vvvvv to see paths)" warning.
describe "lookup('template', missing file)" do
  it "hard-fails the hand-rolled evaluator with the plugin's own message" do
    v = Hash(String, JSON::Any).new
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    assert_raises_message(Krikri::PythonLookupRunner::LookupError,
      "The lookup plugin 'template' failed: the template file #{MISSING} could not be found for the lookup") do
      evaluator.evaluate("lookup('template', '#{MISSING}')")
    end
  end

  it "keeps the message's term AS GIVEN for a role-relative miss" do
    # template.py's raise uses the raw term, never the role-joined
    # search-path candidate the lookup actually probed (live-verified
    # 2.19.11 inside a role: the message says "missing_rel.yaml", not
    # <role>/templates/missing_rel.yaml).
    role_dir = PluginSpecHelper.tmp_path("template_lookup_missing_role_spec")
    Dir.mkdir_p(File.join(role_dir, "templates"))
    v = Hash(String, JSON::Any).new
    v["role_path"] = JSON::Any.new(role_dir)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
    assert_raises_message(Krikri::PythonLookupRunner::LookupError,
      "The lookup plugin 'template' failed: the template file missing-span-probe.j2 could not be found for the lookup") do
      evaluator.evaluate("lookup('template', 'missing-span-probe.j2')")
    end
  end

  it "hard-fails the krikri-jinja engine path with the same message" do
    # The engine's own dispatcher rides the same typed LookupError the
    # cartesian lookup raises; JinjaRenderer#render re-raises that type
    # instead of falling into its lenient text fallback, so a rendered
    # template body or structured value fails the whole task too.
    renderer = Krikri::VariableSubstitutor::JinjaRenderer.new({} of String => JSON::Any)
    assert_raises_message(Krikri::PythonLookupRunner::LookupError,
      "The lookup plugin 'template' failed: the template file #{MISSING} could not be found for the lookup") do
      renderer.render("{{ lookup('template', '#{MISSING}') }}")
    end
  end

  it "fails a set_fact's arg finalization end to end like ansible" do
    _status, out, _err = run_playbook_binary(<<-YAML
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: S1 set_fact with a missing template lookup
            ansible.builtin.set_fact:
              cfg: "{{ lookup('template', '#{MISSING}') }}"
      YAML
    )
    combined = out + _err
    combined.must_include("Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed: Error while resolving value for 'cfg': The lookup plugin 'template' failed: the template file #{MISSING} could not be found for the lookup")
    combined.must_include("Unable to find '#{MISSING}' in expected paths (use -vvvvv to see paths)")
  end

  it "carries on with an empty result for errors='ignore'" do
    status, out, _err = run_playbook_binary(<<-YAML
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: S1 set_fact survives the missing file
            ansible.builtin.set_fact:
              cfg: "{{ lookup('template', '#{MISSING}', errors='ignore') }}"
          - name: S2 shows the empty result
            ansible.builtin.debug:
              msg: "cfg-{{ cfg | default('NONE') }}"
      YAML
    )
    combined = out + _err
    status.success?.must_equal(true, combined)
    out.must_include("cfg-")
    out.wont_include("cfg-NONE")
    combined.must_include("Unable to find '#{MISSING}' in expected paths (use -vvvvv to see paths)")
  end

  it "warns and carries on for errors='warn'" do
    status, out, _err = run_playbook_binary(<<-YAML
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: S1 set_fact survives the missing file
            ansible.builtin.set_fact:
              cfg: "{{ lookup('template', '#{MISSING}', errors='warn') }}"
          - name: S2 shows the empty result
            ansible.builtin.debug:
              msg: "cfg-{{ cfg | default('NONE') }}"
      YAML
    )
    combined = out + _err
    status.success?.must_equal(true, combined)
    out.must_include("cfg-")
    out.wont_include("cfg-NONE")
    combined.must_include("Unable to find '#{MISSING}' in expected paths (use -vvvvv to see paths)")
    combined.must_include("An error occurred while running the lookup plugin 'template': the template file #{MISSING} could not be found for the lookup")
  end
end
