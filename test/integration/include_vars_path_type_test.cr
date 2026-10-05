require "../minitest_helper"

# Ansible's include_vars action plugin uses
# the `file:`/`dir:` value AS a path in two places, before it ever copies it
# to text: `os.path.join(current_dir, self.source_dir)` for dir: and
# `_find_needle('vars', self.source_file)`'s `source.startswith('~')` for
# file:. A truthy non-string YAML literal therefore crashes the plugin there,
# with the value's Python type name in the message - while a FALSY one
# (0, 0.0, false, "", [], {}, a bare `file:`) is discarded by the plugin's own
# `if not self.source_dir and not self.source_file` check first, leaving the
# plain null-file failure. Both were previously a Crystal cast crash at PARSE
# time (`file: 0` dropped the whole task with a parse warning instead of
# running it). The free-form form (`include_vars: 21`) never becomes
# Ansible's _raw_params at all: mod_args refuses it with a whole-playbook abort.
# Every expectation below was probed against ansible-playbook 2.19.11.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String, files : Hash(String, String) = {} of String => String)
  scratch = PluginSpecHelper.tmp_path("include-vars-path-type")
  FileUtils.mkdir_p(scratch)
  files.each { |name, content| File.write(File.join(scratch, name), content) }
  playbook = File.join(scratch, "play.yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: scratch)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(scratch) if scratch && Dir.exists?(scratch)
end

private def play(task_args : String) : String
  <<-YAML
  - hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - include_vars:
  #{task_args}
        ignore_errors: true
  YAML
end

describe "include_vars with a non-string file:/dir: literal" do
  it "runs a falsy file literal as the null-file failure, never dropping the task" do
    _, output = run_playbook(play("          file: 0"))

    output.wont_include("Skipping task")
    output.must_include(%([WARNING]: Invalid request to find a file that matches a "null" value))
    output.must_include("[ERROR]: Task failed: Action failed: Unknown error.")
    output.must_include(%("message": "Could not find file on the Ansible Controller.))
    output.must_match(/ignored=1/)
  end

  it "crashes a truthy non-string file literal in _find_needle, with its Python type name" do
    _, output = run_playbook(play("          file: 21"))

    output.must_include("[ERROR]: Task failed: '_AnsibleTaggedInt' object has no attribute 'startswith'")
    output.must_include(%("msg": "Task failed: '_AnsibleTaggedInt' object has no attribute 'startswith'"))
    output.wont_include("Invalid request to find a file")
    output.must_match(/ignored=1/)
  end

  it "prints plain bool for a true file literal and the tagged names for the containers" do
    _, bools = run_playbook(play("          file: true"))
    bools.must_include("[ERROR]: Task failed: 'bool' object has no attribute 'startswith'")

    _, lists = run_playbook(play("          file: [a]"))
    lists.must_include("[ERROR]: Task failed: '_AnsibleTaggedList' object has no attribute 'startswith'")

    _, dicts = run_playbook(play("          file: {a: 1}"))
    dicts.must_include("[ERROR]: Task failed: '_AnsibleTaggedDict' object has no attribute 'startswith'")

    _, floats = run_playbook(play("          file: 1.5"))
    floats.must_include("[ERROR]: Task failed: '_AnsibleTaggedFloat' object has no attribute 'startswith'")
  end

  it "crashes a truthy non-string dir literal in os.path.join instead" do
    _, output = run_playbook(play("          dir: 21"))

    output.must_include("[ERROR]: Task failed: join() argument must be str, bytes, or os.PathLike object, not '_AnsibleTaggedInt'")
    output.wont_include("Invalid request to find a file")
  end

  it "discards a falsy dir literal into the same null-file failure a file literal gets" do
    _, output = run_playbook(play("          dir: false"))

    output.must_include(%([WARNING]: Invalid request to find a file that matches a "null" value))
    output.must_include("[ERROR]: Task failed: Action failed: Unknown error.")
  end

  it "reports the invalid-option and mixing errors before any type crash" do
    _, mixed = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - include_vars:
              file: 21
              depth: 3
            ignore_errors: true
    YAML
    mixed.must_include("[ERROR]: Task failed: You are mixing file only and dir only arguments")

    _, invalid = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - include_vars:
              file: 21
              files_macthing: "*.yml"
            ignore_errors: true
    YAML
    invalid.must_include("[ERROR]: Task failed: files_macthing is not a valid option in include_vars")
  end

  it "aborts the whole playbook on a non-string free-form value, like Ansible's mod_args" do
    _, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - include_vars: 21
    YAML

    output.must_include("[ERROR]: unexpected parameter type in action: <class 'ansible.module_utils._internal._datatag._AnsibleTaggedInt'>")
    output.wont_include("PLAY [")
  end

  it "still accepts the ordinary string file form" do
    _, output = run_playbook(
      <<-YAML,
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - include_vars: {file: good.yml}
          - debug: {msg: "{{ aa }}"}
      YAML
      {"good.yml" => "aa: 1\n"}
    )

    output.must_include(%("msg": 1))
  end
end
