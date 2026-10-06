require "../minitest_helper"

# Ansible's --tags/--skip-tags selection. Every expectation here was
# captured from a ansible-core 2.19.4 run of the same playbook.
#
# The previous implementation was a single intersection test applied only
# when --tags was passed, and only to top-level tasks. Five things were
# wrong: `never` ignored (so guarded tasks RAN by default), `always`
# ignored, `all`/`tagged`/`untagged` treated as literal names, block tags
# not inherited by children (and children never filtered), and no
# --skip-tags at all.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

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
  stdout_io.to_s.scan(/^\s{4}"msg": "([A-Z]+)"$/m).map { |mat| mat[1] }
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "tag selection" do
  # `tags: never` is how a playbook author guards a destructive or
  # manual-only task. It ran on an ordinary invocation before this fix.
  it "excludes a never-tagged task on a plain run" do
    ran_markers(FLAT_PLAYBOOK, [] of String).must_equal(["A", "B", "U", "ALW"])
  end

  it "runs an always-tagged task even under an unrelated --tags" do
    ran_markers(FLAT_PLAYBOOK, ["--tags", "alpha"]).must_equal(["A", "ALW"])
  end

  it "treats --tags all as everything except never" do
    ran_markers(FLAT_PLAYBOOK, ["--tags", "all"]).must_equal(["A", "B", "U", "ALW"])
  end

  it "treats --tags tagged as every task carrying a tag" do
    ran_markers(FLAT_PLAYBOOK, ["--tags", "tagged"]).must_equal(["A", "B", "ALW"])
  end

  it "treats --tags untagged as every task carrying no tag" do
    ran_markers(FLAT_PLAYBOOK, ["--tags", "untagged"]).must_equal(["U", "ALW"])
  end

  # A never-tagged task DOES run when one of its own tags is named.
  it "runs a never-tagged task when another of its tags is requested" do
    ran_markers(FLAT_PLAYBOOK, ["--tags", "special"]).must_equal(["ALW", "NEV"])
  end

  it "runs a never-tagged task when 'never' itself is requested" do
    ran_markers(FLAT_PLAYBOOK, ["--tags", "never"]).must_equal(["ALW", "NEV"])
  end

  it "supports --skip-tags" do
    ran_markers(FLAT_PLAYBOOK, ["--skip-tags", "alpha"]).must_equal(["B", "U", "ALW"])
  end

  # --skip-tags wins over always, matching Ansible.
  it "lets --skip-tags always drop an always-tagged task" do
    ran_markers(FLAT_PLAYBOOK, ["--skip-tags", "always"]).must_equal(["A", "B", "U"])
  end

  it "combines --tags and --skip-tags" do
    ran_markers(FLAT_PLAYBOOK, ["--tags", "all", "--skip-tags", "beta"]).must_equal(["A", "U", "ALW"])
  end

  # A block's tags are inherited by its children, and the children are
  # filtered individually - not kept or dropped as one atomic unit.
  it "selects a tagged task nested inside an untagged-for-that-tag block" do
    ran_markers(BLOCK_PLAYBOOK, ["--tags", "alpha"]).must_equal(["IA"])
  end

  it "selects every child of a block matched by the block's own tag" do
    ran_markers(BLOCK_PLAYBOOK, ["--tags", "outer"]).must_equal(["IA", "IP"])
  end

  it "skips a whole block by its inherited tag" do
    ran_markers(BLOCK_PLAYBOOK, ["--skip-tags", "outer"]).must_equal(["TB"])
  end

  it "leaves an unfiltered run untouched" do
    ran_markers(BLOCK_PLAYBOOK, [] of String).must_equal(["IA", "IP", "TB"])
  end
end

# Tag selection over tasks that only exist at RUN time - everything an
# include_tasks:/include_role:/import_role: pulls in. Ansible applies the
# same --tags/--skip-tags/never rules to those tasks as to the play's own
# list; krikri used to filter only the play list, so a `never` task in an
# included file ran on a plain invocation (round 1600000, stafwag.libvirt).
# Every expectation below was captured from ansible-core 2.19.11 running
# the identical fixture.
private RUNTIME_INC = <<-YAML
  - name: inc-untagged
    ansible.builtin.debug: {msg: "U"}
  - name: inc-debug
    ansible.builtin.debug: {msg: "D"}
    tags: [alpha]
  - name: inc-always
    ansible.builtin.debug: {msg: "A"}
    tags: [always]
  - name: inc-never
    ansible.builtin.debug: {msg: "N"}
    tags: [never]
  YAML

private RUNTIME_FILES = {
  "inc.yml"                    => RUNTIME_INC,
  "roles/mrole/tasks/main.yml" => RUNTIME_INC,
  "p_inc.yml"                  => <<-YAML,
  - hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - name: do include
        ansible.builtin.include_tasks: inc.yml
  YAML
  "p_inc_directivetags.yml" => <<-YAML,
  - hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - name: do include
        ansible.builtin.include_tasks: inc.yml
        tags: [alpha]
  YAML
  "p_inc_applytags.yml" => <<-YAML,
  - hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - name: do include
        ansible.builtin.include_tasks:
          file: inc.yml
          apply:
            tags: [applied]
  YAML
  "p_inc_loop.yml" => <<-YAML,
  - hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - name: do include loop
        ansible.builtin.include_tasks: "{{ item }}"
        loop:
          - inc.yml
          - inc.yml
  YAML
  "p_importrole.yml" => <<-YAML,
  - hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - name: do import
        ansible.builtin.import_role:
          name: mrole
  YAML
  "p_includerole_directivetags.yml" => <<-YAML,
    - hosts: localhost
      connection: local
      gather_facts: false
      tasks:
        - name: do include role
          ansible.builtin.include_role:
            name: mrole
          tags: [alpha]
    YAML
  "p_roles_entrytags.yml" => <<-YAML
  - hosts: localhost
    connection: local
    gather_facts: false
    roles:
      - role: mrole
        tags: [rtag]
  YAML
}

# Writes the fixture set into one scratch dir (role lookup and include
# resolution both key off the playbook's own directory), runs the binary,
# and returns the msg markers that actually ran, in order.
private def ran_markers_runtime(playbook : String, args : Array(String)) : Array(String)
  dir = PluginSpecHelper.tmp_path("tag-runtime-#{Random::Secure.hex(4)}")
  RUNTIME_FILES.each do |rel, content|
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  stdout_io = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY] + args + [File.join(dir, playbook)], output: stdout_io, error: stdout_io)
  stdout_io.to_s.scan(/^\s{4}"msg": "([A-Z]+)"$/m).map { |mat| mat[1] }
end

describe "tag selection for runtime-loaded tasks" do
  it "excludes a never-tagged task from a plain include_tasks run" do
    ran_markers_runtime("p_inc.yml", [] of String).must_equal(["U", "D", "A"])
  end

  it "drops the whole include when its untagged statement misses --tags" do
    ran_markers_runtime("p_inc.yml", ["--tags", "alpha"]).must_equal([] of String)
  end

  it "applies --skip-tags to tasks loaded by include_tasks" do
    ran_markers_runtime("p_inc.yml", ["--skip-tags", "alpha"]).must_equal(["U", "A"])
  end

  it "applies --tags untagged to tasks loaded by include_tasks" do
    ran_markers_runtime("p_inc.yml", ["--tags", "untagged"]).must_equal(["U", "A"])
  end

  # The include statement's OWN tags belong to the statement: they decide
  # whether the include runs, but they are NOT handed to the loaded tasks
  # (they only match here because inc-debug carries `alpha` itself).
  it "does not push an include directive's own tags onto its children" do
    ran_markers_runtime("p_inc_directivetags.yml", ["--tags", "alpha"]).must_equal(["D", "A"])
  end

  it "still runs every non-never child of a directive-tagged include" do
    ran_markers_runtime("p_inc_directivetags.yml", [] of String).must_equal(["U", "D", "A"])
  end

  # `apply: {tags:}` DOES reach the loaded tasks - they inherit it like an
  # enclosing block's tags, so an "untagged" selection no longer sees an
  # apply-tagged task as untagged.
  it "inherits apply: tags into the loaded tasks for --tags untagged" do
    ran_markers_runtime("p_inc_applytags.yml", ["--tags", "untagged"]).must_equal(["A"])
  end

  it "skips every apply-tagged task under --skip-tags" do
    ran_markers_runtime("p_inc_applytags.yml", ["--skip-tags", "applied"]).must_equal([] of String)
  end

  it "filters each iteration of a looped include_tasks" do
    ran_markers_runtime("p_inc_loop.yml", [] of String).must_equal(["U", "D", "A", "U", "D", "A"])
  end

  it "applies --skip-tags to every looped include iteration" do
    ran_markers_runtime("p_inc_loop.yml", ["--skip-tags", "alpha"]).must_equal(["U", "A", "U", "A"])
  end

  # import_role: is STATIC - its statement must never gate the role (an
  # untagged statement under --tags alpha used to drop the entire role),
  # and the loaded tasks are selected individually.
  it "excludes a never-tagged role task from a plain import_role run" do
    ran_markers_runtime("p_importrole.yml", [] of String).must_equal(["U", "D", "A"])
  end

  it "selects inside an import_role by each task's own tags" do
    ran_markers_runtime("p_importrole.yml", ["--tags", "alpha"]).must_equal(["D", "A"])
  end

  it "lets --tags never reach tasks loaded by import_role" do
    ran_markers_runtime("p_importrole.yml", ["--tags", "never"]).must_equal(["A", "N"])
  end

  # include_role: is DYNAMIC: its statement's tags gate the statement and
  # are not given to the role's tasks.
  it "does not push an include_role directive's own tags onto its tasks" do
    ran_markers_runtime("p_includerole_directivetags.yml", ["--tags", "alpha"]).must_equal(["D", "A"])
  end

  # A roles: entry's tags are a block-level push: everything the role
  # loads - including tasks a nested include brings in - inherits them.
  it "gives a roles: entry's tags to the role's tasks" do
    ran_markers_runtime("p_roles_entrytags.yml", ["--tags", "rtag"]).must_equal(["U", "D", "A", "N"])
  end

  it "sees a roles: entry's tags when selecting --tags untagged" do
    ran_markers_runtime("p_roles_entrytags.yml", ["--tags", "untagged"]).must_equal(["A"])
  end
end
