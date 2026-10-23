require "../minitest_helper"

# Issue #263 - a task whose `with_items:` list (nested `- ` entries) sits
# between `name:` and the module key still gets ansible's three-level
# [ERROR] chain on a task-arg finalization failure; the origin scans used
# to stop at the first nested `- ` line and print no block at all.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "finalization error block with a loop list before the module key" do
  it "locates the module key and param past nested list entries" do
    src_dir = File.tempname("finalization-loop-before-module")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Copy things
            with_items:
              - s: a
                t: b
            ansible.builtin.copy:
              src: "{{ item.s }}"
              dest: "{{ undefined_dir }}/{{ item.t }}"
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: src_dir)
    text = output.to_s

    playbook = File.expand_path(File.join(src_dir, "pb.yml"))
    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.copy' failed")
    text.must_include("Origin: #{playbook}:6:7")
    text.must_include("Origin: #{playbook}:10:7")
    text.must_include("Origin: #{playbook}:12:15")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
