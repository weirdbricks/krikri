require "file_utils"
require "../minitest_helper"

# Ansible's host-pattern language, in both `hosts:` and `--limit`.
# Every expectation was taken from an ansible-core 2.19.4 run of the same
# inventory. Before this, only a bare group/host/glob was understood:
# `prod` (a :children group), `web:db`, `!web`, `prod:!db` and `web:&prod`
# each matched NOTHING - and a pattern matching no hosts silently skips
# the play rather than erroring, so a play aimed at a parent group just
# quietly did nothing.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

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
  run_output(pattern, limit).scan(/H=([a-z0-9]+)/).map { |mat| mat[1] }.sort!
end

# The same run, keeping everything it printed (stdout and stderr merged).
private def run_output(pattern : String, limit : String? = nil) : String
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
  stdout_io.to_s
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "host patterns" do
  it "resolves a :children group transitively" do
    hosts_for("prod").must_equal(["db1", "web1", "web2"])
  end

  it "unions terms separated by a colon" do
    hosts_for("web:db").must_equal(["db1", "web1", "web2"])
  end

  it "unions terms separated by a comma" do
    hosts_for("web,db").must_equal(["db1", "web1", "web2"])
  end

  # A leading ! is relative to every host: "all except web".
  it "treats a leading exclusion as all-except" do
    hosts_for("!web").must_equal(["db1"])
  end

  it "excludes a term from a union" do
    hosts_for("prod:!db").must_equal(["web1", "web2"])
  end

  it "intersects with &" do
    hosts_for("web:&prod").must_equal(["web1", "web2"])
  end

  it "still supports a bare group, host, glob and all" do
    hosts_for("web").must_equal(["web1", "web2"])
    hosts_for("web1").must_equal(["web1"])
    hosts_for("web*").must_equal(["web1", "web2"])
    hosts_for("all").must_equal(["db1", "web1", "web2"])
  end

  it "matches nothing for an unknown pattern" do
    hosts_for("nosuchgroup").empty?.must_equal(true)
  end

  # And warns about it by name (live-verified vs ansible-core 2.21.6). The
  # sigil is stripped before matching, so a negated term reports its bare
  # group name - that warning is what makes a typo like `!oo2` for `!oo_2`
  # visible instead of silently selecting too many hosts (issue #1464).
  it "warns about an unknown pattern named in hosts:" do
    run_output("nosuchgroup").must_include(
      "[WARNING]: Could not match supplied host pattern, ignoring: nosuchgroup")
  end

  it "warns about a negated or intersected hosts: term and reports its bare name" do
    output = run_output("all:!nosuch:&alsonosuch")
    output.must_include("[WARNING]: Could not match supplied host pattern, ignoring: nosuch")
    output.must_include("[WARNING]: Could not match supplied host pattern, ignoring: alsonosuch")
    output.wont_include("ignoring: !nosuch")
    output.wont_include("ignoring: &alsonosuch")
  end

  # Ansible's order_patterns visits regular, then `&`, then `!` terms, so
  # the warnings follow that order rather than the written one.
  it "orders the warnings regular, then &, then !" do
    output = run_output("all:!nosuch:&alsonosuch")
    intersection_at = output.index("ignoring: alsonosuch").as(Int32)
    exclusion_at = output.index("ignoring: nosuch").as(Int32)
    (intersection_at < exclusion_at).must_equal(true)
  end
end

describe "--limit patterns" do
  it "applies the same language as hosts:" do
    hosts_for("all", limit: "prod").must_equal(["db1", "web1", "web2"])
    hosts_for("all", limit: "web:db").must_equal(["db1", "web1", "web2"])
    hosts_for("all", limit: "!web").must_equal(["db1"])
    hosts_for("all", limit: "prod:!db").must_equal(["web1", "web2"])
    hosts_for("all", limit: "web:&prod").must_equal(["web1", "web2"])
  end

  # The implicit Gathering Facts task uploads the facts plugin before any
  # task runs, and that eager pass walked the play's whole `hosts:` pattern
  # - so an out-of-limit host was still contacted, appeared in the recap as
  # unreachable=1 and made the exit code non-zero. ansible-playbook only
  # ever connects to the limited host (live-verified vs ansible-core
  # 2.21.6, issue #1411).
  it "does not contact out-of-limit hosts while gathering facts" do
    dir = File.tempname("limit-facts")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "inv.ini"), <<-INI)
      inlimit ansible_connection=local
      outlimit ansible_host=127.0.0.1 ansible_port=1
      INI
    File.write(File.join(dir, "pb.yml"), <<-YAML)
      - hosts: all
        tasks:
          - ansible.builtin.debug: {msg: "H={{ inventory_hostname }}"}
      YAML

    stdout_io = IO::Memory.new
    status = Process.run(BINARY, ["-i", "inv.ini", "--limit", "inlimit", "pb.yml"],
      output: stdout_io, error: stdout_io, chdir: dir)
    output = stdout_io.to_s
    output.includes?("outlimit").must_equal(false)
    status.success?.must_equal(true)
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  # The issue #1464 report: a negated limit term naming a group that does
  # not exist warned nothing, so a typo silently limited less than
  # intended. ansible-core strips the sigil and warns with the bare name
  # (live-verified vs 2.21.6), while still running on the hosts the rest
  # of the limit selects.
  it "warns about a negated limit term that matches nothing, by bare name" do
    output = run_output("all", limit: "web1:!nosuch")
    output.must_include("[WARNING]: Could not match supplied host pattern, ignoring: nosuch")
    output.wont_include("ignoring: !nosuch")
    hosts_for("all", limit: "web1:!nosuch").must_equal(["web1"])
  end

  it "warns about an intersected limit term that matches nothing" do
    run_output("all", limit: "web:&nosuch").must_include(
      "[WARNING]: Could not match supplied host pattern, ignoring: nosuch")
  end

  # A limit term that resolves to a real group/host stays silent, sigil or
  # not - the warning is only for terms that match nothing at all.
  it "stays silent for negated limit terms that do match" do
    run_output("all", limit: "web1:!db").wont_include("Could not match supplied host pattern")
  end
end
