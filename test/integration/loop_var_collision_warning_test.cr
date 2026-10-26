require "../minitest_helper"

# task_executor.py (_execute, ansible-core 2.19.11): a looped task whose
# loop_var (default "item") is already in the task's variables warns once
# per run - the shape real roles hit when an include_tasks: loop's item is
# threaded into the included tasks and one of them loops on the default
# "item" again (softasap.sa_prometheus_exporters, issue #629). The warning
# is the Display.warning(obj=loop_var) block - Origin: <unknown>, the
# loop_var, then the loop_control hint - deduped like every Display
# warning, and silent whenever the name is genuinely free.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_loop_playbook(pb : String)
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY, pb], output: stdout, error: stderr)
  {stdout.to_s, stderr.to_s}
end

describe "loop variable collision warning" do
  it "warns when a nested looped task sees the outer include's item" do
    dir = PluginSpecHelper.tmp_path("loopvar-collision")
    FileUtils.mkdir_p(dir)
    sub = File.join(dir, "sub.yml")
    pb = File.join(dir, "pb.yml")
    File.write(sub, "- name: Inner loop\n  debug:\n    msg: \"{{ item }}\"\n  loop:\n    - one\n    - two\n")
    File.write(pb, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Outer include
            include_tasks: sub.yml
            loop:
              - a
              - b
      YAML

    stdout, stderr = run_loop_playbook(pb)
    stderr.must_include("[WARNING]: The loop variable 'item' is already in use.\nOrigin: <unknown>\n\nitem\n\nYou should set the `loop_var` value in the `loop_control` option for the task to something else to avoid variable collisions and unexpected behavior.")
    # Real 2.19.11 emits no blank line before the warning (its stderr starts
    # directly with "[WARNING]:") but multi-line warnings end with a blank
    # line (format_event appends "\n\n") - byte-verified against 2.19.11.
    stderr.starts_with?("[WARNING]: The loop variable 'item' is already in use.\n").must_equal(true)
    stderr.must_include("behavior.\n\n")
    # Display's dedup: the outer include runs twice, the inner loop four
    # times - still one warning.
    stderr.scan("The loop variable 'item' is already in use.").size.must_equal(1)
    # The nested loop still runs with the inner item.
    stdout.must_include("\"msg\": \"one\"")
    stdout.must_include("\"msg\": \"two\"")
  end

  it "does not warn when the loop var name is free of a collision" do
    dir = PluginSpecHelper.tmp_path("loopvar-no-collision")
    FileUtils.mkdir_p(dir)
    sub = File.join(dir, "sub.yml")
    pb = File.join(dir, "pb.yml")
    File.write(sub, "- name: Inner loop\n  debug:\n    msg: \"{{ sub }}\"\n  loop:\n    - one\n  loop_control:\n    loop_var: sub\n")
    File.write(pb, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Outer include
            include_tasks: sub.yml
            loop:
              - a
      YAML

    _stdout, stderr = run_loop_playbook(pb)
    stderr.wont_include("already in use")
  end
end
