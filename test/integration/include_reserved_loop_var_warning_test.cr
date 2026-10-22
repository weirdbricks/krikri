require "../minitest_helper"

# Issue #239 - a LOOPED include_tasks: whose loop_control.loop_var names
# a reserved word warns on stderr at task run time, right after the TASK
# banner and before the first `included:` line, with the loop_var VALUE
# token's Origin block (live-verified vs ansible-core 2.19.11). A plain
# module task with the same loop_control: stays silent, and so does a
# non-looped include (loop_control is ignored there, the name is never
# bound) - and Display's dedup means one warning per Origin position no
# matter how many hosts iterate the loop.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")
private TWO_HOSTS    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-two-local-hosts.ini")

private def run_include_playbook(pb : String, inventory : String)
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  Process.run(BINARY, ["-i", inventory, pb], output: stdout, error: stderr)
  {stdout.to_s, stderr.to_s}
end

describe "include_tasks reserved loop_var warning" do
  it "warns on stderr with the loop_var value token's origin block" do
    dir = PluginSpecHelper.tmp_path("loopvar-warn")
    FileUtils.mkdir_p(dir)
    sub = File.join(dir, "sub.yml")
    pb = File.join(dir, "pb.yml")
    File.write(sub, "- debug:\n    msg: \"{{ namespace }}\"\n")
    File.write(pb, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          asset:
            namespaces: [a]
        tasks:
          - name: Loop include
            include_tasks: sub.yml
            loop: "{{ asset.namespaces }}"
            loop_control:
              loop_var: "namespace"
      YAML

    stdout, stderr = run_include_playbook(pb, INVENTORY)
    stderr.must_include("[WARNING]: Found variable using reserved name 'namespace'.")
    # Origin = the loop_var VALUE token: line 13, the opening quote's
    # column (8-space indent + `loop_var: `), with the usual 2-line
    # excerpt and caret.
    stderr.must_include("Origin: #{pb}:13:19\n\n11       loop: \"{{ asset.namespaces }}\"\n12       loop_control:\n13         loop_var: \"namespace\"\n                     ^ column 19")
    # The include still runs normally with the shadowing name bound.
    stdout.must_include("included: #{File.expand_path(sub)} for localhost")
    stdout.must_include("\"msg\": \"a\"")
  end

  it "does not warn for a plain module task with the same loop_control" do
    dir = PluginSpecHelper.tmp_path("loopvar-warn-debug")
    FileUtils.mkdir_p(dir)
    pb = File.join(dir, "pb.yml")
    File.write(pb, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          asset:
            namespaces: [a]
        tasks:
          - name: Plain debug
            debug:
              msg: "{{ namespace }}"
            loop: "{{ asset.namespaces }}"
            loop_control:
              loop_var: "namespace"
      YAML

    _stdout, stderr = run_include_playbook(pb, INVENTORY)
    stderr.wont_include("reserved name")
  end

  it "does not warn for a non-looped include_tasks with the same loop_control" do
    dir = PluginSpecHelper.tmp_path("loopvar-warn-noloop")
    FileUtils.mkdir_p(dir)
    sub = File.join(dir, "sub.yml")
    pb = File.join(dir, "pb.yml")
    File.write(sub, "- debug:\n    msg: ok\n")
    File.write(pb, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Plain include
            include_tasks: sub.yml
            loop_control:
              loop_var: "namespace"
      YAML

    _stdout, stderr = run_include_playbook(pb, INVENTORY)
    stderr.wont_include("reserved name")
  end

  it "warns once per origin across several looping hosts" do
    dir = PluginSpecHelper.tmp_path("loopvar-warn-two-hosts")
    FileUtils.mkdir_p(dir)
    sub = File.join(dir, "sub.yml")
    pb = File.join(dir, "pb.yml")
    File.write(sub, "- debug:\n    msg: \"{{ namespace }}\"\n")
    File.write(pb, <<-YAML)
      ---
      - hosts: all
        connection: local
        gather_facts: false
        vars:
          asset:
            namespaces: [a]
        tasks:
          - name: Loop include
            include_tasks: sub.yml
            loop: "{{ asset.namespaces }}"
            loop_control:
              loop_var: "namespace"
      YAML

    _stdout, stderr = run_include_playbook(pb, TWO_HOSTS)
    stderr.scan("Found variable using reserved name 'namespace'.").size.must_equal(1)
  end
end
