require "../minitest_helper"

# Issue #228 - when a loop's undefined ITEM fails, the "<<< caused by >>>"
# stanza's Origin must point at the FAILING list element: ansible
# templates the items in order and stops at the first failing one.
# Literal block lists (`loop:`/`with_items:` - loop_template_kind never
# marks those) used to print no Origin at all, and the block form pinned
# the first element regardless of which one failed (issue #88's
# single-element shape was only right then); a literal inline flow list
# pins the failing element's OPENING QUOTE. Block-mapping elements
# (`- key: value` spanning lines) pin the failing inner value token
# itself (issue #314). All live-verified against ansible-core 2.19.11.
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

  it "pins a block-list flow-mapping element at the failing scalar's opening quote" do
    src_dir = File.tempname("loop-undef-origin-flowmap")
    Dir.mkdir_p(src_dir)
    text = run_playbook(src_dir, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Flow mapping element
            ansible.builtin.debug:
              msg: "{{ item.line_value }}"
            with_items:
              - { pattern: '^Port.*', line_value: 'Port {{ sshd_port }}', insertafter: '^#Port.*' }
      YAML

    playbook = File.expand_path(File.join(src_dir, "pb.yml"))
    text.must_include("[ERROR]: Task failed: 'sshd_port' is undefined")
    text.must_include("Origin: #{playbook}:10:45")
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

  it "pins a block-mapping element at the deeper failing value's opening quote" do
    # Issue #314's defining repro shape: the failing scalar is NOT on the
    # element's dash line but on its own `key: value` line - real ansible
    # points at that line's quote (col 18 here), krikri used to point at
    # the element start (line 10, the `key` word).
    src_dir = File.tempname("loop-undef-origin-blockmap")
    Dir.mkdir_p(src_dir)
    text = run_playbook(src_dir, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Block mapping element
            ansible.builtin.debug:
              msg: "{{ item.key }}={{ item.value }}"
            loop:
              - key: "M2_HOME"
                value: "{{ install_dir }}"
      YAML

    playbook = File.expand_path(File.join(src_dir, "pb.yml"))
    text.must_include("[ERROR]: Task failed: 'install_dir' is undefined")
    text.must_include("Origin: #{playbook}:11:18")
    text.must_include("11           value: \"{{ install_dir }}\"\n                    ^ column 18")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "pins a block-mapping element's plain value at its first character" do
    src_dir = File.tempname("loop-undef-origin-blockmap-plain")
    Dir.mkdir_p(src_dir)
    text = run_playbook(src_dir, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Plain element value
            ansible.builtin.debug:
              msg: "{{ item.key }}={{ item.value }}"
            loop:
              - key: "M2_HOME"
                value: m2-{{ install_dir }}-prop
      YAML

    playbook = File.expand_path(File.join(src_dir, "pb.yml"))
    text.must_include("[ERROR]: Task failed: 'install_dir' is undefined")
    # No quote to pin for a plain scalar: the value's own start.
    text.must_include("Origin: #{playbook}:11:18")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "pins a block-mapping element's inline dash-line value at its quote" do
    src_dir = File.tempname("loop-undef-origin-blockmap-inline")
    Dir.mkdir_p(src_dir)
    text = run_playbook(src_dir, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Inline mapping value
            ansible.builtin.debug:
              msg: "{{ item.key }}={{ item.value }}"
            loop:
              - key: "{{ install_dir }}"
                value: "M2_HOME"
      YAML

    playbook = File.expand_path(File.join(src_dir, "pb.yml"))
    text.must_include("[ERROR]: Task failed: 'install_dir' is undefined")
    # The failing scalar is the element's INLINE value, quoted: its
    # opening quote (col 16), not the element start (col 11).
    text.must_include("Origin: #{playbook}:10:16")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "scans a block-mapping element past an earlier valueless element" do
    src_dir = File.tempname("loop-undef-origin-blockmap-later")
    Dir.mkdir_p(src_dir)
    text = run_playbook(src_dir, <<-YAML)
      ---
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Later mapping element
            ansible.builtin.debug:
              msg: "{{ item.key }}={{ item.value }}"
            loop:
              - key: "M2_HOME"
              - key: "OTHER"
                value: "{{ install_dir }}"
      YAML

    playbook = File.expand_path(File.join(src_dir, "pb.yml"))
    text.must_include("[ERROR]: Task failed: 'install_dir' is undefined")
    # The first element carries no failing value; the scan must reach the
    # second element's `value:` line (12), not stop or fall back to the
    # first element's start (10).
    text.must_include("Origin: #{playbook}:12:18")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
