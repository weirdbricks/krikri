require "file_utils"
require "../spec_helper"

# `order:` and `throttle:`, both previously parsed to nothing.
# Expectations from an ansible-core 2.19.4 run over an inventory that
# deliberately lists its hosts OUT of sorted order (h3, h1, h2), so
# "inventory" and "sorted" are distinguishable.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def hosts_in_order(keywords : String) : Array(String)
  dir = File.tempname("order")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"),
    "[g]\nh3 ansible_connection=local\nh1 ansible_connection=local\nh2 ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), <<-YAML)
    - hosts: all
      gather_facts: false
    #{keywords}
      tasks:
        - name: t
          ansible.builtin.debug: {msg: "H-{{ inventory_hostname }}"}
    YAML

  stdout_io = IO::Memory.new
  Process.run(BINARY, ["-i", "inv.ini", "pb.yml"], output: stdout_io, error: stdout_io, chdir: dir)
  stdout_io.to_s.scan(/^\s{2}H-(h\d)$/m).map { |mat| mat[1] }
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "order:" do
  # serial: 1 makes the sequence observable one host at a time.
  it "defaults to inventory order" do
    hosts_in_order("  serial: 1").should eq(["h3", "h1", "h2"])
    hosts_in_order("  order: inventory\n  serial: 1").should eq(["h3", "h1", "h2"])
  end

  it "sorts and reverse-sorts by name" do
    hosts_in_order("  order: sorted\n  serial: 1").should eq(["h1", "h2", "h3"])
    hosts_in_order("  order: reverse_sorted\n  serial: 1").should eq(["h3", "h2", "h1"])
  end

  # reverse_inventory is the inventory order REVERSED, not a sort - h2,
  # h1, h3 for an inventory of h3, h1, h2.
  it "reverses inventory order without sorting" do
    hosts_in_order("  order: reverse_inventory\n  serial: 1").should eq(["h2", "h1", "h3"])
  end

  it "ignores an unknown order rather than failing" do
    hosts_in_order("  order: nonsense\n  serial: 1").should eq(["h3", "h1", "h2"])
  end
end

describe "throttle:" do
  # throttle caps concurrency; it must not change which hosts run or the
  # order they are reported in.
  it "runs every host, in order, with throttle: 1" do
    dir = File.tempname("throttle")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "inv.ini"),
      "[g]\nh3 ansible_connection=local\nh1 ansible_connection=local\nh2 ansible_connection=local\n")
    File.write(File.join(dir, "pb.yml"), <<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "H-{{ inventory_hostname }}"}
            throttle: 1
      YAML

    begin
      stdout_io = IO::Memory.new
      status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
        output: stdout_io, error: stdout_io, chdir: dir)
      status.exit_code.should eq(0)
      stdout_io.to_s.scan(/^\s{2}H-(h\d)$/m).map { |mat| mat[1] }.should eq(["h3", "h1", "h2"])
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end
end
