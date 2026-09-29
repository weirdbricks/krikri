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

describe "non-string YAML literal module args (script/unarchive/assemble)" do
  it "script searches for (and reports missing) the Python str() of a non-string cmd" do
    output, _scratch = run_playbook(<<-YAML)
          - script:
              cmd: 75
              executable: /bin/sh
            ignore_errors: true
          - script:
              cmd: true
            ignore_errors: true
          - script:
              cmd: 7.5
            ignore_errors: true
    YAML

    # live-verified vs 2.19.11: the searched-in list carries the same
    # text, twice per root (files/ then the root itself)
    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Could not find or access '75'\\nSearched in:))
    output.must_include("Could not find or access '75'\nSearched in:\n\t")
    output.must_include("files/75")
    output.must_include("Could not find or access 'True'")
    output.must_include("Could not find or access '7.5'")
    # The internal marker must never leak into any message or path.
    output.to_s.wont_include("\u{E000}")
  end

  it "unarchive crashes on a non-string dest/src/creates at the action plugin's own touch points" do
    output, _scratch = run_playbook(<<-YAML)
          - unarchive:
              dest: 59
              remote_src: "true"
              src: #{__DIR__}/../minitest_helper.cr
            ignore_errors: true
          - unarchive:
              dest: true
              remote_src: "true"
              src: #{__DIR__}/../minitest_helper.cr
            ignore_errors: true
          - unarchive:
              dest: 7.5
              remote_src: "true"
              src: #{__DIR__}/../minitest_helper.cr
            ignore_errors: true
          - unarchive:
              dest: /tmp
              src: 75
            ignore_errors: true
          - unarchive:
              creates: 7
              dest: /tmp
              src: #{__DIR__}/../minitest_helper.cr
            ignore_errors: true
    YAML

    output.must_include(%("msg": "Task failed: '_AnsibleTaggedInt' object has no attribute 'startswith'"))
    output.must_include(%("msg": "Task failed: 'bool' object has no attribute 'startswith'"))
    output.must_include(%("msg": "Task failed: '_AnsibleTaggedFloat' object has no attribute 'startswith'"))
    output.must_include(%("msg": "Task failed: expected str, bytes or os.PathLike object, not _AnsibleTaggedInt"))
    output.to_s.wont_include("\u{E000}")
  end

  it "assemble crashes like real's atomic_move on a dest real cannot move onto" do
    scratch = PluginSpecHelper.tmp_path("nonstring-assemble-cwd")
    FileUtils.mkdir_p(File.join(scratch, "frags"))
    File.write(File.join(scratch, "frags", "01-a.txt"), "frag one\n")
    playbook = File.join(scratch, "play.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          # bare relative dest: real's rename creates the file, then the
          # creating-branch os.stat(b'') crashes the module
          - assemble:
              dest: 75
              src: #{scratch}/frags
            ignore_errors: true
          - assemble:
              dest: relmissing.txt
              src: #{scratch}/frags
            ignore_errors: true
          # missing parent dir: the rename itself fails ENOENT
          - assemble:
              dest: #{scratch}/nodir/out.txt
              src: #{scratch}/frags
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: scratch)

    output.to_s.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Module failed: [Errno 2] No such file or directory: b''"}))
    output.to_s.must_include("[ERROR]: Task failed: Module failed: [Errno 2] No such file or directory: b''")
    output.to_s.must_include("Module failed: Could not replace '#{scratch}/nodir/out.txt' with '")
    # the bare-relative dest file IS created before the crash, in both engines
    File.read(File.join(scratch, "75")).must_equal("frag one\n")
    File.read(File.join(scratch, "relmissing.txt")).must_equal("frag one\n")
    File.exists?(File.join(scratch, "nodir", "out.txt")).must_equal(false)
  end

  it "assemble with remote_src false validates through copy's spec, like real's delegation" do
    scratch = PluginSpecHelper.tmp_path("nonstring-assemble-copy-cwd")
    FileUtils.mkdir_p(File.join(scratch, "frags"))
    File.write(File.join(scratch, "frags", "01-a.txt"), "frag one\n")
    playbook = File.join(scratch, "play.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - assemble:
              backup: true
              dest: #{scratch}/out2.txt
              mode: "0600"
              regexp: \\.txt$
              remote_src: "false"
              src: #{scratch}/frags
              ignoer_hidden: false
              mode_bogus: "0600"
            ignore_errors: true
          # the default remote_src keeps validating through assemble's own spec
          - assemble:
              dest: #{scratch}/out3.txt
              src: #{scratch}/frags
              ignoer_hidden: false
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: scratch)

    output.to_s.must_include(%(Unsupported parameters for (ansible.legacy.copy) module: ignoer_hidden, mode_bogus. Supported parameters include: _original_basename, attributes, backup, checksum, content, dest, directory_mode, follow, force, group, local_follow, mode, owner, remote_src, selevel, serole, setype, seuser, src, unsafe_writes, validate (attr).))
    output.to_s.must_include(%(Unsupported parameters for (ansible.legacy.assemble) module: ignoer_hidden. ))
  end
end

describe "copy argspec-failure checksum (template carries it, copy only on the _copy_file path)" do
  it "omits checksum for a remote_src copy failure, carries it for content/controller-src ones" do
    output, _scratch = run_playbook(<<-YAML)
          - copy:
              dest: /tmp/krikri-spec-c1.txt
              remote_src: true
              src: #{__DIR__}/../minitest_helper.cr
              validate_bogus: x
            ignore_errors: true
          - copy:
              content: hello
              dest: /tmp/krikri-spec-c2.txt
              validate_bogus: x
            ignore_errors: true
          - copy:
              dest: /tmp/krikri-spec-c3.txt
              src: #{__DIR__}/../minitest_helper.cr
              validate_bogus: x
            ignore_errors: true
    YAML

    text = output.to_s
    # content/controller-src: the _copy_file tail adds the source SHA1 to
    # the failed result; the remote_src branch returns the module result
    # directly and never adds one (copy.py:466-468, live-verified vs
    # 2.19.11)
    text.scan(%("checksum": "#{Digest::SHA1.hexdigest("hello")}")).size.must_equal(1)
    text.scan(%("checksum": "#{Digest::SHA1.hexdigest(File.read("#{__DIR__}/../minitest_helper.cr"))}")).size.must_equal(1)
    # exactly one of the three fatal dumps carries NO checksum key
    text.scan(%(FAILED! => {"changed": false, "msg": "Unsupported parameters)).size.must_equal(1)
  end
end

describe "non-string YAML literal module args (group_by/add_host)" do
  # group_by's action crashes while building its result dict
  # (`group_name.replace(' ', '-')` for key, the parents comprehension
  # for a non-list parents) and add_host's crash points straddle two
  # stages - the action's "Groups must be specified as a list."
  # AnsibleActionFail (with the failing param value's own Origin in the
  # [ERROR] block) and the executor's inventory.add_host name checks,
  # which abort the WHOLE run with a bare stderr [ERROR] line, rc 1 and
  # no recap. Every expectation below was probed against real
  # ansible-playbook 2.19.11.
  it "group_by crashes on int/bool/float key like real's group_name.replace" do
    output, _scratch = run_playbook(<<-YAML)
          - group_by:
              key: 19
            ignore_errors: true
          - group_by:
              key: true
            ignore_errors: true
          - group_by:
              key: 1.5
            ignore_errors: true
          - group_by:
              key: "text key"
            ignore_errors: true
    YAML

    output.must_include(%("msg": "Task failed: '_AnsibleTaggedInt' object has no attribute 'replace'"))
    output.must_include(%("msg": "Task failed: 'bool' object has no attribute 'replace'"))
    output.must_include(%("msg": "Task failed: '_AnsibleTaggedFloat' object has no attribute 'replace'"))
    output.must_include(%("msg": "Task failed: '_AnsibleTaggedInt' object has no attribute 'replace'"))
  end

  it "group_by crashes on a non-list parents like real's comprehension iteration" do
    output, _scratch = run_playbook(<<-YAML)
          - group_by:
              key: abc
              parents: 7
            ignore_errors: true
          - group_by:
              key: abc
              parents: false
            ignore_errors: true
    YAML

    output.must_include(%("msg": "Task failed: '_AnsibleTaggedInt' object is not iterable"))
    output.must_include(%("msg": "Task failed: 'bool' object is not iterable"))
  end

  it "add_host fails a truthy non-string groups with real's AnsibleActionFail block" do
    output, _scratch = run_playbook(<<-YAML)
          - add_host:
              name: h1
              groups: 5
            ignore_errors: true
    YAML

    output.must_include("[ERROR]: Task failed: Groups must be specified as a list.")
    output.must_include("<<< caused by >>>")
    output.must_include(%("msg": "Groups must be specified as a list."))
    output.wont_include(%("msg": "Task failed: Groups must be specified as a list."))
    output.must_include("Origin:")
  end

  it "add_host aborts the run on a non-string name like real's inventory.add_host" do
    output, _scratch = run_playbook(<<-YAML)
          - add_host:
              name: 5
            ignore_errors: true
          - debug:
              msg: never reached
    YAML

    output.must_include("[ERROR]: Invalid host name supplied, expected a string but got <class 'ansible.module_utils._internal._datatag._AnsibleTaggedInt'> for 5")
    output.wont_include("never reached")
    output.wont_include("PLAY RECAP")
  end

  it "add_host aborts the run on a falsy non-string name like real's empty-host check" do
    output, _scratch = run_playbook(<<-YAML)
          - add_host:
              name: 0
            ignore_errors: true
    YAML

    output.must_include("[ERROR]: Invalid empty host name provided: 0")
    output.wont_include("PLAY RECAP")
  end
end
