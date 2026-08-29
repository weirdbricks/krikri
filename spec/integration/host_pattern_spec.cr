require "file_utils"
require "../spec_helper"

# Real Ansible's host-pattern language, in both `hosts:` and `--limit`.
# Every expectation was taken from an ansible-core 2.19.4 run of the same
# inventory. Before this, only a bare group/host/glob was understood:
# `prod` (a :children group), `web:db`, `!web`, `prod:!db` and `web:&prod`
# each matched NOTHING - and a pattern matching no hosts silently skips
# the play rather than erroring, so a play aimed at a parent group just
# quietly did nothing.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")

private INVENTORY = <<-INI
  [web]
  web1 ansible_connection=local
  web2 ansible_connection=local
  [db]
  db1 ansible_connection=local
  [prod:children]
  web
  db
  INI

# Runs a play against *pattern* and returns the hosts that actually ran.
private def hosts_for(pattern : String, limit : String? = nil) : Array(String)
  dir = File.tempname("host-pattern")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), INVENTORY)
  File.write(File.join(dir, "pb.yml"), <<-YAML)
    - hosts: "#{pattern}"
      gather_facts: false
      tasks:
        - name: t
          ansible.builtin.debug: {msg: "H={{ inventory_hostname }}"}
    YAML

  args = ["-i", "inv.ini"]
  args.concat(["-l", limit]) if limit
  stdout_io = IO::Memory.new
  Process.run(BINARY, args + ["pb.yml"], output: stdout_io, error: stdout_io, chdir: dir)
  stdout_io.to_s.scan(/H=([a-z0-9]+)/).map { |mat| mat[1] }.sort!
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "host patterns" do
  it "resolves a :children group transitively" do
    hosts_for("prod").should eq(["db1", "web1", "web2"])
  end

  it "unions terms separated by a colon" do
    hosts_for("web:db").should eq(["db1", "web1", "web2"])
  end

  it "unions terms separated by a comma" do
    hosts_for("web,db").should eq(["db1", "web1", "web2"])
  end

  # A leading ! is relative to every host: "all except web".
  it "treats a leading exclusion as all-except" do
    hosts_for("!web").should eq(["db1"])
  end

  it "excludes a term from a union" do
    hosts_for("prod:!db").should eq(["web1", "web2"])
  end

  it "intersects with &" do
    hosts_for("web:&prod").should eq(["web1", "web2"])
  end

  it "still supports a bare group, host, glob and all" do
    hosts_for("web").should eq(["web1", "web2"])
    hosts_for("web1").should eq(["web1"])
    hosts_for("web*").should eq(["web1", "web2"])
    hosts_for("all").should eq(["db1", "web1", "web2"])
  end

  it "matches nothing for an unknown pattern" do
    hosts_for("nosuchgroup").empty?.should be_true
  end
end

describe "--limit patterns" do
  it "applies the same language as hosts:" do
    hosts_for("all", limit: "prod").should eq(["db1", "web1", "web2"])
    hosts_for("all", limit: "web:db").should eq(["db1", "web1", "web2"])
    hosts_for("all", limit: "!web").should eq(["db1"])
    hosts_for("all", limit: "prod:!db").should eq(["web1", "web2"])
    hosts_for("all", limit: "web:&prod").should eq(["web1", "web2"])
  end
end
