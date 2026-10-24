require "../minitest_helper"
require "../../src/krikri/yaml_source_map"
require "../../src/krikri/playbook_parser"

# ansible-core 2.19's from_origin (_internal/_errors/_error_utils.py) keeps
# the annotation budget honest at 120 columns: an over-long source line is
# cut to max_src_line_len - 3 characters with "..." attached directly to
# the tail, and the caret is only drawn when the column still points at
# text ansible actually printed (it is dropped when the column falls past
# a truncated line, and re-laid out as "column N ^" trailing text when
# "column N" would overrun the budget otherwise). krikri kept all
# max_src_line_len characters and bolted " ..." on top, so line 38 of the
# Open-Future-Belgium.Zabbix-Agent vars rendered as
# "...name of the machine is us ..." where ansible prints
# "...name of the machine is...".
#
# Both fixtures below pin the label width at 2 digits (dup key on line 10),
# the max_src_line_len ansible computes for that is 120 - 2 - 1 = 117, and
# a truncated line shows its first 114 characters plus the 3-char marker.
describe "Krikri::PlaybookParser.warn_duplicate_map_keys over-long lines (origin_block_truncation_test.cr)" do
  it "truncate an over-long line to 117 display chars ending in \"...\"" do
    work = PluginSpecHelper.tmp_path("origin-block-truncation")
    path = File.join(work, "long-dup.yml")
    long_line = "zbx_agent_HostName:" + (" " * 36) + "# Put the hostname if not filled in name off the machine is us?"

    # Fixture sanity: 118 chars with comments starting inline, cut lands
    # at the exact "machine is" boundary that issued #315 showed.
    long_line.size.must_equal(118)
    long_line.index("machine is").must_equal(104)

    content = "---\n" \
               + (2..8).map { |line_no| "# filler line #{line_no}" }.join("\n") + "\n" \
                                                                                   + "zbx_agent_HostName: provisional\n" \
                                                                                      + long_line + "\n"
    Dir.mkdir_p(work)
    File.write(path, content)

    map = Krikri::YamlSourceMap.scan(content)
    map.duplicate_keys.must_equal([{"zbx_agent_HostName", 10, 1}])

    io = IO::Memory.new
    Krikri::PlaybookParser.warn_duplicate_map_keys(path, map, io)

    truncated = long_line[0...114] + "..."
    truncated.size.must_equal(117)
    truncated.ends_with?("machine is...").must_equal(true)

    expected = String.build do |e|
      e << "[WARNING]: Found duplicate mapping key 'zbx_agent_HostName'.\n"
      e << "Origin: " << File.expand_path(path) << ":10:1\n"
      e << "\n"
      e << " 8 # filler line 8\n"
      e << " 9 zbx_agent_HostName: provisional\n"
      e << "10 " << truncated << "\n"
      e << "   ^ column 1\n"
      e << "\nUsing last defined value only.\n\n"
    end
    io.to_s.must_equal(expected)
  end

  it "omits the caret marker when the column falls past a truncated line" do
    work = PluginSpecHelper.tmp_path("origin-block-caret-omitted")
    path = File.join(work, "cut-caret.yml")

    # A duplicate key indented out to col 116 sits past the 114 characters
    # a truncated 2-digit-numbered line shows, so ansible prints no caret
    # line at all for it. Both occurrences must sit at the same indent
    # (same block mapping) for the scanner to see a repeat; the deep
    # indent keeps each key's line over-long, as the caret rule only
    # bites once a line got truncated.
    first = " " * 115 + "zz: original"
    second = " " * 115 + "zz: two"
    first.size.must_equal(127)
    second.size.must_equal(122)

    content = "---\n" \
               + (2..8).map { |line_no| "# filler line #{line_no}" }.join("\n") + "\n" \
                                                                                   + first + "\n" \
                                                                                              + second + "\n"
    Dir.mkdir_p(work)
    File.write(path, content)

    map = Krikri::YamlSourceMap.scan(content)
    map.duplicate_keys.must_equal([{"zz", 10, 116}])

    io = IO::Memory.new
    Krikri::PlaybookParser.warn_duplicate_map_keys(path, map, io)

    expected = String.build do |e|
      e << "[WARNING]: Found duplicate mapping key 'zz'.\n"
      e << "Origin: " << File.expand_path(path) << ":10:116\n"
      e << "\n"
      e << " 8 # filler line 8\n"
      e << " 9 " << (" " * 114) << "...\n"
      e << "10 " << (" " * 114) << "...\n"
      e << "\nUsing last defined value only.\n\n"
    end
    io.to_s.must_equal(expected)
  end

  it "moves the column label ahead of the caret when it would overrun the width" do
    work = PluginSpecHelper.tmp_path("origin-block-caret-relocated")
    path = File.join(work, "relocated-caret.yml")

    # A 2-digit line number gives the col budget 117; for a duplicate key
    # at col 110 the naive "^ column 110" tail would run to col 121
    # (col - 1 + 2 + len("column 110")), so ansible prints the label text
    # first with the caret trailing at the real column, both inside the
    # budget. The first occurrence's 121-char line is truncated (usable
    # 114) while the one the Origin points at fits whole.
    first = " " * 109 + "zz: original"
    second = " " * 109 + "zz: two"
    first.size.must_equal(121)
    second.size.must_equal(116)

    content = "---\n" \
               + (2..8).map { |line_no| "# filler line #{line_no}" }.join("\n") + "\n" \
                                                                                   + first + "\n" \
                                                                                              + second + "\n"
    Dir.mkdir_p(work)
    File.write(path, content)

    map = Krikri::YamlSourceMap.scan(content)
    map.duplicate_keys.must_equal([{"zz", 10, 110}])

    io = IO::Memory.new
    Krikri::PlaybookParser.warn_duplicate_map_keys(path, map, io)

    expected = String.build do |e|
      e << "[WARNING]: Found duplicate mapping key 'zz'.\n"
      e << "Origin: " << File.expand_path(path) << ":10:110\n"
      e << "\n"
      e << " 8 # filler line 8\n"
      e << " 9 " << (" " * 109) << "zz: o" << "...\n"
      e << "10 " << (" " * 109) << "zz: two\n"
      e << (" " * 3) << (" " * 98) << "column 110 ^\n"
      e << "\nUsing last defined value only.\n\n"
    end
    io.to_s.must_equal(expected)
  end
end
