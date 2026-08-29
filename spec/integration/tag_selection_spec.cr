require "../spec_helper"

# Real Ansible's --tags/--skip-tags selection. Every expectation here was
# captured from a real ansible-core 2.19.4 run of the same playbook.
#
# The previous implementation was a single intersection test applied only
# when --tags was passed, and only to top-level tasks. Five things were
# wrong: `never` ignored (so guarded tasks RAN by default), `always`
# ignored, `all`/`tagged`/`untagged` treated as literal names, block tags
# not inherited by children (and children never filtered), and no
# --skip-tags at all.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private FLAT_PLAYBOOK = <<-YAML
  - hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - name: tagged-a
        ansible.builtin.debug: {msg: "A"}
        tags: [alpha]
      - name: tagged-b
        ansible.builtin.debug: {msg: "B"}
        tags: [beta]
      - name: untagged
        ansible.builtin.debug: {msg: "U"}
      - name: always-task
        ansible.builtin.debug: {msg: "ALW"}
        tags: [always]
      - name: never-task
        ansible.builtin.debug: {msg: "NEV"}
        tags: [never, special]
  YAML

private BLOCK_PLAYBOOK = <<-YAML
  - hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - name: blk
        tags: [outer]
        block:
          - name: inner-alpha
            ansible.builtin.debug: {msg: "IA"}
            tags: [alpha]
          - name: inner-plain
            ansible.builtin.debug: {msg: "IP"}
      - name: top-beta
        ansible.builtin.debug: {msg: "TB"}
        tags: [beta]
  YAML

# Returns the msg markers that actually ran, in order.
private def ran_markers(yaml : String, args : Array(String)) : Array(String)
  playbook = File.tempname("tag-selection", ".yml")
  File.write(playbook, yaml)
  stdout_io = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY] + args + [playbook], output: stdout_io, error: stdout_io)
  stdout_io.to_s.scan(/^\s{2}([A-Z]+)$/m).map { |mat| mat[1] }
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "tag selection" do
  # `tags: never` is how a playbook author guards a destructive or
  # manual-only task. It ran on an ordinary invocation before this fix.
  it "excludes a never-tagged task on a plain run" do
    ran_markers(FLAT_PLAYBOOK, [] of String).should eq(["A", "B", "U", "ALW"])
  end

  it "runs an always-tagged task even under an unrelated --tags" do
    ran_markers(FLAT_PLAYBOOK, ["--tags", "alpha"]).should eq(["A", "ALW"])
  end

  it "treats --tags all as everything except never" do
    ran_markers(FLAT_PLAYBOOK, ["--tags", "all"]).should eq(["A", "B", "U", "ALW"])
  end

  it "treats --tags tagged as every task carrying a tag" do
    ran_markers(FLAT_PLAYBOOK, ["--tags", "tagged"]).should eq(["A", "B", "ALW"])
  end

  it "treats --tags untagged as every task carrying no tag" do
    ran_markers(FLAT_PLAYBOOK, ["--tags", "untagged"]).should eq(["U", "ALW"])
  end

  # A never-tagged task DOES run when one of its own tags is named.
  it "runs a never-tagged task when another of its tags is requested" do
    ran_markers(FLAT_PLAYBOOK, ["--tags", "special"]).should eq(["ALW", "NEV"])
  end

  it "runs a never-tagged task when 'never' itself is requested" do
    ran_markers(FLAT_PLAYBOOK, ["--tags", "never"]).should eq(["ALW", "NEV"])
  end

  it "supports --skip-tags" do
    ran_markers(FLAT_PLAYBOOK, ["--skip-tags", "alpha"]).should eq(["B", "U", "ALW"])
  end

  # --skip-tags wins over always, matching real Ansible.
  it "lets --skip-tags always drop an always-tagged task" do
    ran_markers(FLAT_PLAYBOOK, ["--skip-tags", "always"]).should eq(["A", "B", "U"])
  end

  it "combines --tags and --skip-tags" do
    ran_markers(FLAT_PLAYBOOK, ["--tags", "all", "--skip-tags", "beta"]).should eq(["A", "U", "ALW"])
  end

  # A block's tags are inherited by its children, and the children are
  # filtered individually - not kept or dropped as one atomic unit.
  it "selects a tagged task nested inside an untagged-for-that-tag block" do
    ran_markers(BLOCK_PLAYBOOK, ["--tags", "alpha"]).should eq(["IA"])
  end

  it "selects every child of a block matched by the block's own tag" do
    ran_markers(BLOCK_PLAYBOOK, ["--tags", "outer"]).should eq(["IA", "IP"])
  end

  it "skips a whole block by its inherited tag" do
    ran_markers(BLOCK_PLAYBOOK, ["--skip-tags", "outer"]).should eq(["TB"])
  end

  it "leaves an unfiltered run untouched" do
    ran_markers(BLOCK_PLAYBOOK, [] of String).should eq(["IA", "IP", "TB"])
  end
end
