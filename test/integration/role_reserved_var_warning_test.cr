require "../minitest_helper"
require "file_utils"

# ansible-core 2.19 warns for a reserved-name key at the top level of any
# vars-style file a role loads (defaults/main.yml, vars/main.yml, and the
# files of a defaults/main/ directory), at role load time - on stderr
# with an Origin block naming the key's own position (column 1 for a
# top-level key), BEFORE the "PLAY [..]" banner for a play-level role and
# at the include point for include_role (live-verified vs 2.19.11:
# defaults/main.yml line 2 `remote_user: root` prints exactly this, and
# an included role's defaults warn the same way at the include task).
# Once per file+key per run, no matter how often the loader re-reads or
# re-loads the same role.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "reserved variable name warning in role defaults/vars files" do
  it "warns for a play role's defaults/main.yml with the key's own Origin, before the PLAY banner" do
    src_dir = File.tempname("reserved-role-defaults")
    Dir.mkdir_p(File.join(src_dir, "roles", "r1", "defaults"))
    File.write(File.join(src_dir, "roles", "r1", "defaults", "main.yml"), "---\nremote_user: root\n")
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - r1
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)
    text = output.to_s

    text.must_include("[WARNING]: Found variable using reserved name 'remote_user'.")
    # A top-level key sits at column 1 - Origin names line 2 col 1 with
    # the source excerpt and caret, blank line after the block.
    text.must_include("Origin: #{File.join(src_dir, "roles", "r1", "defaults", "main.yml")}:2:1")
    text.must_include("2 remote_user: root")
    text.must_include("  ^ column 1")
    # ordering matters: stderr precedes the banner in the captured stream
    warn_at = text.index!("[WARNING]: Found variable using reserved name")
    play_at = text.index!("PLAY [")
    (warn_at < play_at).must_equal(true)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end

  it "warns for a play role's vars/main.yml too" do
    src_dir = File.tempname("reserved-role-vars")
    Dir.mkdir_p(File.join(src_dir, "roles", "r2", "vars"))
    File.write(File.join(src_dir, "roles", "r2", "vars", "main.yml"), "---\nlookup: x\n")
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - r2
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)
    text = output.to_s

    text.must_include("[WARNING]: Found variable using reserved name 'lookup'.")
    text.must_include("Origin: #{File.join(src_dir, "roles", "r2", "vars", "main.yml")}:2:1")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end

  it "warns once for an included role's defaults no matter how often it is loaded" do
    src_dir = File.tempname("reserved-role-include")
    Dir.mkdir_p(File.join(src_dir, "roles", "rdep", "defaults"))
    Dir.mkdir_p(File.join(src_dir, "roles", "rdep", "tasks"))
    File.write(File.join(src_dir, "roles", "rdep", "defaults", "main.yml"), "---\nname: x\n")
    File.write(File.join(src_dir, "roles", "rdep", "tasks", "main.yml"), "---\n- debug: msg=hi\n")
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - include_role: name=rdep
          - include_role: name=rdep
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)
    text = output.to_s

    text.scan("Found variable using reserved name").size.must_equal(1)
    text.must_include("Origin: #{File.join(src_dir, "roles", "rdep", "defaults", "main.yml")}:2:1")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end

  it "never warns for a role defaults/vars file with no reserved-name keys" do
    src_dir = File.tempname("reserved-role-clean")
    Dir.mkdir_p(File.join(src_dir, "roles", "r3", "defaults"))
    Dir.mkdir_p(File.join(src_dir, "roles", "r3", "vars"))
    File.write(File.join(src_dir, "roles", "r3", "defaults", "main.yml"), "---\nportnum: 80\n")
    File.write(File.join(src_dir, "roles", "r3", "vars", "main.yml"), "---\nsecret: x\n")
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - r3
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    refute(output.to_s.includes?("Found variable using reserved name"))
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end
end
