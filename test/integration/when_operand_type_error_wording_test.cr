require "../minitest_helper"
require "file_utils"

# A `when:` whose evaluation dies on an operand TypeError is worded by the
# part of the condition that failed (issue #1822, inofix.yapkg): a VARIABLE's
# own value that fails to render is a template error real reports as
# "Error rendering template: <msg>" with the caused-by Origin at that
# value's declaration, while the clause's own unbraced expression keeps
# "Error rendering expression: <msg>" at the when: token. The braced `{{ }}`
# form is a template render too, so it gets the template wording (it used
# to escape as an unhandled exception and kill the whole run). All three
# shapes live-verified against ansible-core 2.21.6.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-localhost-local.ini")

private def run_when_playbook(name : String, playbook_body : String) : NamedTuple(text: String, success: Bool, playbook: String)
  root = PluginSpecHelper.tmp_path("when-operand-#{name}")
  playbook = File.join(root, "pb.yml")
  FileUtils.mkdir_p(root)
  File.write(playbook, playbook_body)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook],
    output: output, error: output, input: IO::Memory.new)
  {text: output.to_s, success: status.success?, playbook: playbook}
ensure
  FileUtils.rm_rf(root) if root
end

describe "when: operand-type failure wording" do
  it "words a failing variable value as a template render and pins its declaration" do
    # yapkg_list's shape: a `{% for %}` value that renders to None, so the
    # value reading it fails an operand TypeError when the when: resolves it.
    result = run_when_playbook("var-value", <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        connection: local
        vars:
          failing_list: '{% for p in [] %}{% endfor %}'
          failing_names: '{{ [] | list + failing_list.rstrip(";").split(";") }}'
        tasks:
          - name: guarded
            debug:
              msg: hi
            when:
              - failing_names is iterable
      YAML
    text = result[:text]
    playbook = result[:playbook]
    detail = "A 'when' expression failed: Error rendering template: can only concatenate list (not \"UndefinedMarker\") to list"
    result[:success].must_equal(false)
    text.wont_include("Unhandled exception")
    text.must_include("[ERROR]: Task failed: #{detail}")
    text.must_include("Task failed.\nOrigin: #{playbook}:9:7\n\n7     failing_names: '{{ [] | list + failing_list.rstrip(\";\").split(\";\") }}'\n8   tasks:\n9     - name: guarded\n        ^ column 7")
    # The caused-by Origin is the FAILING VALUE's declaration.
    text.must_include("<<< caused by >>>\n\n#{detail}\nOrigin: #{playbook}:7:20\n\n5   vars:\n6     failing_list: '{% for p in [] %}{% endfor %}'\n7     failing_names: '{{ [] | list + failing_list.rstrip(\";\").split(\";\") }}'\n                     ^ column 20")
    text.wont_include("Error while evaluating conditional")
    # No ALLOW_BROKEN_CONDITIONALS hint for this wording class.
    text.wont_include("Broken conditionals can be temporarily allowed")
    text.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: #{detail.gsub("\"", "\\\"")}\"}")
  end

  it "words a braced operand failure as a template render at the when token" do
    result = run_when_playbook("braced", <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: braced
            debug:
              msg: hi
            when: "{{ [1] + 'x' }}"
      YAML
    text = result[:text]
    playbook = result[:playbook]
    detail = "A 'when' expression failed: Error rendering template: can only concatenate list (not \"str\") to list"
    result[:success].must_equal(false)
    text.wont_include("Unhandled exception")
    text.must_include("[ERROR]: Task failed: #{detail}")
    text.must_include("<<< caused by >>>\n\n#{detail}\nOrigin: #{playbook}:9:13")
    text.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: #{detail.gsub("\"", "\\\"")}\"}")
  end

  it "keeps the expression wording for the clause's own operand failure" do
    result = run_when_playbook("expression", <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: expression
            debug:
              msg: hi
            when: "[1] + 'x'"
      YAML
    text = result[:text]
    playbook = result[:playbook]
    detail = "A 'when' expression failed: Error rendering expression: can only concatenate list (not \"str\") to list"
    result[:success].must_equal(false)
    text.must_include("[ERROR]: Task failed: #{detail}")
    text.must_include("<<< caused by >>>\n\n#{detail}\nOrigin: #{playbook}:9:13")
    text.wont_include("Error rendering template")
  end

  # An `until:` draws the same template-vs-expression line (the clause's own
  # failed variable value is a template render, its own expression is not).
  it "words an until: failing on a variable value as a template render" do
    result = run_when_playbook("until", <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        connection: local
        vars:
          failing: '{{ [1] + "x" }}'
        tasks:
          - name: retried
            debug:
              msg: hi
            register: r
            until: failing is iterable
            retries: 1
            delay: 0
      YAML
    text = result[:text]
    playbook = result[:playbook]
    detail = "An 'until' expression failed: Error rendering template: can only concatenate list (not \"str\") to list"
    result[:success].must_equal(false)
    text.must_include("[ERROR]: Task failed: #{detail}")
    text.must_include("<<< caused by >>>\n\n#{detail}\nOrigin: #{playbook}:6:14")
  end
end
