require "file_utils"
require "../spec_helper"

# `strategy:` - linear (the default, and this engine's existing
# behavior) versus free, where each host runs the WHOLE task list
# independently with no barrier between tasks. Expectations captured
# from ansible-core 2.19.4 with h1 deliberately sleeping in the first
# task, which is what makes the difference observable.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_strategy(strategy : String?) : {Int32, Array(String)}
  dir = File.tempname("strategy")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"),
    "[g]\nh1 ansible_connection=local\nh2 ansible_connection=local\n")
  line = strategy ? "  strategy: #{strategy}\n" : ""
  File.write(File.join(dir, "pb.yml"), <<-YAML)
    - hosts: all
      gather_facts: false
    #{line.rstrip}
      tasks:
        - name: slow on h1
          ansible.builtin.command: sh -c "test '{{ inventory_hostname }}' = h1 && sleep 2; echo A"
        - name: second
          ansible.builtin.command: echo B
    YAML

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "-f", "5", "pb.yml"],
    output: stdout_io, error: stdout_io, chdir: dir)
  # The banner/result sequence IS the observable difference.
  lines = stdout_io.to_s.lines.compact_map do |lv2|
    if lv2.starts_with?("TASK [")
      lv2.strip
    elsif lv2 =~ /^(changed|ok): \[(h\d)\]/
      "#{$1}:#{$2}"
    end
  end
  {status.exit_code, lines}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "strategy:" do
  # linear: one banner per task, both hosts under it - there is a
  # barrier, so nobody starts task 2 until everyone finished task 1.
  it "keeps a barrier between tasks by default" do
    code, lines = run_strategy(nil)
    code.should eq(0)
    lines.count(&.starts_with?("TASK [slow")).should eq(1)
    lines.index!("TASK [second]").should be > lines.index!("changed:h1")
  end

  it "behaves the same for an explicit linear" do
    _, lines = run_strategy("linear")
    lines.count(&.starts_with?("TASK [slow")).should eq(1)
  end

  # free: h2 races through BOTH its tasks while h1 is still sleeping in
  # the first, so each host gets its own banner sequence and h2's second
  # task is reported before h1's first.
  it "lets a fast host run ahead with free" do
    code, lines = run_strategy("free")
    code.should eq(0)
    lines.count(&.starts_with?("TASK [slow")).should eq(2)
    lines.should eq([
      "TASK [slow on h1]", "changed:h2",
      "TASK [second]", "changed:h2",
      "TASK [slow on h1]", "changed:h1",
      "TASK [second]", "changed:h1",
    ])
  end

  # host_pinned differs from free only in worker affinity, which this
  # engine has no equivalent of.
  it "treats host_pinned as free" do
    _, lines = run_strategy("host_pinned")
    lines.count(&.starts_with?("TASK [slow")).should eq(2)
  end

  # Real Ansible REFUSES an unknown strategy - it does not fall back to
  # linear - and exits 1, not the parser-error 4.
  it "refuses an unknown strategy" do
    code, _ = run_strategy("nonsense")
    code.should eq(1)
  end
end
