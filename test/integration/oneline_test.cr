require "../minitest_helper"
require "file_utils"

# The oneline stdout-callback emulation (src/krikri/oneline_output.cr):
# ANSIBLE_STDOUT_CALLBACK=oneline (or -o/--one-line/--krikri-oneline)
# replaces the whole default-callback output surface with one line per
# host result. Every expected string below is copied from a live
# ansible-core 2.19.11 run of the same playbook (see the shape contract
# in the module comment). Tests drive the compiled binary with a
# per-child env - no suite-process ENV is touched (no serial! needed).

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

raise "bin/krikri-playbook and bin/plugins/ missing - run ./build.sh first" unless File.exists?(BINARY) && Dir.exists?(File.join(PROJECT_ROOT, "bin", "plugins"))

private def run_playbook(playbook_body : String, env_overrides : Hash(String, String) = {} of String => String, args : Array(String) = [] of String) : {Process::Status, String}
  path = PluginSpecHelper.tmp_path("playbook.yml")
  File.write(path, playbook_body)
  env = {"PATH" => ENV["PATH"], "HOME" => ENV["HOME"], "LANG" => "C.UTF-8"}
  env_overrides.each { |key, value| env[key] = value }
  output = IO::Memory.new
  status = Process.run(BINARY, args + [path], output: output, error: output, chdir: PROJECT_ROOT, env: env)
  {status, output.to_s}
end

# Mirrors the live 2.19.11 capture: command ok + empty stdout, dict
# result, when:-skip, a looped command, a fail module with
# ignore_errors:, and a shell task with stderr.
private ONELINE_PLAYBOOK = <<-YAML
  ---
  - name: oneline demo
    hosts: localhost
    gather_facts: false
    tasks:
      - name: cmd ok
        ansible.builtin.command: echo hi

      - name: cmd empty
        ansible.builtin.command: "true"

      - name: debug dict
        ansible.builtin.debug:
          msg: done

      - name: skipped
        ansible.builtin.debug:
          msg: never
        when: false

      - name: loop cmd
        ansible.builtin.command: "echo {{ item }}"
        loop:
          - a
          - b

      - name: fails
        ansible.builtin.fail:
          msg: boom
        ignore_errors: true

      - name: shell stderr
        ansible.builtin.shell: echo out; echo err >&2
        changed_when: false
  YAML

describe "oneline stdout callback emulation" do
  it "renders the exact live-captured line shapes" do
    _, output = run_playbook(ONELINE_PLAYBOOK, {"ANSIBLE_STDOUT_CALLBACK" => "oneline"})

    [
      "localhost | CHANGED | rc=0 | (stdout) hi",
      "localhost | CHANGED | rc=0 | (stdout) ", # empty stdout: trailing space
      "localhost | SUCCESS => {    \"changed\": false,    \"msg\": \"done\"}",
      "localhost | SKIPPED",
      # The looped command's ONE aggregate line (no rc/stdout at the top
      # level: rc defaults to -1, stdout to empty).
      "localhost | CHANGED | rc=-1 | (stdout) ",
      "An exception occurred during task execution. To see the full traceback, use -vvv. The error was: (traceback unavailable)",
      "localhost | FAILED! => {\"changed\": false,\"msg\": \"boom\"}",
      "localhost | SUCCESS | rc=0 | (stdout) out (stderr) err",
    ].each do |expected|
      output.must_include(expected)
    end
  end

  it "prints the 2.19 deprecation warning and no recap or banners" do
    _, output = run_playbook(ONELINE_PLAYBOOK, {"ANSIBLE_STDOUT_CALLBACK" => "oneline"})

    output.must_include("[DEPRECATION WARNING]: The oneline callback plugin is deprecated. This feature will be removed from ansible-core version 2.23.")
    output.must_include("[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg.")
    # The hint precedes the deprecation line, matching the real run's
    # Display ordering.
    hint_idx = output.index!("[WARNING]: Deprecation warnings can be disabled")
    deprecation_idx = output.index!("[DEPRECATION WARNING]")
    (hint_idx < deprecation_idx).must_equal(true)

    output.wont_include("PLAY [")
    output.wont_include("TASK [")
    output.wont_include("PLAY RECAP")
    output.wont_include("ok: [localhost]")
    output.wont_include("...ignoring")
  end

  it "accepts the ansible.builtin.oneline FQCN and a no-op default" do
    _, fqcn = run_playbook(ONELINE_PLAYBOOK, {"ANSIBLE_STDOUT_CALLBACK" => "ansible.builtin.oneline"})
    fqcn.must_include("localhost | CHANGED | rc=0 | (stdout) hi")

    _, default_cb = run_playbook(ONELINE_PLAYBOOK, {"ANSIBLE_STDOUT_CALLBACK" => "default"})
    default_cb.must_include("PLAY RECAP")
    _, fqcn_default = run_playbook(ONELINE_PLAYBOOK, {"ANSIBLE_STDOUT_CALLBACK" => "ansible.builtin.default"})
    fqcn_default.must_include("PLAY RECAP")
  end

  it "exits 1 for any other stdout callback value" do
    status, output = run_playbook(ONELINE_PLAYBOOK, {"ANSIBLE_STDOUT_CALLBACK" => "minimal"})

    status.success?.must_equal(false)
    status.exit_code.must_equal(1)
    output.must_include("[ERROR]: Could not load 'minimal' callback plugin.")
  end

  it "runs through the -o / --one-line / --krikri-oneline flags" do
    ["-o", "--one-line", "--krikri-oneline"].each do |flag|
      _, output = run_playbook(ONELINE_PLAYBOOK, args: [flag])
      output.must_include("localhost | CHANGED | rc=0 | (stdout) hi")
      output.wont_include("PLAY RECAP")
    end
  end

  it "renders skipped looped tasks as one bare SKIPPED line" do
    playbook = <<-YAML
      ---
      - name: skipped loop
        hosts: localhost
        gather_facts: false
        tasks:
          - name: never runs
            ansible.builtin.debug:
              msg: "{{ item }}"
            when: false
            loop:
              - a
              - b
      YAML

    _, output = run_playbook(playbook, {"ANSIBLE_STDOUT_CALLBACK" => "oneline"})
    skip_lines = output.lines.select { |line| line.ends_with?(" | SKIPPED") }
    skip_lines.size.must_equal(1)
    skip_lines.first.must_equal("localhost | SKIPPED")
  end

  it "renders a failed command as both the command line and the FAILED! dump" do
    playbook = <<-YAML
      ---
      - name: cmd fail
        hosts: localhost
        gather_facts: false
        tasks:
          - name: exit 3
            ansible.builtin.command: "exit 3"
            ignore_errors: true
      YAML

    _, output = run_playbook(playbook, {"ANSIBLE_STDOUT_CALLBACK" => "oneline"})
    output.must_include("localhost | FAILED | rc=2 | (stdout) ")
    output.must_include("localhost | FAILED! => {\"changed\": false,\"cmd\": \"exit 3\",\"msg\": \"Error executing command.\",\"rc\": 2,")
  end
end
