require "digest/sha1"
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

  # Real's copy.py hands the whole task to the copy MODULE the moment
  # remote_src is truthy (the `elif remote_src:` branch), so the
  # controller-side path is never walked: the module's own argspec
  # validation is the first thing to look at the non-string dest, and a
  # dest that survives it is coerced by the module's `type: path` spec.
  # Live-verified vs 2.19.11: with remote_src the same `dest: 89` that
  # crashes without it reports the bool error instead, and with no other
  # error at all it writes the file named "89".
  it "copy's remote_src branch hands a non-string dest to the module, which validates and coerces it" do
    output, scratch = run_playbook(<<-YAML)
          - copy:
              dest: 89
              remote_src: true
              src: #{__DIR__}/../minitest_helper.cr
              backup: notabool
            ignore_errors: true
          - copy:
              dest: 89
              remote_src: true
              src: #{__DIR__}/../minitest_helper.cr
              typo_destinatoin: x
            ignore_errors: true
          - copy:
              dest: 89
              remote_src: "false"
              src: #{__DIR__}/../minitest_helper.cr
              backup: notabool
            ignore_errors: true
          - copy:
              dest: 89
              remote_src: true
              src: #{__DIR__}/../minitest_helper.cr
    YAML

    # remote_src: the module's own spec reports first - the bool error,
    # the unsupported-parameter error, neither wrapped in the action
    # plugin's "Task failed:" crash chain
    output.must_include(%("msg": "argument 'backup' is of type str and we were unable to convert to bool: The value 'notabool' is not a valid boolean.))
    output.must_include(%(Unsupported parameters for (ansible.legacy.copy) module: typo_destinatoin.))
    # ... and a dest that survives both is used as the str() text, not
    # as a path object
    File.exists?(File.join(scratch, "89")).must_equal(true)
    File.read(File.join(scratch, "89")).must_equal(File.read("#{__DIR__}/../minitest_helper.cr"))
    # remote_src spelled falsy keeps the controller-side crash, which is
    # reported ahead of the module's spec (so the bool error still comes
    # from the remote_src: true task alone - one of each)
    output.must_include(%("msg": "Task failed: '_AnsibleTaggedInt' object has no attribute 'startswith'"))
    # one task, two occurrences ([ERROR] line + fatal dump)
    output.scan("argument 'backup' is of type str and we were unable to convert to bool").size.must_equal(2)
    output.to_s.wont_include("\u{E000}")
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

describe "non-string YAML literal list MEMBERS (group_by/add_host)" do
  it "group_by crashes on the first non-string parents member like real's replace comprehension" do
    output, _scratch = run_playbook(<<-YAML)
          - group_by:
              key: g1
              parents: [a, 7]
            ignore_errors: true
          - group_by:
              key: g2
              parents: [a, true]
            ignore_errors: true
          - group_by:
              key: g3
              parents: [a, 1.5]
            ignore_errors: true
          - group_by:
              key: g4
              parents: [a, null]
            ignore_errors: true
          - group_by:
              key: g5
              parents: [{a: b}]
            ignore_errors: true
          - group_by:
              key: g6
              parents: [a, [b]]
            ignore_errors: true
          - group_by:
              key: g7
              parents: [7, g9]
            ignore_errors: true
    YAML

    output.must_include(%("msg": "Task failed: '_AnsibleTaggedInt' object has no attribute 'replace'"))
    output.must_include(%("msg": "Task failed: 'bool' object has no attribute 'replace'"))
    output.must_include(%("msg": "Task failed: '_AnsibleTaggedFloat' object has no attribute 'replace'"))
    output.must_include(%("msg": "Task failed: 'NoneType' object has no attribute 'replace'"))
    output.must_include(%("msg": "Task failed: '_AnsibleTaggedDict' object has no attribute 'replace'"))
    output.must_include(%("msg": "Task failed: '_AnsibleTaggedList' object has no attribute 'replace'"))
    # The FIRST member crashes when it is itself non-string (list order).
    output.scan(/'_AnsibleTaggedInt' object has no attribute 'replace'/).size.must_equal(4)
  end

  it "add_host crashes on the first non-string groups member like real's strip loop" do
    output, _scratch = run_playbook(<<-YAML)
          - add_host:
              name: h1
              groups: [g1, 7]
            ignore_errors: true
          - add_host:
              name: h2
              groups: [g1, true]
            ignore_errors: true
          - add_host:
              name: h3
              groups: [{a: b}]
            ignore_errors: true
          - add_host:
              name: h4
              groups: [[x]]
            ignore_errors: true
          - add_host:
              name: h5
              groups: [7, g9]
            ignore_errors: true
    YAML

    output.must_include(%("msg": "Task failed: '_AnsibleTaggedInt' object has no attribute 'strip'"))
    output.must_include(%("msg": "Task failed: 'bool' object has no attribute 'strip'"))
    output.must_include(%("msg": "Task failed: '_AnsibleTaggedDict' object has no attribute 'strip'"))
    output.must_include(%("msg": "Task failed: '_AnsibleTaggedList' object has no attribute 'strip'"))
    output.scan(/'_AnsibleTaggedInt' object has no attribute 'strip'/).size.must_equal(4)
  end
end

describe "add_host name-chain failure shapes (missing/null/empty name)" do
  it "fails a missing name with real's action-level AnsibleActionFail" do
    output, _scratch = run_playbook(<<-YAML)
          - add_host:
              naem: eigrxz
              groups: [ilmuwy, zrdsgj]
            ignore_errors: true
          - debug:
              msg: still here
    YAML

    output.must_include("[ERROR]: Task failed: name, host or hostname needs to be provided")
    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "name, host or hostname needs to be provided"}))
    output.wont_include("Module failed")
    output.must_include("still here")
    output.must_match(/ignored=1/)
  end

  it "fails a name present as null before the hostname fallback, like real's args.get chain" do
    output, _scratch = run_playbook(<<-YAML)
          - add_host:
              name: null
            ignore_errors: true
          - add_host:
              name: null
              hostname: web2
            ignore_errors: true
    YAML

    # A PRESENT name key wins real's args.get('name', ...) even when its
    # value is None - the hostname fallback is never consulted
    # (live-verified vs 2.19.11).
    output.scan(/name, host or hostname needs to be provided/).size.must_equal(4)
    output.must_match(/ignored=2/)
  end

  it "aborts the run on an empty-string name like real's inventory empty-host check" do
    output, _scratch = run_playbook(<<-YAML)
          - add_host:
              name: ""
            ignore_errors: true
          - debug:
              msg: never reached
    YAML

    # Byte-exact vs 2.19.11: the bare colon carries NO trailing space when
    # the name is the empty string (a falsy non-None literal like `name:
    # false` renders "Invalid empty host name provided: False").
    output.must_include("[ERROR]: Invalid empty host name provided:")
    output.wont_include("Invalid empty host name provided: ")
    output.wont_include("never reached")
    output.wont_include("PLAY RECAP")
  end
end

describe "fail msg keeps its native type (real's action puts the raw arg in result['msg'])" do
  it "fails with an int/float/bool msg natively, in the fatal dump, the block and the registered var" do
    output, _scratch = run_playbook(<<-YAML)
          - fail:
              msg: 50
            register: r_int
            ignore_errors: true
          - fail:
              msg: 1.5
            ignore_errors: true
          - fail:
              msg: true
            ignore_errors: true
          - fail:
              msg: false
            ignore_errors: true
          - fail:
              msg: 0
            ignore_errors: true
          - debug:
              var: r_int.msg
    YAML

    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": 50}))
    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": 1.5}))
    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": true}))
    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": false}))
    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": 0}))
    output.must_include("[ERROR]: Task failed: Action failed: 50")
    output.must_include("[ERROR]: Task failed: Action failed: 1.5")
    output.must_include("[ERROR]: Task failed: Action failed: True")
    output.must_include("[ERROR]: Task failed: Action failed: False")
    output.must_include("[ERROR]: Task failed: Action failed: 0")
    # the registered var carries the native int, exactly like real's debug
    output.must_include(%("r_int.msg": 50))
  end

  it "keeps an explicit null / empty-string msg, and containers natively" do
    output, _scratch = run_playbook(<<-YAML)
          - fail:
              msg:
            ignore_errors: true
          - fail:
              msg: ""
            ignore_errors: true
          - fail:
              msg: [1, 'a']
            ignore_errors: true
          - fail:
              msg: {'a': 1}
            ignore_errors: true
    YAML

    # `msg:` with no value is args.get's explicit None - NOT the default
    # message, which only applies when the key is absent entirely
    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": null}))
    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": ""}))
    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": [1, "a"]}))
    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": {"a": 1}}))
    output.must_include("[ERROR]: Task failed: Action failed: None")
    # the empty string renders the bare "Action failed." block like real
    output.must_include("[ERROR]: Task failed: Action failed.")
    output.must_include("[ERROR]: Task failed: Action failed: [1, 'a']")
    output.must_include("[ERROR]: Task failed: Action failed: {'a': 1}")
  end

  it "keeps the default message when msg is absent entirely" do
    output, _scratch = run_playbook(<<-YAML)
          - fail:
            ignore_errors: true
    YAML

    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Failed as requested from task"}))
    output.must_include("[ERROR]: Task failed: Action failed: Failed as requested from task")
  end
end

describe "assemble's action-branch remote_src semantics (boolean(strict=False), not a falsy-spelling list)" do
  it "delegates an invalid/None/non-1 remote_src to copy's spec, like real's action plugin" do
    scratch = PluginSpecHelper.tmp_path("nonstring-assemble-delegate-cwd")
    FileUtils.mkdir_p(File.join(scratch, "frags"))
    File.write(File.join(scratch, "frags", "01-a.txt"), "frag one\n")
    File.write(File.join(scratch, "frags", "02-b.txt"), "frag two\n")
    playbook = File.join(scratch, "play.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          # an invalid spelling boolean(strict=False) answers False for:
          # the action assembles locally and copy's spec (remote_src
          # STRIPPED) rejects the typo - the assemble module, and its
          # strict remote_src bool conversion with it, never runs
          - assemble:
              dest: #{scratch}/o1.cfg
              remote_src: timjjr
              src: #{scratch}/frags
              gorup: root
            ignore_errors: true
          # the same invalid spelling with NO typo succeeds - the file
          # gets assembled and placed by the copy module
          - assemble:
              dest: #{scratch}/o2.cfg
              remote_src: timjjr
              src: #{scratch}/frags
            ignore_errors: true
          # an explicit None and a non-1 native int answer False too
          - assemble:
              dest: #{scratch}/o3.cfg
              remote_src:
              src: #{scratch}/frags
              gorup: root
            ignore_errors: true
          - assemble:
              dest: #{scratch}/o4.cfg
              remote_src: 2
              src: #{scratch}/frags
              gorup: root
            ignore_errors: true
          # a BOOLEANS_TRUE value takes the module branch instead, where
          # assemble's own spec names (ansible.legacy.assemble)
          - assemble:
              dest: #{scratch}/o5.cfg
              remote_src: true
              src: #{scratch}/frags
              gorup: root
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: scratch)

    # each of the three failures carries the message twice: the [ERROR]
    # block and the fatal dump
    output.to_s.scan(/Unsupported parameters for \(ansible\.legacy\.copy\) module: gorup\. Supported parameters include: _original_basename/).size.must_equal(6)
    output.to_s.must_include(%(Unsupported parameters for (ansible.legacy.assemble) module: gorup. ))
    # the typo-free invalid-remote_src task assembled and placed the file
    output.to_s.must_include("changed: [localhost]")
    File.read(File.join(scratch, "o2.cfg")).must_equal("frag one\nfrag two\n")
    output.to_s.wont_include("unable to convert to bool")
  end

  it "crashes on a truthy non-string delimiter/regexp at the action's own touch points" do
    scratch = PluginSpecHelper.tmp_path("nonstring-assemble-delimiter-cwd")
    FileUtils.mkdir_p(File.join(scratch, "frags"))
    File.write(File.join(scratch, "frags", "01-a.txt"), "frag one\n")
    File.write(File.join(scratch, "frags", "02-b.txt"), "frag two\n")
    playbook = File.join(scratch, "play.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - assemble:
              delimiter: 50
              dest: #{scratch}/o1.cfg
              remote_src: false
              src: #{scratch}/frags
            ignore_errors: true
          - assemble:
              dest: #{scratch}/o2.cfg
              regexp: true
              remote_src: false
              src: #{scratch}/frags
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: scratch)

    # codecs.escape_decode(50) inside the fragment loop - only once a
    # SECOND fragment is reached, and after the re.compile(regexp) call
    output.to_s.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: a bytes-like object is required, not '_AnsibleTaggedInt'"}))
    output.to_s.must_include("[ERROR]: Task failed: a bytes-like object is required, not '_AnsibleTaggedInt'")
    output.to_s.must_include(%("msg": "Task failed: first argument must be string or compiled pattern"))
    File.exists?(File.join(scratch, "o1.cfg")).must_equal(false)
    File.exists?(File.join(scratch, "o2.cfg")).must_equal(false)
    output.to_s.wont_include("\u{E000}")
  end

  it "fails a missing delegated src with real's _find_needle text, before the isdir check" do
    output, _scratch = run_playbook(<<-YAML)
          - assemble:
              dest: /tmp/krikri-nonstring-assemble-missing.cfg
              remote_src: false
              src: /nonexistent-krikri-assemble-src
            ignore_errors: true
    YAML

    output.must_include(%("msg": "Task failed: Could not find or access '/nonexistent-krikri-assemble-src' on the Ansible Controller.\\nIf you are using a module and expect the file to exist on the remote, see the remote_src option"))
    output.must_include("[ERROR]: Task failed: Could not find or access '/nonexistent-krikri-assemble-src' on the Ansible Controller.")
    output.wont_include("is not a directory")
  end
end

# debconf's `value:` is its module's only `type: raw` option, so an int
# literal reaches real's `' '.join([pkg, question, vtype, value])`
# (debconf.py:179) as itself and kills the module - probed against real
# ansible-playbook 2.19.11, whose console rendering of that uncaught
# exception is what the two must_include's below pin down. The debconf
# binaries are PATH-shimmed through the task's own `environment:` so
# nothing here touches the real debconf database (and the crash means
# nothing is ever seeded).
describe "non-string YAML literal module args (debconf value)" do
  it "debconf fails with real's uncaught ' '.join TypeError for an int value" do
    scratch = PluginSpecHelper.tmp_path("nonstring-debconf-cwd")
    shim = File.join(scratch, "shim")
    log = File.join(scratch, "set-selections.log")
    FileUtils.mkdir_p(shim)
    File.write(File.join(shim, "debconf-show"), "#!/bin/sh\nexit 0\n")
    File.write(File.join(shim, "debconf-set-selections"), "#!/bin/sh\ncat >> \"#{log}\"\n")
    File.write(File.join(shim, "debconf-get-selections"), "#!/bin/sh\nexit 0\n")
    %w[debconf-show debconf-set-selections debconf-get-selections].each do |bin|
      File.chmod(File.join(shim, bin), 0o755)
    end
    playbook = File.join(scratch, "play.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - debconf:
              name: kpgpkg
              question: 16
              value: 76
              vtype: text
            environment:
              PATH: "#{shim}:/usr/bin:/bin"
            ignore_errors: true
    YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: scratch)

    output.to_s.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Module failed: sequence item 3: expected str instance, int found"}))
    output.to_s.must_include("[ERROR]: Task failed: Module failed: sequence item 3: expected str instance, int found")
    output.to_s.wont_include("\u{E000}")
    File.exists?(log).must_equal(false)
  end
end
