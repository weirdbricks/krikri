require "../minitest_helper"

# Issue #228 - when a loop's undefined ITEM fails, the "<<< caused by >>>"
# stanza's Origin must point at the FAILING list element: ansible
# templates the items in order and stops at the first failing one.
# Literal block lists (`loop:`/`with_items:` - loop_template_kind never
# marks those) used to print no Origin at all, and the block form pinned
# the first element regardless of which one failed (issue #88's
# single-element shape was only right then); a literal inline flow list
# pins the failing element's OPENING QUOTE. All live-verified against
# ansible-core 2.19.11.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(src_dir : String, yaml : String)
  File.write(File.join(src_dir, "pb.yml"), yaml)
  output = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: src_dir)
  output.to_s
end

describe "undefined loop item cause stanza origin" do
  it "pins a literal with_items block at the failing element, not the first" do
    src_dir = File.tempname("loop-undef-origin-block")
    Dir.mkdir_p(src_dir)
    text = run_playbook(src_dir, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Mixed defined first
            ansible.builtin.debug:
              msg: "{{ item }}"
            with_items:
              - "ok"
              - "{{ third_undefined }}"
      YAML

    playbook = File.expand_path(File.join(src_dir, "pb.yml"))
    text.must_include("[ERROR]: Task failed: 'third_undefined' is undefined")
    text.must_include("<<< caused by >>>")
    # "ok" is defined, so ansible fails on the second element: line 11,
    # its value token's column.
    text.must_include("Origin: #{playbook}:11:11")
    text.must_include("11         - \"{{ third_undefined }}\"\n             ^ column 11")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "pins a literal loop: block at the failing element, not the first" do
    src_dir = File.tempname("loop-undef-origin-loop")
    Dir.mkdir_p(src_dir)
    text = run_playbook(src_dir, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Block loop keyword
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop:
              - "ok"
              - "{{ loop_undefined }}"
      YAML

    playbook = File.expand_path(File.join(src_dir, "pb.yml"))
    text.must_include("[ERROR]: Task failed: 'loop_undefined' is undefined")
    text.must_include("Origin: #{playbook}:11:11")
    text.must_include("11         - \"{{ loop_undefined }}\"\n             ^ column 11")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "pins a literal inline flow list at the failing element's opening quote" do
    src_dir = File.tempname("loop-undef-origin-inline")
    Dir.mkdir_p(src_dir)
    text = run_playbook(src_dir, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Inline with_items
            ansible.builtin.debug:
              msg: "{{ item }}"
            with_items: ["ok", "{{ inline_undefined }}"]
      YAML

    playbook = File.expand_path(File.join(src_dir, "pb.yml"))
    text.must_include("[ERROR]: Task failed: 'inline_undefined' is undefined")
    # Real 2.19.11: the second element's quote, not the `[` starting the
    # list.
    text.must_include("Origin: #{playbook}:9:26")
    text.must_include("9       with_items: [\"ok\", \"{{ inline_undefined }}\"]\n                           ^ column 26")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "matches element names on word boundaries" do
    # The issue's defining repro: with an element already referencing the
    # LONGER name, the failing `group_git_cloning` element must win - and
    # vice versa a `group_git_cloning` failure must not match inside
    # `all_group_git_cloning` (both undefined; ansible stops at the first
    # failing element in source order).
    src_dir = File.tempname("loop-undef-origin-bounds")
    Dir.mkdir_p(src_dir)
    text = run_playbook(src_dir, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Clone git repos
            ansible.builtin.debug:
              msg: "{{ item.repo }}"
            with_items:
              - "{{ known_cloning }}"
              - "{{ group_git_cloning }}"
              - "{{ all_group_git_cloning }}"
            vars:
              known_cloning: []
      YAML

    playbook = File.expand_path(File.join(src_dir, "pb.yml"))
    text.must_include("[ERROR]: Task failed: 'group_git_cloning' is undefined")
    # The second element (line 11), not `all_group_git_cloning` (line 12).
    text.must_include("Origin: #{playbook}:11:11")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
