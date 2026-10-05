require "../minitest_helper"
require "file_utils"

# The ad-hoc CLI (krikri.cr, binary `bin/krikri`) gained the full real
# `ansible` ad-hoc option surface (verified against ansible-core
# 2.19.4's own `ansible --help`). These specs drive the compiled binary
# against local-connection fixtures, the same "no SSH required" trick
# test/integration/cli_test.cr uses for krikri-playbook.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")
private TWO_HOSTS    = File.join(__DIR__, "..", "fixtures", "inventory-two-local-hosts.ini")

# minitest.cr has no before_suite hook; the classic suite built the
# binaries lazily here, the minitest suite expects ./build.sh to have run
# already, so this only fails fast when that precondition is missing.
raise "bin/krikri and bin/plugins/ missing - run ./build.sh first" unless File.exists?(BINARY) && Dir.exists?(File.join(PROJECT_ROOT, "bin", "plugins"))

private def run_adhoc(args : Array(String), env : Hash(String, String)? = nil) : {Process::Status, String}
  output = IO::Memory.new
  status = Process.run(BINARY, args, output: output, error: output, chdir: PROJECT_ROOT, env: env)
  {status, output.to_s}
end

describe "krikri ad-hoc CLI" do
  it "--help lists the Ansible ad-hoc option surface" do
    _, output = run_adhoc(["--help"])

    ["--become-password-file", "--become-pass-file",
     "--connection-password-file", "--conn-pass-file",
     "--flush-cache", "--list-hosts", "--playbook-dir", "--task-timeout",
     "--vault-id", "--vault-password-file", "--vault-pass-file",
     "-B", "--background", "-D", "--diff",
     "-J", "--ask-vault-password", "--ask-vault-pass",
     "-K", "--ask-become-pass", "-M", "--module-path",
     "--become-method", "--private-key", "--key-file",
     "--scp-extra-args", "--sftp-extra-args", "--ssh-common-args",
     "--ssh-extra-args", "-T", "--timeout", "-c", "--connection",
     "-e", "--extra-vars", "-k", "--ask-pass", "-o", "--one-line",
     "-t", "--tree", "-P", "--poll"].each do |flag|
      output.must_include(flag)
    end
  end

  it "--list-hosts lists matched hosts and exits 0, without executing" do
    status, output = run_adhoc(["all", "-i", TWO_HOSTS, "--list-hosts", "-m", "ping"])

    status.success?.must_equal(true)
    output.must_include("hosts (2)")
    output.must_include("hostone")
    output.must_include("hosttwo")
  end

  it "--list-hosts honors --limit" do
    status, output = run_adhoc(["all", "-i", TWO_HOSTS, "--limit", "hosttwo", "--list-hosts", "-m", "ping"])

    status.success?.must_equal(true)
    output.must_include("hosts (1)")
    output.must_include("hosttwo")
    output.wont_include("hostone\n")
  end

  it "-c/--connection sets the connection type for the ad-hoc task" do
    status, output = run_adhoc(["localhost", "-i", INVENTORY, "-c", "local", "-m", "debug", "-a", "msg=connflag"])

    status.success?.must_equal(true)
    output.must_include("connflag")
  end

  it "-o/--one-line condenses output to a single line" do
    _, output = run_adhoc(["localhost", "-i", INVENTORY, "-o", "-m", "debug", "-a", "msg=oneliner"])

    lines = output.strip.split("\n")
    lines.size.must_equal(1)
    lines[0].must_include("localhost | SUCCESS => {")
    lines[0].must_include("oneliner")
  end

  it "-o renders command-module output inline with escaped newlines" do
    _, output = run_adhoc(["localhost", "-i", INVENTORY, "-o", "-m", "command", "-a", "printf 'a\\nb\\n'"])

    lines = output.strip.split("\n")
    lines.size.must_equal(1)
    # The embedded newline is escaped as literal \n, keeping the line one
    # line (the module itself strips the trailing one).
    lines[0].must_include("rc=0 | (stdout) a\\nb")
  end

  it "-t/--tree logs the result as JSON in the tree directory" do
    tree = PluginSpecHelper.tmp_path("adhoc-tree")
    FileUtils.rm_rf(tree)
    status, _ = run_adhoc(["localhost", "-i", INVENTORY, "-t", tree, "-m", "debug", "-a", "msg=treed"])

    begin
      status.success?.must_equal(true)
      result_file = File.join(tree, "localhost")
      File.exists?(result_file).must_equal(true)
      JSON.parse(File.read(result_file))["msg"].as_s.must_equal("treed")
    ensure
      FileUtils.rm_rf(tree)
    end
  end

  # Ad-hoc result shape for command/shell, matched against Ansible's
  # own ad-hoc output (re-verified 2026-09-16, ansible-core 2.19.11,
  # matching command.py's r['msg'] = '' initialization + exit_json):
  # `ansible localhost -c local -m command -a "echo hi" -t <dir>` writes
  # {"changed": true, "cmd": ["echo", "hi"], "rc": 0, "msg": "",
  # "stderr": "", "stderr_lines": [], "stdout": "hi",
  # "stdout_lines": ["hi"], ...} - cmd is the argv LIST for command and
  # the raw STRING for shell, the *_lines keys are present, and msg is
  # an explicit EMPTY STRING on success (real command.py initializes
  # r['msg'] = '' and exits it verbatim; the earlier "msg is ABSENT"
  # reading of the 2026-09-13 sweep was wrong - both plugins now emit it
  # via include_empty_msg). The ad-hoc path dumps the plugin's raw
  # result verbatim, so these plugin-side keys are what the tree file -
  # and the SUCCESS => JSON dump for non-command-shaped results - must
  # carry.
  describe "command/shell ad-hoc result shape" do
    it "command carries cmd as an argv list, stdout_lines/stderr_lines, and an empty msg on success" do
      tree = PluginSpecHelper.tmp_path("adhoc-command-shape")
      FileUtils.rm_rf(tree)
      status, _ = run_adhoc(["localhost", "-i", INVENTORY, "-c", "local", "-t", tree, "-m", "command", "-a", "echo hi"])

      begin
        status.success?.must_equal(true)
        result = JSON.parse(File.read(File.join(tree, "localhost")))
        result["cmd"].as_a.map(&.as_s).must_equal(["echo", "hi"])
        result["stdout_lines"].as_a.map(&.as_s).must_equal(["hi"])
        result["stderr_lines"].as_a.map(&.as_s).must_equal([] of String)
        result["rc"].as_i.must_equal(0)
        result["changed"].as_bool.must_equal(true)
        result["msg"].as_s.must_equal("")
      ensure
        FileUtils.rm_rf(tree)
      end
    end

    it "shell carries cmd as the raw string, stdout_lines/stderr_lines, and an empty msg on success" do
      tree = PluginSpecHelper.tmp_path("adhoc-shell-shape")
      FileUtils.rm_rf(tree)
      status, _ = run_adhoc(["localhost", "-i", INVENTORY, "-c", "local", "-t", tree, "-m", "shell", "-a", "echo hi && echo bye"])

      begin
        status.success?.must_equal(true)
        result = JSON.parse(File.read(File.join(tree, "localhost")))
        result["cmd"].as_s.must_equal("echo hi && echo bye")
        result["stdout"].as_s.must_equal("hi\nbye")
        result["stdout_lines"].as_a.map(&.as_s).must_equal(["hi", "bye"])
        result["stderr_lines"].as_a.map(&.as_s).must_equal([] of String)
        result["rc"].as_i.must_equal(0)
        result["changed"].as_bool.must_equal(true)
        result["msg"].as_s.must_equal("")
      ensure
        FileUtils.rm_rf(tree)
      end
    end
  end

  it "-e/--extra-vars feed the templating context" do
    status, output = run_adhoc(["localhost", "-i", INVENTORY, "-e", "greet=adhoc", "-m", "debug", "-a", "msg={{ greet }}"])

    status.success?.must_equal(true)
    output.must_include("adhoc")
  end

  it "accepts the connection/become password-file, ssh-args, -T, -M, --flush-cache and --playbook-dir flags together" do
    status, _ = run_adhoc(["localhost", "-i", INVENTORY,
                           "--connection-password-file", "/dev/null",
                           "--become-password-file", "/dev/null",
                           "--key-file", "/dev/null",
                           "-T", "25",
                           "--ssh-common-args", "-o LogLevel=ERROR",
                           "--ssh-extra-args", "-o Compression=yes",
                           "--scp-extra-args", "-O",
                           "--sftp-extra-args", "-x",
                           "-M", "/tmp",
                           "--flush-cache",
                           "--playbook-dir", "/tmp",
                           "--task-timeout", "30",
                           "-m", "ping"])
    status.exit_code.must_equal(0)
  end

  it "stacks -v/-vv/-vvv like Ansible and krikri-playbook" do
    status, _ = run_adhoc(["localhost", "-i", INVENTORY, "-vv", "-m", "ping"])

    status.success?.must_equal(true)
  end

  it "still rejects an unknown option with the same error shape" do
    status, output = run_adhoc(["localhost", "-i", INVENTORY, "--no-such-flag", "-m", "ping"])

    status.success?.must_equal(false)
    output.must_include("Error")
  end

  # Ansible passes the ENTIRE ad-hoc result buffer to one
  # Display.display(msg, color=...) call whose stringc() wraps each line
  # with the same SGR code - so the whole block gets colored, not just
  # the status word. Codes verified byte-for-byte against ansible-core
  # 2.19.4 (`ANSIBLE_FORCE_COLOR=1 ansible ... | xxd`): yellow=0;33,
  # green=0;32, red=0;31.
  describe "ANSI colorization" do
    it "colors the whole CHANGED command block yellow, every line" do
      _, output = run_adhoc(["localhost", "-i", INVENTORY, "-c", "local", "-m", "command", "-a", "echo colormarker"],
        env: {"ANSIBLE_FORCE_COLOR" => "1"})

      output.must_include("\e[0;33mlocalhost | CHANGED | rc=0 >>\e[0m\n")
      output.must_include("\e[0;33mcolormarker\e[0m\n")
    end

    it "colors the whole SUCCESS JSON block green, every line" do
      _, output = run_adhoc(["localhost", "-i", INVENTORY, "-c", "local", "-m", "debug", "-a", "msg=greenmarker"],
        env: {"ANSIBLE_FORCE_COLOR" => "1"})

      output.must_include("\e[0;32mlocalhost | SUCCESS => {\e[0m\n")
      output.must_include("\e[0;32m}\e[0m\n")
    end

    it "colors the whole FAILED command block red, every line" do
      _, output = run_adhoc(["localhost", "-i", INVENTORY, "-c", "local", "-m", "command", "-a", "false"],
        env: {"ANSIBLE_FORCE_COLOR" => "1"})

      output.must_include("\e[0;31mlocalhost | FAILED! | rc=1 >>\e[0m\n")
    end

    it "stays plain when piped without ANSIBLE_FORCE_COLOR" do
      _, output = run_adhoc(["localhost", "-i", INVENTORY, "-c", "local", "-m", "command", "-a", "echo plainmarker"])

      output.must_include("localhost | CHANGED | rc=0 >>")
      output.wont_include("\e[0;33m")
    end
  end

  # JSON-object `-a` args: Ansible's ad-hoc arg parsing accepts a
  # single JSON object string as the module params (verified live
  # against ansible-core 2.19.11, same sweep date) - before the
  # JSON-object path in PlaybookParser.parse_adhoc_params existed, the
  # whole string was silently ignored and the module ran on its own
  # defaults (e.g. debug printed "Hello world!" instead of the given
  # msg). Malformed JSON-looking strings fall through to the ordinary
  # k=v split, exactly as Ansible does (live-checked: `{bad json`
  # became `_raw_params`, which command then tried to execute and
  # failed with rc=2).
  describe "JSON-object -a args" do
    it "parses a JSON object as the module params" do
      status, output = run_adhoc(["localhost", "-i", INVENTORY, "-c", "local", "-m", "debug", "-a", %({"msg":"hi"})])

      status.success?.must_equal(true)
      output.must_include(%("msg": "hi"))
    end

    it "keeps nested dict/list types through a dict-shaped module arg" do
      status, output = run_adhoc(["localhost", "-i", INVENTORY, "-c", "local", "-m", "command",
                                  "-a", %({"argv":["echo","jsonargvmarker"]})])

      status.success?.must_equal(true)
      output.must_include("jsonargvmarker")
    end

    it "still parses plain k=v args unchanged" do
      status, output = run_adhoc(["localhost", "-i", INVENTORY, "-c", "local", "-m", "debug",
                                  "-a", %(msg="kv marker")])

      status.success?.must_equal(true)
      output.must_include("kv marker")
    end

    it "falls back to k=v parsing for malformed JSON-looking args, like Ansible" do
      status, output = run_adhoc(["localhost", "-i", INVENTORY, "-c", "local", "-m", "command", "-a", "{bad json"])

      status.success?.must_equal(false)
      output.must_include("FAILED")
      output.wont_include("Hello world!")
    end
  end
end
