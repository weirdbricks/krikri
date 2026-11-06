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
end
