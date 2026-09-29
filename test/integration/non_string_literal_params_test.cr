require "../minitest_helper"

# Runs the compiled binary against real playbooks: the non-string-YAML-
# literal crash/type-check behavior lives in executor-side hooks and the
# plugin wire (parser marker -> BasePlugin demotion), which no unit spec
# can reach without a live TaskExecutor run. Every expectation below was
# probed against real ansible-playbook 2.19.11 (privileged container,
# dest/src x int/bool/float matrix for copy/fetch/template) - see
# NON_STRING_PARAM_PREFIX's comment in param_sentinels.cr.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# The runner chdirs into a per-test scratch dir: real's bool/int dest
# literals resolve as paths relative to the CWD, and the whole point of
# the crash paths is that NOTHING gets written there.
private def run_playbook(tasks : String) : {String, String}
  scratch = PluginSpecHelper.tmp_path("nonstring-literal-cwd")
  FileUtils.mkdir_p(scratch)
  playbook = File.join(scratch, "play.yml")
  File.write(playbook, "- hosts: localhost\n  connection: local\n  gather_facts: false\n  tasks:\n" + tasks)
  output = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: scratch)
  {output.to_s, scratch}
end

describe "non-string YAML literal module args (copy/fetch/template)" do
  it "copy crashes on a truthy non-string dest like real's _remote_expand_user" do
    output, scratch = run_playbook(<<-YAML)
          - copy:
              dest: 89
              src: #{__DIR__}/../minitest_helper.cr
            ignore_errors: true
          - copy:
              dest: true
              src: #{__DIR__}/../minitest_helper.cr
            ignore_errors: true
          - copy:
              dest: 1.5
              src: #{__DIR__}/../minitest_helper.cr
            ignore_errors: true
    YAML

    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: '_AnsibleTaggedInt' object has no attribute 'startswith'"}))
    output.must_include("[ERROR]: Task failed: '_AnsibleTaggedInt' object has no attribute 'startswith'")
    output.must_include(%("msg": "Task failed: 'bool' object has no attribute 'startswith'"))
    output.must_include(%("msg": "Task failed: '_AnsibleTaggedFloat' object has no attribute 'startswith'"))
    Dir.children(scratch).reject { |file| file == "play.yml" }.must_equal([] of String)
  end

  it "copy crashes on a non-string src before the dest check, like real's find_needle path" do
    output, _scratch = run_playbook(<<-YAML)
          - copy:
              dest: out-int
              src: 89
            ignore_errors: true
          - copy:
              dest: out-bool
              src: true
            ignore_errors: true
    YAML

    output.must_include(%("msg": "Task failed: '_AnsibleTaggedInt' object has no attribute 'endswith'"))
    output.must_include(%("msg": "Task failed: 'bool' object has no attribute 'endswith'"))
  end

  it "copy crashes on content + non-string dest at the elif chain's endswith" do
    output, _scratch = run_playbook(<<-YAML)
          - copy:
              content: hello
              dest: 89
            ignore_errors: true
    YAML

    output.must_include(%("msg": "Task failed: '_AnsibleTaggedInt' object has no attribute 'endswith'"))
  end

  it "copy treats falsy non-string literals as not provided, like real's truthiness checks" do
    output, scratch = run_playbook(<<-YAML)
          - copy:
              dest: false
              src: #{__DIR__}/../minitest_helper.cr
            ignore_errors: true
          - copy:
              dest: 0
              content: hi
            ignore_errors: true
          - copy:
              dest: out-falsy-src
              src: 0
            ignore_errors: true
          - copy:
              content: from-zero-src
              dest: out-falsy-src-content
              src: 0
    YAML

    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "dest is required"}))
    output.must_include("[ERROR]: Task failed: Action failed: dest is required")
    output.must_include(%("msg": "src (or content) is required"))
    # src: 0 with content: the falsy src is ignored, the content path runs
    File.read(File.join(scratch, "out-falsy-src-content")).must_equal("from-zero-src")
  end

  it "fetch fails a non-string dest/src with real's action-level message" do
    output, _scratch = run_playbook(<<-YAML)
          - fetch:
              dest: 89
              src: #{__DIR__}/../minitest_helper.cr
            ignore_errors: true
          - fetch:
              dest: true
              src: #{__DIR__}/../minitest_helper.cr
            ignore_errors: true
          - fetch:
              dest: fetch-out
              src: 1.5
            ignore_errors: true
          - fetch:
              dest: 89
              src: 42
            ignore_errors: true
    YAML

    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Invalid type supplied for dest option, it must be a string"}))
    output.must_include("[ERROR]: Task failed: Invalid type supplied for dest option, it must be a string")
    output.must_include(%("msg": "Invalid type supplied for source option, it must be a string"))
    # dest's message overwrites src's when both are non-string (three
    # tasks carry a non-string dest; the [ERROR] blocks repeat the text)
    output.scan("FAILED! => {\"changed\": false, \"msg\": \"Invalid type supplied for dest option").size.must_equal(3)
  end

  it "template coerces a non-string literal dest through Python str()" do
    scratch = PluginSpecHelper.tmp_path("nonstring-template-cwd")
    FileUtils.mkdir_p(scratch)
    template = File.join(scratch, "t.j2")
    File.write(template, "x{{ 1 + 1 }}\n")
    playbook = File.join(scratch, "play.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - template:
              dest: true
              src: #{template}
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: scratch)

    output.to_s.must_include("changed: [localhost]")
    # dest: true writes "True" (Python str), not YAML's "true"
    File.exists?(File.join(scratch, "True")).must_equal(true)
  end
end
