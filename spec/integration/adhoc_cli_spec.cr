require "../spec_helper"
require "file_utils"

# The ad-hoc CLI (krikri.cr, binary `bin/krikri`) gained the full real
# `ansible` ad-hoc option surface (verified against ansible-core
# 2.19.4's own `ansible --help`). These specs drive the compiled binary
# against local-connection fixtures, the same "no SSH required" trick
# spec/integration/cli_spec.cr uses for krikri-playbook.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")
private TWO_HOSTS    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-two-local-hosts.ini")

Spec.before_suite do
  needs_build = !File.exists?(BINARY) || !Dir.exists?(File.join(PROJECT_ROOT, "bin", "plugins"))
  next unless needs_build

  status = Process.run("./build.sh", chdir: PROJECT_ROOT, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
  raise "build.sh failed while preparing integration specs" unless status.success?
end

private def run_adhoc(args : Array(String)) : {Process::Status, String}
  output = IO::Memory.new
  status = Process.run(BINARY, args, output: output, error: output, chdir: PROJECT_ROOT)
  {status, output.to_s}
end

describe "krikri ad-hoc CLI" do
  it "--help lists the real ansible ad-hoc option surface" do
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
      output.should contain(flag)
    end
  end

  it "--list-hosts lists matched hosts and exits 0, without executing" do
    status, output = run_adhoc(["all", "-i", TWO_HOSTS, "--list-hosts", "-m", "ping"])

    status.success?.should be_true
    output.should contain("hosts (2)")
    output.should contain("hostone")
    output.should contain("hosttwo")
  end

  it "--list-hosts honors --limit" do
    status, output = run_adhoc(["all", "-i", TWO_HOSTS, "--limit", "hosttwo", "--list-hosts", "-m", "ping"])

    status.success?.should be_true
    output.should contain("hosts (1)")
    output.should contain("hosttwo")
    output.should_not contain("hostone\n")
  end

  it "-c/--connection sets the connection type for the ad-hoc task" do
    status, output = run_adhoc(["localhost", "-i", INVENTORY, "-c", "local", "-m", "debug", "-a", "msg=connflag"])

    status.success?.should be_true
    output.should contain("connflag")
  end

  it "-o/--one-line condenses output to a single line" do
    _, output = run_adhoc(["localhost", "-i", INVENTORY, "-o", "-m", "debug", "-a", "msg=oneliner"])

    lines = output.strip.split("\n")
    lines.size.should eq(1)
    lines[0].should contain("localhost | SUCCESS => {")
    lines[0].should contain("oneliner")
  end

  it "-o renders command-module output inline with escaped newlines" do
    _, output = run_adhoc(["localhost", "-i", INVENTORY, "-o", "-m", "command", "-a", "printf 'a\\nb\\n'"])

    lines = output.strip.split("\n")
    lines.size.should eq(1)
    # The embedded newline is escaped as literal \n, keeping the line one
    # line (the module itself strips the trailing one).
    lines[0].should contain("rc=0 | (stdout) a\\nb")
  end

  it "-t/--tree logs the result as JSON in the tree directory" do
    tree = File.join(PROJECT_ROOT, "spec", "tmp", "adhoc-tree-spec")
    FileUtils.rm_rf(tree)
    status, _ = run_adhoc(["localhost", "-i", INVENTORY, "-t", tree, "-m", "debug", "-a", "msg=treed"])

    begin
      status.success?.should be_true
      result_file = File.join(tree, "localhost")
      File.exists?(result_file).should be_true
      JSON.parse(File.read(result_file))["msg"].as_s.should eq("treed")
    ensure
      FileUtils.rm_rf(tree)
    end
  end

  it "-e/--extra-vars feed the templating context" do
    status, output = run_adhoc(["localhost", "-i", INVENTORY, "-e", "greet=adhoc", "-m", "debug", "-a", "msg={{ greet }}"])

    status.success?.should be_true
    output.should contain("adhoc")
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
    status.exit_code.should eq(0)
  end

  it "stacks -v/-vv/-vvv like real ansible and krikri-playbook" do
    status, _ = run_adhoc(["localhost", "-i", INVENTORY, "-vv", "-m", "ping"])

    status.success?.should be_true
  end

  it "still rejects an unknown option with the same error shape" do
    status, output = run_adhoc(["localhost", "-i", INVENTORY, "--no-such-flag", "-m", "ping"])

    status.success?.should be_false
    output.should contain("Error")
  end
end
