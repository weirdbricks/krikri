require "../minitest_helper"
require "file_utils"

# The three inventory SOURCE shapes Ansible accepts beyond a single
# file: a directory of sources, a comma-separated host list, and no
# usable inventory at all (implicit localhost). All differentialed
# against ansible-core 2.19.4.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

# The classic suite built this directory-of-sources tree once in
# before_suite under a shared spec/tmp root; the minitest suite rebuilds
# it per test under that test's own tmp_path subtree.
private def inv_dir : String
  dir = PluginSpecHelper.tmp_path("inventory_sources", "dir")
  FileUtils.mkdir_p(dir)

  File.write(File.join(dir, "01-web.ini"), <<-INI)
    [web]
    web1 ansible_connection=local
    web2 ansible_connection=local

    [web:vars]
    role_var=fromweb
    INI

  File.write(File.join(dir, "02-db.ini"), <<-INI)
    [db]
    db1 ansible_connection=local

    [all:vars]
    shared=shared_value
    INI

  File.write(File.join(dir, "03-extra.yml"), <<-YAML)
    all:
      children:
        cache:
          hosts:
            cache1:
              ansible_connection: local
    YAML

  # Must be ignored: an editor backup, and a hidden file.
  File.write(File.join(dir, "04-old.ini~"), "[ignored]\nghost1\n")
  File.write(File.join(dir, ".hidden.ini"), "[hidden]\nghost2\n")
  File.write(File.join(dir, "notes.md"), "[docs]\nghost3\n")
  dir
end

private def run_playbook(yaml : String, args : Array(String))
  playbook = File.tempname("inventory-sources", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, args + [playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private REPORT = <<-YAML
  - hosts: all
    gather_facts: false
    tasks:
      - name: report
        ansible.builtin.debug:
          msg: "HOST=[{{ inventory_hostname }}] GROUPS=[{{ group_names | sort | join(',') }}] SHARED=[{{ shared | default('-') }}] ROLE=[{{ role_var | default('-') }}]"
  YAML

describe "inventory sources" do
  it "merges every source in an inventory directory" do
    status, output = run_playbook(REPORT, ["-i", inv_dir])

    status.exit_code.must_equal(0)
    output.must_include("HOST=[web1] GROUPS=[web]")
    output.must_include("HOST=[web2] GROUPS=[web]")
    output.must_include("HOST=[db1] GROUPS=[db]")
    # From the YAML source in the same directory, alongside the two INI ones.
    output.must_include("HOST=[cache1] GROUPS=[cache]")
  end

  # An [all:vars] block in one file has to reach hosts defined in
  # another - each file's own parse only ever sees its own hosts.
  it "applies group vars across file boundaries" do
    _, output = run_playbook(REPORT, ["-i", inv_dir])

    output.scan(/SHARED=\[shared_value\]/).size.must_equal(4)
    # A group's own vars still reach only that group.
    output.must_include("HOST=[web1] GROUPS=[web] SHARED=[shared_value] ROLE=[fromweb]")
    output.must_include("HOST=[db1] GROUPS=[db] SHARED=[shared_value] ROLE=[-]")
  end

  it "skips backup, hidden and ignored-extension files in the directory" do
    _, output = run_playbook(REPORT, ["-i", inv_dir])

    output.wont_include("ghost1")
    output.wont_include("ghost2")
    output.wont_include("ghost3")
  end

  it "accepts a comma-separated host list" do
    status, output = run_playbook(REPORT, ["-i", "alpha,beta,"])

    status.exit_code.must_equal(0)
    output.must_include("HOST=[alpha]")
    output.must_include("HOST=[beta]")
  end

  it "expands ranges inside a host list" do
    _, output = run_playbook(REPORT, ["-i", "web[01:03],"])

    output.must_include("HOST=[web01]")
    output.must_include("HOST=[web02]")
    output.must_include("HOST=[web03]")
  end

  # Ansible does not abort for an unusable inventory
  # (INVENTORY_UNPARSED_IS_FAILED is false): it warns and leaves the
  # implicit localhost as the only reachable host.
  it "runs a localhost play with no inventory at all" do
    status, output = run_playbook(<<-YAML, [] of String)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: report
            ansible.builtin.debug:
              msg: "RAN=[{{ inventory_hostname }}]"
      YAML

    status.exit_code.must_equal(0)
    output.must_include("RAN=[localhost]")
    output.must_include("No inventory was parsed, only implicit localhost is available")
  end

  it "warns and continues when the named inventory source cannot be read" do
    status, output = run_playbook(<<-YAML, ["-i", "/nonexistent/hosts.ini"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: report
            ansible.builtin.debug:
              msg: "RAN=[{{ inventory_hostname }}]"
      YAML

    status.exit_code.must_equal(0)
    output.must_include("Unable to parse /nonexistent/hosts.ini as an inventory source")
    output.must_include("RAN=[localhost]")
  end

  # The implicit localhost deliberately does not match 'all' - real
  # Ansible skips the play and exits 0.
  it "matches no hosts for `hosts: all` with an empty inventory" do
    status, output = run_playbook(<<-YAML, [] of String)
      - hosts: all
        gather_facts: false
        tasks:
          - name: report
            ansible.builtin.debug:
              msg: "SHOULD-NOT-RUN"
      YAML

    status.exit_code.must_equal(0)
    output.wont_include("SHOULD-NOT-RUN")
  end

  # Ansible reports ["ungrouped"] for a host that belongs to no
  # other group - genuine membership, unlike "all", which is always
  # excluded.
  it "reports ungrouped in group_names for a host with no group of its own" do
    inventory = PluginSpecHelper.tmp_path("bare.ini")
    File.write(inventory, "bare1 ansible_connection=local\n")

    _, output = run_playbook(REPORT, ["-i", inventory])
    output.must_include("HOST=[bare1] GROUPS=[ungrouped]")
  end

  it "applies an [all:vars] block to every host of a single INI file" do
    inventory = PluginSpecHelper.tmp_path("single.ini")
    File.write(inventory, <<-INI)
      [web]
      only1 ansible_connection=local

      [all:vars]
      shared=shared_value
      INI

    _, output = run_playbook(REPORT, ["-i", inventory])
    output.must_include("HOST=[only1] GROUPS=[web] SHARED=[shared_value]")
  end
end
