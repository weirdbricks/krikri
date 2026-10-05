require "../minitest_helper"
require "../../src/krikri/yaml_source_map"

# Regression coverage for YamlSourceMap, the libyaml event pass that
# labels tasks with their playbook origin for Ansible 2.19's
# `[ERROR]: Task failed:` blocks.
#
# The historical bug here was NOT the path logic: scan_events allocated
# the parser with `Pointer(LibYAML::Parser).malloc(1)`, but Crystal's
# LibYAML::Parser mapping covers only the error/problem fields at the
# start of the real (480-byte) yaml_parser_t, so yaml_parser_initialize
# overflowed the allocation and corrupted the heap. The corruption
# surfaced later and elsewhere - as a stray SIGSEGV or as libyaml's
# scanner spinning forever inside yaml_parser_update_buffer - which made
# the whole krikri-playbook process hang at 100% CPU on ordinary
# playbooks. The fix allocates LibYAML::PARSER_SIZE bytes the same way
# Crystal's own YAML::PullParser does; the assertions below pin the
# observable behavior (correct positions + a heap that stays healthy
# across repeated scans and subsequent allocations).
#
# A task's recorded position is the start of its own YAML mapping - the
# position of its first key, matching Ansible's Origin column
# (e.g. `name` at column 5 of `  - name: x`).
describe Krikri::YamlSourceMap do
  it "maps task positions by path through plays and task lists" do
    content = <<-YAML
      ---
      - name: 'play one'
        hosts: all
        gather_facts: false
        tasks:
        - name: 'first task'
          ansible.builtin.debug:
            msg: hello
        - name: 'second task'
          ansible.builtin.debug:
            msg: bye
      YAML

    map = Krikri::YamlSourceMap.scan(content)
    map.at?("0/tasks/0").must_equal({6, 5})
    map.at?("0/tasks/1").must_equal({9, 5})
    # The play mapping itself starts at its first key.
    map.at?("0").must_equal({2, 3})
  end

  it "maps nested block task positions with section-prefixed paths" do
    content = <<-YAML
      - name: play
        hosts: all
        tasks:
        - name: my block
          block:
          - name: inner task
            ansible.builtin.debug:
              msg: hi
      YAML

    map = Krikri::YamlSourceMap.scan(content)
    # parse_block_task builds "<prefix>/<index>/block" for the block's
    # body list.
    map.at?("0/tasks/0/block/0").must_equal({6, 7})
  end

  it "survives repeated scans of many documents without corrupting the heap" do
    documents = [] of String
    50.times do |i|
      documents << <<-YAML
        - name: 'generated play #{i}'
          hosts: all
          gather_facts: false
          tasks:
          - name: 'task #{i}'
            ansible.builtin.command: /bin/true
        YAML
    end

    3.times do
      documents.each do |doc|
        map = Krikri::YamlSourceMap.scan(doc)
        map.at?("0/tasks/0").must_equal({5, 5})
      end
      GC.collect
    end

    # Heap corruption from a bad scan shows up as a crash in entirely
    # unrelated allocations (File.read, string building); allocating and
    # touching fresh memory here is the observable proxy for "healthy".
    probe = Array.new(1000) { |i| i.to_s * 20 }
    probe.size.must_equal(1000)
  end

  it "yields no position for a missing path and never raises on odd YAML" do
    map = Krikri::YamlSourceMap.scan("not even yaml: [\n")
    # The root mapping opened before the failure is recorded; everything
    # past it is not, and the scan itself must neither raise nor hang.
    map.at?("").must_equal({1, 1})
    map.at?("0/tasks/0").must_be_nil
  end
end
