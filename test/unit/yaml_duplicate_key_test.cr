require "../minitest_helper"
require "../../src/krikri/yaml_source_map"
require "../../src/krikri/playbook_parser"

# ansible-core 2.19.11 (constructor.py construct_mapping) warns once per
# duplicate mapping-key occurrence at LOAD time, before any PLAY output:
#
#   [WARNING]: Found duplicate mapping key 'bookworm'.
#   Origin: /abs/path/pb.yml:7:7
#
#   5     m:
#   6       bookworm: a
#   7       bookworm: b
#           ^ column 7
#
#   Using last defined value only.
#
# The Origin points at the DUPLICATE (second) key's own position, and the
# last value still wins - the warning is purely cosmetic.
describe "Krikri::YamlSourceMap duplicate mapping keys (yaml_duplicate_key_test.cr)" do
  it "records each duplicate occurrence at the repeated key's position" do
    content = <<-YAML
      ---
      - hosts: localhost
        gather_facts: false
        vars:
          m:
            bookworm: a
            bookworm: b
        tasks:
        - name: t
          ansible.builtin.debug:
            msg: hi
      YAML

    map = Krikri::YamlSourceMap.scan(content)
    map.duplicate_keys.must_equal([{"bookworm", 7, 7}])
  end

  it "reports one entry per occurrence after the first for a triple key" do
    content = <<-YAML
      ---
      - hosts: localhost
        gather_facts: false
        vars:
          m:
            bookworm: a
            bookworm: b
            bookworm: c
        tasks:
        - name: t
          ansible.builtin.debug:
            msg: hi
      YAML

    map = Krikri::YamlSourceMap.scan(content)
    map.duplicate_keys.must_equal([{"bookworm", 7, 7}, {"bookworm", 8, 7}])
  end

  it "does not treat the same key in sibling mappings as a duplicate" do
    content = <<-YAML
      ---
      - hosts: localhost
        gather_facts: false
        vars:
          first:
            x: 1
          second:
            x: 2
        tasks:
        - name: t
          ansible.builtin.debug:
            msg: hi
      YAML

    map = Krikri::YamlSourceMap.scan(content)
    map.duplicate_keys.must_equal([] of Krikri::YamlSourceMap::DuplicateKey)
  end

  it "finds duplicates in a bare mapping document" do
    map = Krikri::YamlSourceMap.scan("a: 1\nb: 2\na: 3\n")
    map.duplicate_keys.must_equal([{"a", 3, 1}])
  end
end

describe "Krikri::PlaybookParser.warn_duplicate_map_keys rendering (yaml_duplicate_key_test.cr)" do
  it "renders ansible's load-time warning block for a real file" do
    work = PluginSpecHelper.tmp_path("yaml-dup-keys")
    path = File.join(work, "dup.yml")
    content = <<-YAML
      ---
      - hosts: localhost
        gather_facts: false
        vars:
          m:
            bookworm: a
            bookworm: b
        tasks:
        - name: t
          ansible.builtin.debug:
            msg: hi
      YAML
    Dir.mkdir_p(work)
    File.write(path, content)

    map = Krikri::YamlSourceMap.scan(content)
    io = IO::Memory.new
    Krikri::PlaybookParser.warn_duplicate_map_keys(path, map, io)

    expected = String.build do |e|
      e << "[WARNING]: Found duplicate mapping key 'bookworm'.\n"
      e << "Origin: " << File.expand_path(path) << ":7:7\n"
      e << "\n5     m:\n6       bookworm: a\n7       bookworm: b\n        ^ column 7\n"
      e << "\nUsing last defined value only.\n\n"
    end
    io.to_s.must_equal(expected)
  end

  it "stays silent when the path is not a real file" do
    map = Krikri::YamlSourceMap.scan("a: 1\na: 2\n")
    io = IO::Memory.new
    Krikri::PlaybookParser.warn_duplicate_map_keys("/nonexistent/dup.yml", map, io)
    io.to_s.must_equal("")
  end

  it "stays silent when there are no duplicates" do
    work = PluginSpecHelper.tmp_path("yaml-dup-keys-clean")
    Dir.mkdir_p(work)
    path = File.join(work, "clean.yml")
    content = "---\n- hosts: localhost\n  gather_facts: false\n  vars:\n    m:\n      a: 1\n"
    File.write(path, content)

    map = Krikri::YamlSourceMap.scan(content)
    io = IO::Memory.new
    Krikri::PlaybookParser.warn_duplicate_map_keys(path, map, io)
    io.to_s.must_equal("")
  end
end
