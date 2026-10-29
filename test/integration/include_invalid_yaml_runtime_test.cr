# A runtime-loaded file (include_tasks:) that is not valid YAML at all is
# ansible-core's whole-run loader refusal: the [ERROR] YAML parsing failed
# block on STDERR, rc=4, NO PLAY RECAP (live-verified vs 2.19.11).
# jbertozzi.cis_rhel8's tasks/section_1.yml:75 (issue #534): krikri used to
# swallow the include-load parse error into a per-task "Failed to load
# included tasks" failure (rc=2, with a recap).
require "../minitest_helper"
require "file_utils"

private BINARY = File.expand_path(File.join(__DIR__, "..", "..", "bin", "krikri-playbook"))

describe "runtime include-load invalid-YAML refusal" do
  it "aborts the whole run with the [ERROR] block and rc=4, no recap" do
    dir = PluginSpecHelper.tmp_path("invalid-yaml-include-runtime")
    FileUtils.mkdir_p(File.join(dir, "tasks"))
    File.write(File.join(dir, "site.yml"), <<-PLAY)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: Initial Setup
            ansible.builtin.include_tasks: tasks/section_1.yml
      PLAY
    # The role's own shape: a multi-line quoted name whose continuation
    # leaves `block` as a bare scalar, with the next line an indented
    # `template:` mapping - libyaml's "could not find expected ':'".
    File.write(File.join(dir, "tasks", "section_1.yml"), <<-TASKS)
      ---
      - name: "1.1.2 Ensure /tmp is configured (Scored)\\n
        1.1.5 Ensure noexec option set on /tmp partition (Scored)"
        block
          template:
            src: tmp.mount.j2
      TASKS

    captured = IO::Memory.new
    status = Process.run(BINARY, ["-i", File.join(__DIR__, "..", "fixtures", "inventory-localhost-local.ini"), "-c", "local", File.join(dir, "site.yml")],
      output: captured, error: captured, chdir: dir)
    status.exit_code.must_equal(4)
    out = captured.to_s
    out.must_include("TASK [Initial Setup]")
    out.wont_include("PLAY RECAP")
    out.must_include("[ERROR]: YAML parsing failed: Colons in unquoted values must be followed by a non-space character.")
    out.must_include("Origin: #{File.join(dir, "tasks", "section_1.yml")}:5:13")
    out.wont_include("Failed to load included tasks")
  end
end
