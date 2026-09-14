require "../spec_helper"
require "file_utils"

# `copy:` with an empty-string `content:` or `src:`.
#
# `src` and `content` have DIFFERENT presence rules in real Ansible -
# live-verified against ansible-core 2.19.11, all four shapes below:
# `src` is truthiness-checked (an empty string is never a valid file
# path, so `src: ""` is "not provided" exactly like an absent `src:`),
# while `content` is presence-checked (nil vs not-nil) - an empty FILE
# is a legitimate thing to write, so `content: ""` given directly
# succeeds and writes a real empty file, and `src: "<path>", content:
# ""` DOES hit "src and content are mutually exclusive" (the empty
# content still counts as "given"). A previous investigation
# (hbjydev.restic, round 702015) found ONE real case that fails -
# `content:` templated from a `{% for %}...{% endfor %}` block tag that
# renders to nothing - and mistakenly generalized it to "any empty
# content: is not provided"; that block-tag-specific case is handled
# upstream in TaskExecutor#substitute_task_params (dropping the param
# key entirely via OMIT_SENTINEL), not in this plugin, and is spec'd
# separately at the task-executor level.
private def with_temp_dir(&)
  dir = File.tempname("copy-empty-content-spec")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "copy: empty-string content/src presence rules" do
  it "writes a real empty file for a literal empty content: with no src" do
    with_temp_dir do |dir|
      dest = File.join(dir, "files")

      result = PluginSpecHelper.run("copy", {
        "content" => "",
        "dest"    => dest,
      })

      result["failed"]?.try(&.as_bool).should_not be_true
      result["changed"].as_bool.should be_true
      File.exists?(dest).should be_true
      File.read(dest).should eq("")
    end
  end

  it "truncates an existing destination to empty when content is empty" do
    # Real Ansible's copy module actually writes the file - an empty
    # content: is a legitimate, present value, not a validation
    # failure that leaves dest untouched.
    with_temp_dir do |dir|
      dest = File.join(dir, "files")
      File.write(dest, "original\n")

      result = PluginSpecHelper.run("copy", {
        "content" => "",
        "dest"    => dest,
      })

      result["failed"]?.try(&.as_bool).should_not be_true
      result["changed"].as_bool.should be_true
      File.read(dest).should eq("")
    end
  end

  it "fails with the real Ansible message for an empty-string src and no content" do
    # src IS truthiness-checked (unlike content) - an empty string can
    # never be a real file path, so src: "" is "not provided" too.
    with_temp_dir do |dir|
      dest = File.join(dir, "out")

      result = PluginSpecHelper.run("copy", {
        "src"  => "",
        "dest" => dest,
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("src (or content) is required")
      File.exists?(dest).should be_false
    end
  end

  it "uses content when src is an empty string" do
    # src: "" is ignored rather than "mutually exclusive" - the empty
    # string falls out of src's own truthiness check, leaving the
    # content path to run.
    with_temp_dir do |dir|
      dest = File.join(dir, "out")

      result = PluginSpecHelper.run("copy", {
        "src"     => "",
        "content" => "hello\n",
        "dest"    => dest,
      })

      result["failed"]?.try(&.as_bool).should_not be_true
      result["changed"].as_bool.should be_true
      File.read(dest).should eq("hello\n")
    end
  end

  it "fails as mutually exclusive when a real src and an empty content are both given" do
    # Unlike src: "", an empty content: DOES count as "given" - so a
    # real src alongside it is a genuine conflict, not "content
    # ignored, use src".
    with_temp_dir do |dir|
      src_path = File.join(dir, "source.txt")
      File.write(src_path, "hello\n")
      dest = File.join(dir, "out")

      result = PluginSpecHelper.run("copy", {
        "src"     => src_path,
        "content" => "",
        "dest"    => dest,
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("src and content are mutually exclusive")
      File.exists?(dest).should be_false
    end
  end
end
