require "../minitest_helper"
require "file_utils"

# Issue #783: copy's --diff `+++ after:` header. Ansible's copy ACTION
# plugin builds the diff itself (_get_diff_data) and sets after_header to
# the CONTROLLER src path for a src: file copy and to the dest path only
# for inline content:. krikri computed every copy diff inside the module
# with after: <dest>, and the src: path (which runs through
# handle_file_copy) produced no diff payload at all on a local connection
# - where real still prints the diff, because the action plugin runs
# there too.
describe "copy diff headers" do
  it "headers the after side with the controller src path when a src file was inlined" do
    dir = PluginSpecHelper.tmp_path("copy-diff-header-inlined")
    FileUtils.mkdir_p(dir)
    src = File.join(dir, "a.txt")
    File.write(src, "hello")
    dest = File.join(dir, "dest.txt")

    result = PluginSpecHelper.run("copy", {
      "content"                 => "hello",
      "dest"                    => dest,
      "__original_src_path"     => src,
      "__original_src_basename" => "a.txt",
      "_ansible_diff"           => "true",
    })

    # _get_diff_data emits a one-entry LIST and carries NO before_header
    # at all when the dest did not exist yet (live-verified vs 2.19.11
    # and 2.21.6); the "before: "/"after: " prefixes are the callback's.
    diff = result["diff"].as_a.first.as_h
    diff["after_header"].as_s.must_equal(src.to_s)
    diff.has_key?("before_header").must_equal(false)
  end

  it "keeps the dest path as after_header for an inline content copy" do
    dir = PluginSpecHelper.tmp_path("copy-diff-header-content")
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, "dest.txt")

    result = PluginSpecHelper.run("copy", {
      "content"       => "hello",
      "dest"          => dest,
      "_ansible_diff" => "true",
    })

    diff = result["diff"].as_a.first.as_h
    diff["after_header"].as_s.must_equal(dest.to_s)
    diff.has_key?("before_header").must_equal(false)
  end

  it "produces a src-path-headed diff for a src-file copy" do
    dir = PluginSpecHelper.tmp_path("copy-diff-header-file")
    FileUtils.mkdir_p(dir)
    src = File.join(dir, "a.txt")
    File.write(src, "hello")
    dest = File.join(dir, "dest.txt")

    result = PluginSpecHelper.run("copy", {
      "src"           => src,
      "dest"          => dest,
      "_ansible_diff" => "true",
    })

    # _get_diff_data emits a one-entry LIST and carries NO before_header
    # at all when the dest did not exist yet (live-verified vs 2.19.11
    # and 2.21.6); the "before: "/"after: " prefixes are the callback's.
    diff = result["diff"].as_a.first.as_h
    diff["after_header"].as_s.must_equal(src.to_s)
    diff.has_key?("before_header").must_equal(false)
    diff["before"].as_s.must_equal("")
    diff["after"].as_s.must_equal("hello")
  end

  it "headers the before side with the dest path when the dest already exists" do
    dir = PluginSpecHelper.tmp_path("copy-diff-header-existing")
    FileUtils.mkdir_p(dir)
    src = File.join(dir, "a.txt")
    File.write(src, "new")
    dest = File.join(dir, "dest.txt")
    File.write(dest, "old")

    result = PluginSpecHelper.run("copy", {
      "src"           => src,
      "dest"          => dest,
      "_ansible_diff" => "true",
    })

    diff = result["diff"].as_a.first.as_h
    diff["before_header"].as_s.must_equal(dest.to_s)
    diff["after_header"].as_s.must_equal(src.to_s)
    diff["before"].as_s.must_equal("old")
  end

  it "still emits no diff payload for a remote_src copy" do
    dir = PluginSpecHelper.tmp_path("copy-diff-header-remote-src")
    FileUtils.mkdir_p(dir)
    src = File.join(dir, "a.txt")
    File.write(src, "hello")
    dest = File.join(dir, "dest.txt")

    result = PluginSpecHelper.run("copy", {
      "src"           => src,
      "dest"          => dest,
      "remote_src"    => "true",
      "_ansible_diff" => "true",
    })

    # The wire always carries the empty-list diff shape; a real diff dict
    # (headers included) must not appear.
    result["diff"].as_a.must_equal([] of JSON::Any)
  end

  it "marks a binary source side with src_binary instead of its raw bytes" do
    dir = PluginSpecHelper.tmp_path("copy-diff-src-binary")
    FileUtils.mkdir_p(dir)
    src = File.join(dir, "blob.bin")
    File.write(src, "bin\u{0}lary")
    dest = File.join(dir, "dest.bin")

    result = PluginSpecHelper.run("copy", {
      "src"           => src,
      "dest"          => dest,
      "_ansible_diff" => "true",
    })

    # _get_diff_data replaces the source content with a src_binary marker
    # when it holds a NUL byte (live-verified vs 2.21.6). Raw binary bytes
    # in the diff JSON are not valid UTF-8 and killed the whole task
    # before the copy ran (issue #1064).
    diff = result["diff"].as_a.first.as_h
    diff["src_binary"].as_i64.must_equal(1)
    diff.has_key?("after").must_equal(false)
    diff.has_key?("after_header").must_equal(false)
    diff["before"].as_s.must_equal("")
  end

  it "marks a binary destination side with dst_binary and keeps the source content" do
    dir = PluginSpecHelper.tmp_path("copy-diff-dst-binary")
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, "dest.bin")
    File.write(dest, "old\u{0}dest")

    result = PluginSpecHelper.run("copy", {
      "content"       => "hello",
      "dest"          => dest,
      "_ansible_diff" => "true",
    })

    diff = result["diff"].as_a.first.as_h
    diff["dst_binary"].as_i64.must_equal(1)
    diff.has_key?("before").must_equal(false)
    diff.has_key?("before_header").must_equal(false)
    diff["after"].as_s.must_equal("hello")
    diff["after_header"].as_s.must_equal(dest.to_s)
  end

  it "replaces an oversized source side with the src_larger marker" do
    dir = PluginSpecHelper.tmp_path("copy-diff-src-larger")
    FileUtils.mkdir_p(dir)
    src = File.join(dir, "big.txt")
    File.write(src, "a" * 104449)
    dest = File.join(dir, "dest.txt")

    result = PluginSpecHelper.run("copy", {
      "src"           => src,
      "dest"          => dest,
      "_ansible_diff" => "true",
    })

    # Past MAX_FILE_SIZE_FOR_DIFF (_get_diff_data's limit, the marker
    # stores the number the callback quotes), the content is dropped for
    # an src_larger marker - live-verified vs 2.21.6, where an .rpm copy
    # prints "diff skipped: source file size is greater than 104448".
    diff = result["diff"].as_a.first.as_h
    diff["src_larger"].as_i64.must_equal(104448)
    diff.has_key?("after").must_equal(false)
  end

  it "replaces an oversized destination side with the dst_larger marker" do
    dir = PluginSpecHelper.tmp_path("copy-diff-dst-larger")
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, "big.txt")
    File.write(dest, "a" * 104449)

    result = PluginSpecHelper.run("copy", {
      "content"       => "hello",
      "dest"          => dest,
      "_ansible_diff" => "true",
    })

    diff = result["diff"].as_a.first.as_h
    diff["dst_larger"].as_i64.must_equal(104448)
    diff.has_key?("before").must_equal(false)
    diff["after"].as_s.must_equal("hello")
  end
end
