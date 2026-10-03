require "../minitest_helper"

# Console output and registered results of FAILING controller-side actions,
# live-verified against ansible-core 2.19.11 (every expectation below is real's
# own output, with tmp paths/timestamps masked).
#
# include_vars with a missing file (register: + ignore_errors:) - real registers
# the action's own failed result, so `r` stays DEFINED afterwards:
#   {failed, message, ansible_included_var_files, ansible_facts, changed,
#    exception, msg}
# and a relative `file:` additionally lists every searched path in `message`.
# The suppressed (failed_when: false) variant registers the same keys with
# failed: false plus the failed_when: verdict, and no msg/exception.
#
# set_fact with an invalid variable name - the registered key order already
# matched real; what was missing is the two-segment [ERROR] block whose cause
# segment points at the invalid key's own Origin, plus real's help text.
# debug with an undefined variable in msg: already printed real's block
# byte-for-byte; pinned here so it cannot regress.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private PLAY_HEADER = [
  "- hosts: localhost",
  "  gather_facts: false",
  "  connection: local",
  "  tasks:",
]

# Runs the task lines (already indented for the `tasks:` list) and returns the
# whole console output plus whether the run succeeded.
private def run_play(tasks : Array(String)) : {Bool, String}
  playbook = File.tempname("action-failure-console", ".yml")
  File.write(playbook, (PLAY_HEADER + tasks).join("\n") + "\n")
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, input: IO::Memory.new)
  {status.success?, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# Dumps the registered `r` through a copy: task, so the display layer's own
# escaping cannot hide a value difference.
private def registered_dump(tasks : Array(String)) : JSON::Any
  dump = PluginSpecHelper.tmp_path("action-failure-console-dump-#{Random::Secure.hex(4)}.json")
  success, output = run_play(tasks + [
    "      - name: dump",
    "        ansible.builtin.copy:",
    "          content: |-",
    "            {{ r | to_json }}",
    "          dest: #{dump}",
  ])
  success.must_equal(true, output)
  JSON.parse(File.read(dump))
ensure
  File.delete(dump) if dump && File.exists?(dump)
end

describe "include_vars failure registration" do
  it "registers the action's own failed result for a missing relative file" do
    result = registered_dump([
      "      - ansible.builtin.include_vars:",
      "          file: definitely_missing.yml",
      "        ignore_errors: true",
      "        register: r",
    ])

    result.as_h.keys.must_equal(
      ["failed", "message", "ansible_included_var_files", "ansible_facts", "changed", "exception", "msg"]
    )
    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["exception"].as_s.must_equal("(traceback unavailable)")
    result["msg"].as_s.must_equal("Task failed: Action failed: Unknown error.")
    result["ansible_included_var_files"].as_a.must_be_empty
    result["ansible_facts"].as_h.must_be_empty

    message = result["message"].as_s
    message.must_match(/\ACould not find or access 'definitely_missing\.yml'\nSearched in:\n\t/)
    message.must_match(/ on the Ansible Controller\.\nIf you are using a module and expect the file to exist on the remote, see the remote_src option\z/)
    # Every searched candidate is the "<base>/vars/<file>" / "<base>/<file>"
    # pair of the play dir, repeated twice (the basedir and the play dir are
    # the same for a play-level task). Only the file-name part is asserted -
    # the dirs depend on the playbook's own location.
    searched = message.split("\nSearched in:\n")[1].split(" on the Ansible")[0].split("\n\t").map(&.strip)
    searched.map(&.ends_with?("definitely_missing.yml")).must_equal([true, true, true, true])
    searched.map(&.ends_with?("/vars/definitely_missing.yml")).must_equal([true, false, true, false])
  end

  it "leaves r defined afterwards, as an ordinary task failure does" do
    success, output = run_play([
      "      - ansible.builtin.include_vars:",
      "          file: definitely_missing.yml",
      "        ignore_errors: true",
      "        register: r",
      "      - ansible.builtin.debug:",
      "          msg: \"DEFINED={{ r is defined }}\"",
    ])

    success.must_equal(true, output)
    output.must_include(%("msg": "DEFINED=True"))
    output.must_match(/ignored=1/)
  end

  it "keeps an absolute missing file free of the searched-in list" do
    result = registered_dump([
      "      - ansible.builtin.include_vars:",
      "          file: /nonexistent/definitely_missing.yml",
      "        ignore_errors: true",
      "        register: r",
    ])

    result["message"].as_s.must_equal(
      "Could not find or access '/nonexistent/definitely_missing.yml' on the Ansible Controller.\n" \
      "If you are using a module and expect the file to exist on the remote, see the remote_src option"
    )
  end

  it "registers a missing dir with the directory-does-not-exist message" do
    result = registered_dump([
      "      - ansible.builtin.include_vars:",
      "          dir: /nonexistent/varsdir",
      "        ignore_errors: true",
      "        register: r",
    ])

    result.as_h.keys.must_equal(
      ["failed", "message", "ansible_included_var_files", "ansible_facts", "changed", "exception", "msg"]
    )
    result["message"].as_s.must_equal("/nonexistent/varsdir directory does not exist")
  end

  it "registers the wrapped facts and the trailing null-lookup warning for name: with no file" do
    result = registered_dump([
      "      - ansible.builtin.include_vars:",
      "          name: a.yml",
      "        ignore_errors: true",
      "        register: r",
    ])

    result.as_h.keys.must_equal(
      ["failed", "message", "ansible_included_var_files", "ansible_facts", "changed", "exception", "msg", "warnings"]
    )
    result["ansible_facts"].as_h.keys.must_equal(["a.yml"])
    result["warnings"].as_a.map(&.as_s).must_equal(
      ["Invalid request to find a file that matches a \"null\" value"]
    )
  end

  it "registers the finalization failure of an undefined include_vars path" do
    result = registered_dump([
      "      - ansible.builtin.include_vars:",
      "          file: \"{{ definitely_undefined }}\"",
      "        ignore_errors: true",
      "        register: r",
    ])

    result.as_h.keys.must_equal(["failed", "exception", "msg", "changed"])
    result["msg"].as_s.must_equal(
      "Task failed: Finalization of task args for 'ansible.builtin.include_vars' failed: " \
      "Error while resolving value for 'file': 'definitely_undefined' is undefined"
    )
  end

  it "registers the suppressed failure shape under failed_when: false" do
    result = registered_dump([
      "      - ansible.builtin.include_vars:",
      "          file: /nonexistent/definitely_missing.yml",
      "        failed_when: false",
      "        register: r",
    ])

    result.as_h.keys.must_equal(
      ["failed", "message", "ansible_included_var_files", "ansible_facts", "changed", "failed_when_result"]
    )
    result["failed"].as_bool.must_equal(false)
    result["failed_when_result"].as_bool.must_equal(false)
    result["message"].as_s.must_equal(
      "Could not find or access '/nonexistent/definitely_missing.yml' on the Ansible Controller.\n" \
      "If you are using a module and expect the file to exist on the remote, see the remote_src option"
    )
  end
end

describe "action failure console blocks" do
  it "prints set_fact's invalid-variable-name failure as a two-segment block at the key's Origin" do
    success, output = run_play([
      "      - ansible.builtin.set_fact:",
      "          \"bad-name\": 1",
      "        ignore_errors: true",
    ])

    success.must_equal(true, output)
    output.must_include("[ERROR]: Task failed: Invalid variable name 'bad-name'.")
    output.must_include("Task failed.\nOrigin: ")
    output.must_include("\n<<< caused by >>>\n\nInvalid variable name 'bad-name'.\nOrigin: ")
    # the caret lands on the opening quote of the quoted key, the same column
    # the bare form gets (real 2.19.11, 10-space indent -> column 11)
    output.must_include("          ^ column 11")
    output.must_include("Variable names must be strings starting with a letter or underscore character, and contain only letters, numbers and underscores.")
    output.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Invalid variable name 'bad-name'."}))
    output.must_match(/ignored=1/)
  end

  it "points set_fact's cause segment at an unquoted invalid key the same way" do
    success, output = run_play([
      "      - ansible.builtin.set_fact:",
      "          bad-name: 1",
      "        ignore_errors: true",
    ])

    success.must_equal(true, output)
    output.must_include("\n<<< caused by >>>\n\nInvalid variable name 'bad-name'.\nOrigin: ")
    output.must_include("          ^ column 11")
    output.must_match(/ignored=1/)
  end

  it "halts the play on set_fact's invalid variable name without ignore_errors" do
    success, output = run_play([
      "      - ansible.builtin.set_fact:",
      "          \"bad-name\": 1",
    ])

    success.must_equal(false, output)
    output.must_include("[ERROR]: Task failed: Invalid variable name 'bad-name'.")
    output.must_include("Variable names must be strings starting with a letter or underscore character")
    output.must_match(/failed=1/)
  end

  it "prints debug's undefined-msg failure as a two-segment finalization block" do
    success, output = run_play([
      "      - ansible.builtin.debug:",
      "          msg: \"{{ definitely_undefined }}\"",
      "        ignore_errors: true",
    ])

    success.must_equal(true, output)
    output.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.debug' failed: Error while resolving value for 'msg': 'definitely_undefined' is undefined")
    output.must_include("\n<<< caused by >>>\n\nError while resolving value for 'msg': 'definitely_undefined' is undefined\nOrigin: ")
    output.must_include("^ column 16")
    output.must_include(%(fatal: [localhost]: FAILED! => {"msg": "Task failed: Finalization of task args))
    output.must_match(/ignored=1/)
  end

  it "halts the play on debug's undefined msg without ignore_errors" do
    success, output = run_play([
      "      - ansible.builtin.debug:",
      "          msg: \"{{ definitely_undefined }}\"",
    ])

    success.must_equal(false, output)
    output.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.debug' failed: Error while resolving value for 'msg': 'definitely_undefined' is undefined")
    output.must_match(/failed=1/)
  end
end
