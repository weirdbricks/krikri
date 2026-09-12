require "../spec_helper"
require "file_utils"

# Read-only - just runs plain shell commands and inspects captured output,
# never mutates host state.

describe "shell plugin" do
  it "rstrips a trailing newline from stdout, matching real Ansible's own AnsibleModule.run_command()" do
    result = PluginSpecHelper.run("shell", {"cmd" => "echo hello"})

    result["stdout"].as_s.should eq("hello")
  end

  it "does not strip internal newlines, only the trailing one" do
    result = PluginSpecHelper.run("shell", {"cmd" => "printf 'line1\\nline2\\n'"})

    result["stdout"].as_s.should eq("line1\nline2")
  end

  it "leaves stdout as-is when there is no trailing newline" do
    result = PluginSpecHelper.run("shell", {"cmd" => "printf 'no-newline'"})

    result["stdout"].as_s.should eq("no-newline")
  end

  it "rstrips stderr the same way" do
    result = PluginSpecHelper.run("shell", {"cmd" => "echo oops 1>&2"})

    result["stderr"].as_s.should eq("oops")
  end

  it "preserves the command's own embedded single quotes when executable: names a custom shell" do
    # Real bug found benchmarking ansible-community.ansible-vault's own
    # "Get installed Vault version" task (`args: {executable: /bin/bash}`,
    # cmd containing `cut -d' ' -f2 | tr -d 'v'`) - a non-default
    # executable: wraps the whole command in `-c '...'`, and naively
    # embedding a command that has its own single quotes prematurely
    # closed that outer quoting, corrupting everything after the first
    # embedded quote ("cut: option requires an argument -- 'd'").
    result = PluginSpecHelper.run("shell", {
      "cmd"        => "echo 'v1.2.3' | cut -d' ' -f2 | tr -d 'v'",
      "executable" => "/bin/bash",
    })

    result["stdout"].as_s.should eq("1.2.3")
  end

  it "creates: accepts a GLOB pattern and reports an ordinary ok result, not a skip" do
    # Same real bug as command:'s own copy (appsilon.mount_efs's
    # `creates: ".../amazon-efs-utils*deb"`) - see command_spec.cr's
    # identical case for the full rationale. shell:'s own creates:
    # check went through a DIFFERENT (also literal-only) helper
    # (remote_file_exists?) before this fix.
    dir = File.tempname("shell-creates-glob-spec")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "amazon-efs-utils_1.2.3.deb"), "")

    result = PluginSpecHelper.run("shell", {"cmd" => "echo should-be-skipped", "creates" => File.join(dir, "amazon-efs-utils*.deb")})

    result["changed"].as_bool.should be_false
    result["msg"].as_s.should contain("Did not run command since")
    result.as_h.has_key?("skipped").should be_false
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # Proactive param-coverage pass: real Ansible's `shell` doesn't document
  # `argv:` in its own docs but it IS functional there (shell and command
  # share the same underlying module implementation - command.py with
  # _uses_shell=True, where `args = args or argv` picks the argv list and
  # basic.py's run_command shlex_quote's each element and joins them with
  # spaces before the shell sees the string). Live-verified against
  # ansible-core 2.19.4: `shell: {argv: [echo, "hello world"]}` ->
  # stdout "hello world", changed: true. Not previously implemented
  # (argv:-only tasks failed "Missing required parameter: cmd").
  it "accepts argv: as an alternative to cmd:, quoting each element for the shell" do
    result = PluginSpecHelper.run("shell", {"argv" => ["echo", "hello world with spaces"].to_json})

    result["failed"].as_bool.should be_false
    result["stdout"].as_s.should eq("hello world with spaces")
  end

  it "keeps shell operators inert inside argv: elements (quoted, not split)" do
    # Same argv contract as command: - an element containing shell
    # metacharacters must reach the command as ONE literal argument
    # (real Ansible shlex_quote's it), not be re-interpreted by the
    # shell that runs the joined string.
    result = PluginSpecHelper.run("shell", {"argv" => ["echo", "a > b | c"].to_json})

    result["stdout"].as_s.should eq("a > b | c")
  end

  # Proactive param-coverage pass: real Ansible's `shell` documents
  # `stdin` as "Set the stdin of the command directly to the specified
  # value" - live-verified against ansible-core 2.19.4 that it behaves
  # identically on shell to command (shared implementation). Not
  # previously implemented.
  it "pipes stdin: to the command" do
    result = PluginSpecHelper.run("shell", {"cmd" => "tr a-z A-Z", "stdin" => "hello"})

    result["stdout"].as_s.should eq("HELLO")
  end

  # Proactive param-coverage pass: real Ansible's `shell` documents
  # `stdin_add_newline` as "Whether to append a newline to stdin data"
  # (bool, default yes) - live-verified against ansible-core 2.19.4 that
  # it behaves identically on shell to command: `wc -l` fed "line1\nline2"
  # counts 2 lines by default, 1 with stdin_add_newline: false. Not
  # previously implemented.
  it "appends a newline to stdin: by default (stdin_add_newline default true)" do
    result = PluginSpecHelper.run("shell", {"cmd" => "wc -l", "stdin" => "line1\nline2"})

    result["stdout"].as_s.should eq("2")
  end

  it "does not append a newline when stdin_add_newline is false" do
    result = PluginSpecHelper.run("shell", {"cmd" => "wc -l", "stdin" => "line1\nline2", "stdin_add_newline" => "false"})

    result["stdout"].as_s.should eq("1")
  end

  # Proactive param-coverage pass: real Ansible's `shell` doesn't document
  # `strip_empty_ends` in its own docs but it IS functional there (shared
  # command.py implementation: stdout/stderr are rstripped of "\r\n" only
  # `if strip`, default yes). Live-verified against ansible-core 2.19.4.
  # Not previously implemented (the rstrip was unconditional).
  it "strips trailing newlines by default (strip_empty_ends default true)" do
    result = PluginSpecHelper.run("shell", {"cmd" => "printf 'a\\nb\\n\\n\\n'"})

    result["stdout"].as_s.should eq("a\nb")
  end

  it "preserves trailing newlines when strip_empty_ends is false" do
    result = PluginSpecHelper.run("shell", {"cmd" => "printf 'a\\nb\\n\\n\\n'", "strip_empty_ends" => "false"})

    result["stdout"].as_s.should eq("a\nb\n\n\n")
  end

  # Proactive param-coverage pass: real Ansible REJECTS
  # `expand_argument_vars:` on shell outright - the shell module's own
  # argspec doesn't include it (only command's does), so the task fails
  # before the command runs with exactly "Unsupported parameters for
  # (shell) module: expand_argument_vars" (live-verified against
  # ansible-core 2.19.4; note the message carries no "Supported
  # parameters include" tail, unlike the warn: rejection). Matching that
  # rejection IS the real-Ansible behavior, so that is what's implemented.
  it "rejects expand_argument_vars: exactly like real Ansible's shell module" do
    result = PluginSpecHelper.run("shell", {"cmd" => "echo hi", "expand_argument_vars" => "false"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Unsupported parameters for (shell) module: expand_argument_vars")
    result["changed"].as_bool.should be_false
  end
end
