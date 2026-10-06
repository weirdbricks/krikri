# A runtime-loaded file (include_tasks: chain) whose own import_tasks:/
# include_role: carries a disallowed attribute (`static: no`) is
# ansible-core's whole-run TaskInclude attribute refusal: the [ERROR] +
# invalid_task_attribute_failed + Origin block on STDERR, rc=4, NO PLAY
# RECAP (live-verified vs 2.19.11). Round 2100407 (oVirt.image-template's
# tasks/qcow2_image.yml:173): krikri used to swallow the include-load
# parse error into a per-task "Failed to load included tasks" failure
# (rc=2, with a recap).
require "../minitest_helper"
require "file_utils"

private BINARY = File.expand_path(File.join(__DIR__, "..", "..", "bin", "krikri-playbook"))

describe "runtime include-load TaskInclude attribute refusal" do
  it "aborts the whole run with the [ERROR] block and rc=4, no recap" do
    dir = PluginSpecHelper.tmp_path("static-include-runtime")
    FileUtils.mkdir_p(File.join(dir, "tasks"))
    File.write(File.join(dir, "site.yml"), <<-PLAY)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: Image upload
            ansible.builtin.include_tasks: tasks/qcow2_image.yml
      PLAY
    File.write(File.join(dir, "tasks", "qcow2_image.yml"), <<-TASKS)
      ---
      - name: Include prerequisites tasks for VM
        import_tasks: empty.yml
        static: no
      TASKS
    File.write(File.join(dir, "tasks", "empty.yml"), "---\n")

    captured = IO::Memory.new
    status = Process.run(BINARY, ["-i", "localhost,", "-c", "local", File.join(dir, "site.yml")],
      output: captured, error: captured, chdir: dir)
    status.exit_code.must_equal(4)
    out = captured.to_s
    out.must_include("TASK [Image upload]")
    out.wont_include("PLAY RECAP")
    out.must_include("[ERROR]: 'static' is not a valid attribute for a TaskInclude")
    out.must_include("This error can be suppressed as a warning using the \"invalid_task_attribute_failed\" configuration")
    out.must_include("Origin: #{File.join(dir, "tasks", "qcow2_image.yml")}:4:3")
    out.wont_include("Failed to load included tasks")
  end
end
