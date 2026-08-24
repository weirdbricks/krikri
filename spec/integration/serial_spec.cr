require "file_utils"
require "../spec_helper"

# `serial:` batches a play: real Ansible runs the WHOLE play against one
# batch of hosts at a time, which is what makes a rolling restart
# rolling. This engine ignored the keyword entirely, so `serial: 1` still
# hit every host simultaneously - the batching that exists to protect a
# fleet silently did nothing.
#
# Every expected ordering below is from an ansible-core 2.19.4 run of the
# same playbook over four hosts.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")

private def run_serial(serial : String?) : Array(String)
  dir = File.tempname("serial")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"),
    "[g]\nh1 ansible_connection=local\nh2 ansible_connection=local\n" \
    "h3 ansible_connection=local\nh4 ansible_connection=local\n")
  serial_line = serial ? "  serial: #{serial}\n" : ""
  File.write(File.join(dir, "pb.yml"), <<-YAML)
    - hosts: all
      gather_facts: false
    #{serial_line.rstrip}
      tasks:
        - name: a
          ansible.builtin.debug: {msg: "A-{{ inventory_hostname }}"}
        - name: b
          ansible.builtin.debug: {msg: "B-{{ inventory_hostname }}"}
    YAML

  stdout_io = IO::Memory.new
  Process.run(BINARY, ["-i", "inv.ini", "pb.yml"], output: stdout_io, error: stdout_io, chdir: dir)
  stdout_io.to_s.scan(/^\s{2}([AB]-h\d)$/m).map { |m| m[1] }
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "serial:" do
  # One host at a time: the whole play (both tasks) finishes for h1
  # before h2 starts.
  it "runs the whole play per host for serial: 1" do
    run_serial("1").should eq(%w[A-h1 B-h1 A-h2 B-h2 A-h3 B-h3 A-h4 B-h4])
  end

  it "batches two at a time for serial: 2" do
    run_serial("2").should eq(%w[A-h1 A-h2 B-h1 B-h2 A-h3 A-h4 B-h3 B-h4])
  end

  # A percentage is of the TOTAL host count, rounded up.
  it "accepts a percentage" do
    run_serial(%("50%")).should eq(%w[A-h1 A-h2 B-h1 B-h2 A-h3 A-h4 B-h3 B-h4])
  end

  # A list sizes successive batches, and the LAST entry sizes every
  # remaining batch - so [1, 2] over four hosts is 1, then 2, then the
  # one host left.
  it "accepts a list of batch sizes" do
    run_serial("[1, 2]").should eq(%w[A-h1 B-h1 A-h2 A-h3 B-h2 B-h3 A-h4 B-h4])
  end

  it "handles a batch larger than the remainder" do
    run_serial("3").should eq(%w[A-h1 A-h2 A-h3 B-h1 B-h2 B-h3 A-h4 B-h4])
  end

  it "treats 100% as a single batch" do
    run_serial(%("100%")).should eq(%w[A-h1 A-h2 A-h3 A-h4 B-h1 B-h2 B-h3 B-h4])
  end

  # Guard: without serial: the play still runs every host at once.
  it "is a no-op when absent" do
    run_serial(nil).should eq(%w[A-h1 A-h2 A-h3 A-h4 B-h1 B-h2 B-h3 B-h4])
  end
end
