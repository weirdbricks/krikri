require "../minitest_helper"
require "file_utils"

# ansible-core 2.19 warns for a reserved-name key at the top level of a
# file loaded through a play's vars_files:, at play-load time - on stderr
# with an Origin block naming the key's own position (column 1 for a
# top-level key), BEFORE the "PLAY [..]" banner (same wording and format
# as the role defaults/vars variant). Once per file+key per run no matter
# how often the file is re-loaded per host.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "reserved variable name warning in play vars_files" do
  it "warns for a literal vars_files entry with the key's own Origin, before the PLAY banner" do
    src_dir = File.tempname("reserved-vars-files")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "vf.yml"), "foo: bar\nvars_files:\n  - other.yml\n")
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars_files:
          - vf.yml
        tasks:
          - debug: msg=hi
      YAML

    output = IO::Memory.new
    # One real pipe for both streams: with two pipes the drain order is racy and the stderr-before-banner check flakes.
    Process.run("sh", ["-c", "exec \"$0\" \"$@\" 2>&1", BINARY, "-i", INVENTORY, playbook], output: output, input: IO::Memory.new, chdir: src_dir)
    text = output.to_s

    text.must_include("[WARNING]: Found variable using reserved name 'vars_files'.")
    # A top-level key sits at column 1 - Origin names line 2 col 1 with
    # the source excerpt and caret, blank line after the block.
    text.must_include("Origin: #{File.join(src_dir, "vf.yml")}:2:1")
    text.must_include("2 vars_files:")
    text.must_include("  ^ column 1")
    # ordering matters: stderr precedes the banner in the captured stream
    warn_at = text.index!("[WARNING]: Found variable using reserved name")
    play_at = text.index!("PLAY [")
    (warn_at < play_at).must_equal(true)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end

  it "warns once for a templated vars_files path resolved at runtime" do
    src_dir = File.tempname("reserved-vars-files-tmpl")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "vf2.yml"), "remote_user: root\n")
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars_files:
          - "{{ 'vf2' }}.yml"
        tasks:
          - debug: msg=hi
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)
    text = output.to_s

    text.scan("Found variable using reserved name").size.must_equal(1)
    text.must_include("[WARNING]: Found variable using reserved name 'remote_user'.")
    text.must_include("Origin: #{File.join(src_dir, "vf2.yml")}:1:1")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end

  it "stays silent for a vars_files file with no reserved-name keys" do
    src_dir = File.tempname("reserved-vars-files-clean")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "ok.yml"), "foo: bar\n")
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars_files:
          - ok.yml
        tasks:
          - debug: msg=hi
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    refute(output.to_s.includes?("Found variable using reserved name"))
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end
end
