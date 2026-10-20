require "../minitest_helper"
require "file_utils"

# ansible-core 2.19 warns for a reserved-name key at the top level of a
# vars file loaded by include_vars, on stderr under the TASK header and
# before the task's own result line (live-verified vs 2.19.11: a
# two-line file whose line 2 is `vars_files:` prints exactly this).
# Same once-per-file+key dedup as every other reserved-name warning
# path, so re-including the same file in one run stays silent.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "reserved variable name warning in include_vars files" do
  it "warns with the key's own Origin for an include_vars vars file" do
    src_dir = File.tempname("include-vars-reserved")
    Dir.mkdir_p(src_dir)
    vf = File.join(src_dir, "vf.yml")
    File.write(vf, "---\nfoo: bar\nvars_files:\n  - other.yml\n")
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - include_vars: vf.yml
      YAML

    output = IO::Memory.new
    # One real pipe for both streams: with two pipes the drain order is racy and the stderr-before-result check flakes.
    Process.run("sh", ["-c", "exec \"$0\" \"$@\" 2>&1", BINARY, "-i", INVENTORY, playbook], output: output, input: IO::Memory.new, chdir: src_dir)
    text = output.to_s

    text.must_include("[WARNING]: Found variable using reserved name 'vars_files'.")
    # A top-level key sits at column 1 - Origin names line 3 col 1 with
    # the source excerpt and caret, blank line after the block.
    text.must_include("Origin: #{vf}:3:1")
    text.must_include("3 vars_files:")
    text.must_include("  ^ column 1")
    # The warning is emitted while the file loads, before the task's
    # own ok: line is printed.
    warn_at = text.index!("[WARNING]: Found variable using reserved name")
    ok_at = text.index!("ok: [localhost]")
    (warn_at < ok_at).must_equal(true)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end

  it "warns once per file+key no matter how often include_vars re-loads it" do
    src_dir = File.tempname("include-vars-reserved-dedup")
    Dir.mkdir_p(src_dir)
    vf = File.join(src_dir, "vf.yml")
    File.write(vf, "---\nvars_files: x\n")
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - include_vars: vf.yml
          - include_vars: vf.yml
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)
    text = output.to_s

    text.scan("Found variable using reserved name").size.must_equal(1)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end

  it "warns for each reserved-name file loaded by include_vars with dir:" do
    src_dir = File.tempname("include-vars-reserved-dir")
    Dir.mkdir_p(src_dir)
    Dir.mkdir_p(File.join(src_dir, "varsdir"))
    File.write(File.join(src_dir, "varsdir", "a.yml"), "---\nvars_files: x\n")
    File.write(File.join(src_dir, "varsdir", "b.yml"), "---\nname: y\n")
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - include_vars:
              dir: varsdir
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)
    text = output.to_s

    text.scan("Found variable using reserved name").size.must_equal(2)
    text.must_include("Origin: #{File.join(src_dir, "varsdir", "a.yml")}:2:1")
    text.must_include("Origin: #{File.join(src_dir, "varsdir", "b.yml")}:2:1")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end

  it "stays silent for an include_vars file with no reserved-name keys" do
    src_dir = File.tempname("include-vars-reserved-clean")
    Dir.mkdir_p(src_dir)
    vf = File.join(src_dir, "vf.yml")
    File.write(vf, "---\nfoo: bar\nportnum: 80\n")
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - include_vars: vf.yml
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    refute(output.to_s.includes?("Found variable using reserved name"))
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end
end
