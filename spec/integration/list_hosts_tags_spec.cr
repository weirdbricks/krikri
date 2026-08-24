require "file_utils"
require "../spec_helper"

# --list-hosts and --list-tags, matching real ansible-playbook's layout
# (captured from ansible-core 2.19.4).
#
# One DELIBERATE divergence, in --list-hosts: real Ansible emits the
# hosts of a multi-group pattern like `all` in a different order on every
# run (Python hash iteration - observed as web2,db1,web1 / web1,web2,db1
# / web2,web1,db1 across five consecutive runs of the same playbook), so
# there is no byte-order to match. This engine sorts them, which is
# deterministic and diffable.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")

private def run_listing(flag : String, inventory : String, yaml : String)
  dir = File.tempname("list-hosts-tags")
  Dir.mkdir_p(dir)
  inv = File.join(dir, "inv.ini")
  File.write(inv, inventory)
  playbook = File.join(dir, "pb.yml")
  File.write(playbook, yaml)

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", flag, "pb.yml"],
    output: stdout_io, error: stdout_io, chdir: dir)
  {status, stdout_io.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

private INVENTORY = <<-INI
  [web]
  web1 ansible_connection=local
  web2 ansible_connection=local
  [db]
  db1 ansible_connection=local
  INI

private PLAYBOOK = <<-YAML
  - name: Web play
    hosts: web
    gather_facts: false
    tasks:
      - name: t1
        ansible.builtin.debug: {msg: "x"}
        tags: [alpha, beta]
  - name: All play
    hosts: all
    gather_facts: false
    tasks:
      - name: t2
        ansible.builtin.debug: {msg: "y"}
        tags: [gamma]
      - name: t3
        ansible.builtin.debug: {msg: "z"}
  YAML

describe "--list-hosts" do
  it "lists each play's pattern and matched hosts" do
    status, output = run_listing("--list-hosts", INVENTORY, PLAYBOOK)
    status.exit_code.should eq(0)
    output.should eq(<<-OUT + "\n")

      playbook: pb.yml

        play #1 (web): Web play\tTAGS: []
          pattern: ['web']
          hosts (2):
            web1
            web2

        play #2 (all): All play\tTAGS: []
          pattern: ['all']
          hosts (3):
            db1
            web1
            web2
      OUT
  end

  it "runs no task and prints no banner" do
    _, output = run_listing("--list-hosts", INVENTORY, PLAYBOOK)
    output.should_not contain("PLAY RECAP")
    output.should_not contain("CRYSTAL PLAY")
    output.should_not contain("Inventory Warnings")
  end
end

describe "--list-tags" do
  it "lists the sorted union of each play's task tags" do
    status, output = run_listing("--list-tags", INVENTORY, PLAYBOOK)
    status.exit_code.should eq(0)
    output.should eq(<<-OUT + "\n")

      playbook: pb.yml

        play #1 (web): Web play\tTAGS: []
            TASK TAGS: [alpha, beta]

        play #2 (all): All play\tTAGS: []
            TASK TAGS: [gamma]
      OUT
  end

  # Block tags reach the listing through the same inheritance
  # --list-tasks uses.
  it "includes tags inherited from an enclosing block" do
    yaml = <<-YAML
      - name: Blocky
        hosts: all
        gather_facts: false
        tasks:
          - name: blk
            tags: [outer]
            block:
              - name: inner
                ansible.builtin.debug: {msg: "i"}
                tags: [inner]
      YAML

    _, output = run_listing("--list-tags", INVENTORY, yaml)
    output.should contain("TASK TAGS: [inner, outer]")
  end
end
