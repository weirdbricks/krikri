require "../minitest_helper"
require "file_utils"

# `template:` --diff/--check against an EXISTING multi-kilobyte dest.
#
# The diff's "before" side used to carry single-character typos that are
# in no file at all ("secrets" -> "secets", "exec" -> "eec"): the dest
# content was decoded with `String.new(bytes, "UTF-8", invalid: :skip)`,
# which routes through iconv opened as "UTF-8//IGNORE" - and glibc's
# iconv silently DROPS a byte at each internal buffer boundary even when
# the input is already valid UTF-8. A ~4.3 KB dest lost 4 bytes, so the
# printed diff showed corrupted "- before" lines (plus their "+ after"
# twins) for lines both sides actually agree on; the dest file itself was
# never touched. ansible-playbook shows only the real difference.
#
# The fix decodes valid UTF-8 byte-for-byte and only falls back to the
# iconv skip path for a dest written in a non-UTF-8 output_encoding. The
# assertion below is exact equality of the whole before side, so it fails
# on the unpatched glibc behavior and holds on any platform where iconv
# happens to be lossless.
private def monitored_service_block(name : String) : String
  <<-BLOCK
    # Monitor #{name}
    check program #{name}_status with path "/usr/bin/systemctl is-active #{name} --quiet"
      if status != 0 for 10 cycles then exec "/usr/bin/systemctl start #{name}"
      if status != 0 for 15 cycles then exec "/usr/bin/notify --add-hostname --service-name #{name} --state-file /var/lib/state.json /secrets/token '#{name} is not running after restart attempt'"
      else if succeeded for 3 cycles then exec "/usr/bin/notify --add-hostname --service-name #{name} --state-file /var/lib/state.json /secrets/token '#{name} is running again'"

    BLOCK
end

private def with_temp_dir(&)
  dir = File.tempname("template-diff-before-spec")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "template: --diff before side of a multi-KB dest" do
  it "diffs the dest byte-for-byte with no dropped characters" do
    with_temp_dir do |dir|
      dest = File.join(dir, "dest.conf")
      # Eight ~540-byte service blocks: the same shape as the issue #681
      # repro, large enough to cross the iconv buffer boundaries where the
      # IGNORE-suffixed decode used to drop a byte (one per ~1 KB of output).
      original = String.build do |io|
        %w[alpha bravo charlie delta echo foxtrot golf hotel].each do |svc|
          io << monitored_service_block(svc)
        end
      end
      File.write(dest, original)

      result = PluginSpecHelper.run("template", {
        "_ansible_check_mode"     => "true",
        "_ansible_diff"           => "true",
        "dest"                    => dest,
        "content"                 => original + "# Monitor extra\n",
        "_rendered_from_template" => "t.conf.j2",
      })

      result["changed"].as_bool.must_equal(true)
      # template's diff payload is a one-entry LIST (copy's action builds
      # it), like real ansible's.
      before = result["diff"].as_a.first.as_h["before"].as_s
      # The load-bearing assertion: the "before" side is exactly what is
      # on disk - every typo'd character here was a byte iconv dropped.
      before.must_equal(original)
      File.read(dest).must_equal(original)
    end
  end
end

# `template:` delegates to copy's action plugin, so its diff payload comes
# from _get_diff_data, which replaces a binary side with a skip marker
# (src_binary/dst_binary) instead of the raw bytes; the callback then
# prints "diff skipped: source/destination file appears to be binary".
# krikri built the entry inline and embedded the NUL bytes, printing a
# full diff where ansible printed the skip line (issue #1618).
describe "template: --diff binary sides" do
  it "marks a binary source side with src_binary instead of its raw bytes" do
    dir = PluginSpecHelper.tmp_path("template-diff-src-binary")
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, "dest.txt")
    original = "kpg locked dest\nsecond line\n"
    File.write(dest, original)

    result = PluginSpecHelper.run("template", {
      "_ansible_diff"           => "true",
      "dest"                    => dest,
      "content"                 => "\u{0}\u{1}kpg\u{0}binary\u{F7FF}",
      "_rendered_from_template" => "binary.bin",
    })

    result["changed"].as_bool.must_equal(true)
    diff = result["diff"].as_a.first.as_h
    diff["src_binary"].as_i64.must_equal(1)
    diff.has_key?("after").must_equal(false)
    diff.has_key?("after_header").must_equal(false)
    diff["before"].as_s.must_equal(original)
    diff["before_header"].as_s.must_equal(dest)
  end

  it "marks a binary destination side with dst_binary and keeps the source content" do
    dir = PluginSpecHelper.tmp_path("template-diff-dst-binary")
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, "dest.txt")
    File.write(dest, "old\u{0}dest")

    result = PluginSpecHelper.run("template", {
      "_ansible_diff"           => "true",
      "dest"                    => dest,
      "content"                 => "kpg no trailing newline\n",
      "_rendered_from_template" => "no-newline.txt",
    })

    diff = result["diff"].as_a.first.as_h
    diff["dst_binary"].as_i64.must_equal(1)
    diff.has_key?("before").must_equal(false)
    diff.has_key?("before_header").must_equal(false)
    diff["after"].as_s.must_equal("kpg no trailing newline\n")
    diff["after_header"].as_s.must_equal("no-newline.txt")
  end
end
