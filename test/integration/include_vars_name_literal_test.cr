require "../minitest_helper"

# Real include_vars.py's `scope[self.return_results_as_name] = results`
# runs whenever the `name:` value is Python-truthy, regardless of the load
# outcome - so a non-string YAML literal name wraps the facts under its
# stringified key both on success and on the file-not-found failure, a
# falsy one (0/false/""/null/[]/{}) skips the wrap entirely, and a truthy
# unhashable one (list/dict) crashes the action at the dict-key assignment
# ("unhashable type: '_AnsibleTaggedList'/'_AnsibleTaggedDict'"),
# superseding every file error. Every expectation below was probed against
# ansible-playbook 2.19.11 (see the include_vars_name_shape comment in
# executor_blocks_includes.cr). The non-string name value rides the
# parser's NON_STRING_PARAM_PREFIX marker (see parse_include_vars_task).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String, vars_files : Hash(String, String) = {} of String => String)
  scratch = PluginSpecHelper.tmp_path("include-vars-name-literal")
  FileUtils.mkdir_p(scratch)
  vars_files.each { |name, content| File.write(File.join(scratch, name), content) }
  playbook = File.join(scratch, "play.yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: scratch)
  {status, output.to_s, scratch}
ensure
  FileUtils.rm_rf(scratch) if scratch && Dir.exists?(scratch)
end

describe "include_vars with a non-string name: literal" do
  it "wraps the failure facts under the stringified int name, like Ansible's scope assignment" do
    _, output, _scratch = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - include_vars:
              depth: 88
              files_matching: 54
              hash_behaviour: 5
              name: 27
            ignore_errors: true
      YAML

    output.must_include(%("ansible_facts": {"27": {}}))
    output.must_include(%("ansible_included_var_files": []))
    output.must_match(/ignored=1/)
  end

  it "keeps a truthy non-string name out of the string-keyed variable store, like Ansible's native key" do
    _, output, _scratch = run_playbook(
      <<-YAML,
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - include_vars: {file: good.yml, name: 27}
          - include_vars: {file: good.yml, name: true}
          - include_vars: {file: good.yml, name: 27.5}
          - debug: {msg: "{{ lookup('vars', '27', default='UNDEF') }}/{{ lookup('vars', 'true', default='UNDEF') }}/{{ lookup('vars', 'aa', default='UNDEF') }}"}
      YAML
      {"good.yml" => "aa: 1\n"}
    )

    # Real stores the facts under the NATIVE int/bool key, unreachable
    # through every string-keyed lookup (live-verified vs 2.19.11:
    # lookup('vars', '27') is undefined), and does NOT merge the file's
    # own keys either.
    output.must_include("UNDEF/UNDEF/UNDEF")
    output.must_match(/ok=4\b/)
  end

  it "skips the wrap for falsy name literals, like Ansible's truthiness check" do
    _, output, _scratch = run_playbook(
      <<-YAML,
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - include_vars: {file: good.yml, name: 0}
          - include_vars: {file: good.yml, name: ""}
          - include_vars: {file: good.yml, name: []}
          - debug: {msg: "{{ lookup('vars', 'aa', default='UNDEF') }}"}
          - include_vars: {file: missing.yml, name: false}
            ignore_errors: true
      YAML
      {"good.yml" => "aa: 1\n"}
    )

    # Falsy names spread the file's own keys (real: `if self.
    # return_results_as_name:` skips the wrap), and a falsy name on a
    # MISSING file still reports the bare empty ansible_facts.
    output.must_include(%("msg": 1))
    output.must_include(%("ansible_facts": {}))
    output.must_match(/ignored=1/)
  end

  it "crashes on a truthy unhashable name like Ansible's dict-key assignment" do
    _, output, _scratch = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - include_vars: {name: [a, b]}
            ignore_errors: true
          - include_vars: {name: {k: v}}
            ignore_errors: true
          - include_vars: {file: good.yml, name: [a, b]}
            ignore_errors: true
      YAML

    # The crash supersedes the null-file failure (first two tasks) and the
    # missing-file one (third), and the fatal msg carries the "Task failed: "
    # prefix (a raised TypeError, not an action result).
    output.must_include(%("msg": "Task failed: unhashable type: '_AnsibleTaggedList'"))
    output.must_include(%("msg": "Task failed: unhashable type: '_AnsibleTaggedDict'"))
    output.must_include("[ERROR]: Task failed: unhashable type: '_AnsibleTaggedList'")
    output.must_match(/ignored=3/)
  end
end
