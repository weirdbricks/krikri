require "../minitest_helper"
require "../../src/krikri/task_executor/output_routing"

# Ansible reconfigures sys.stdout/stderr with `_replacing_warning_handler`
# (utils/display.py): any character the stream cannot encode is written as
# "?" and a one-per-run warning is printed. A remote command's non-UTF-8
# output reaches that handler through the lone surrogate a surrogateescape
# decode made of each undecodable byte - krikri's twin for it, U+F780+
# (byte-0x80) - so the console form of both shapes is "?" (issue #1811,
# live-verified against ansible-core 2.21.6).
describe "display non-UTF-8 scrubbing" do
  serial! # the warning dedupe is one run-wide flag

  it "replaces each undecodable byte with one question mark" do
    text = String.new(Bytes[0x61, 0xff, 0xfe, 0x62])
    Krikri::OutputRouting.normalize_for_display(text).must_equal("a??b")
  end

  it "replaces each surrogateescape twin with a question mark" do
    Krikri::OutputRouting.normalize_for_display("a\u{F780}b\u{F7FF}c").must_equal("a?b?c")
  end

  it "leaves valid text, including non-ASCII, untouched" do
    Krikri::OutputRouting.normalize_for_display("h\u{e9}llo \u{4e16}\u{754c}").must_equal("h\u{e9}llo \u{4e16}\u{754c}")
  end

  it "scrubs a colorized line, where every result and banner line goes" do
    Krikri::OutputRouting.normalize_for_display("fatal: \u{F7FF}".colorize(:red)).must_equal("fatal: ?")
  end

  it "warns once per run, however many writes carry undecodable characters" do
    Krikri::OutputRouting.reset_non_utf8_report
    Krikri::OutputRouting.scrub_undecodable("a\u{F7FF}")
    Krikri::OutputRouting.non_utf8_reported?.must_equal(true)
    Krikri::OutputRouting.scrub_undecodable(String.new(Bytes[0x61, 0xff]))
    Krikri::OutputRouting.non_utf8_reported?.must_equal(true)
  end

  it "writes the scrubbed text through the routed puts" do
    io = IO::Memory.new
    Krikri::OutputRouting.redirect_current_fiber_to(io)
    begin
      puts "a\u{F7FF}b"
    ensure
      Krikri::OutputRouting.clear_current_fiber_redirect
    end

    io.to_s.must_equal("a?b\n")
  end
end
