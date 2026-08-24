require "file_utils"
require "../spec_helper"

# Inventory host ranges, and the group-related magic variables. All
# expectations taken from an ansible-core 2.19.4 run of the same
# inventory.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")

private def run_inventory(inventory : String, playbook : String, extra : Hash(String, String)? = nil) : String
  dir = File.tempname("inv-range")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), inventory)
  File.write(File.join(dir, "pb.yml"), playbook)
  extra.try &.each do |path, body|
    full = File.join(dir, path)
    Dir.mkdir_p(File.dirname(full))
    File.write(full, body)
  end

  stdout_io = IO::Memory.new
  Process.run(BINARY, ["-i", "inv.ini", "pb.yml"], output: stdout_io, error: stdout_io, chdir: dir)
  stdout_io.to_s
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

private SHOW_HOST = <<-YAML
  - hosts: all
    gather_facts: false
    tasks:
      - name: t
        ansible.builtin.debug: {msg: "H={{ inventory_hostname }}"}
  YAML

describe "inventory host ranges" do
  # Previously the whole entry was one literal hostname, so an inventory
  # written the ordinary way defined a host actually NAMED "web[01:03]"
  # and every real host in it was invisible.
  it "expands a zero-padded numeric range, keeping the padding" do
    out = run_inventory("[g]\nweb[01:03] ansible_connection=local\n", SHOW_HOST)
    out.scan(/H=(\S+)/).map { |m| m[1] }.sort.should eq(["web01", "web02", "web03"])
  end

  it "expands an unpadded numeric range" do
    out = run_inventory("[g]\nn[1:3] ansible_connection=local\n", SHOW_HOST)
    out.scan(/H=(\S+)/).map { |m| m[1] }.sort.should eq(["n1", "n2", "n3"])
  end

  it "expands an alphabetic range" do
    out = run_inventory("[g]\nh[a:c] ansible_connection=local\n", SHOW_HOST)
    out.scan(/H=(\S+)/).map { |m| m[1] }.sort.should eq(["ha", "hb", "hc"])
  end

  it "honors a step" do
    out = run_inventory("[g]\nx[01:10:3] ansible_connection=local\n", SHOW_HOST)
    out.scan(/H=(\S+)/).map { |m| m[1] }.sort.should eq(["x01", "x04", "x07", "x10"])
  end

  it "keeps text on both sides of the range" do
    out = run_inventory("[g]\nsrv[1:2].ex.com ansible_connection=local\n", SHOW_HOST)
    out.scan(/H=(\S+)/).map { |m| m[1] }.sort.should eq(["srv1.ex.com", "srv2.ex.com"])
  end

  it "leaves a plain hostname alone" do
    out = run_inventory("[g]\nplain1 ansible_connection=local\n", SHOW_HOST)
    out.scan(/H=(\S+)/).map { |m| m[1] }.should eq(["plain1"])
  end
end

private NESTED_INVENTORY = <<-INI
  [web]
  web1 ansible_connection=local
  [db]
  db1 ansible_connection=local
  [prod:children]
  web
  db
  INI

describe "group magic variables" do
  # Both were missing: inventory_hostname_short RAISED as undefined, and
  # group_names rendered empty.
  it "provides inventory_hostname_short and a sorted group_names" do
    out = run_inventory(NESTED_INVENTORY, <<-YAML)
      - hosts: web
        gather_facts: false
        tasks:
          - name: t
            ansible.builtin.debug:
              msg: "short={{ inventory_hostname_short }} groups={{ group_names | join('+') }}"
      YAML

    out.should contain("short=web1")
    out.should contain("groups=prod+web")
  end

  it "strips the domain for inventory_hostname_short" do
    out = run_inventory("[g]\nsrv1.ex.com ansible_connection=local\n", <<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: t
            ansible.builtin.debug: {msg: "short={{ inventory_hostname_short }}"}
      YAML

    out.should contain("short=srv1")
  end

  # groups[...] had the same parent-group bug as host resolution: a
  # :children group reported an empty host list.
  it "resolves a parent group in the groups magic var" do
    out = run_inventory(NESTED_INVENTORY, <<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: t
            run_once: true
            ansible.builtin.debug:
              msg: "prod={{ groups['prod'] | sort | join('+') }}"
      YAML

    out.should contain("prod=db1+web1")
  end
end
