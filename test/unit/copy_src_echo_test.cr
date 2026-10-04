require "../minitest_helper"
require "system/user"

# The registered `src` echo for content copies, pinned to real's shape:
# the copy action plugin stages the content on the target as
# <remote_tmp>/ansible-tmp-<epoch.micro>-<pid>-<random>/.source and the
# module echoes that path back (round 995005 deploy_helper_helper_block:
# real /root/.ansible/tmp/ansible-tmp-.../.source, krikri its own
# .krikri-playbook-copy-<hex>.tmp next to the dest). Krikri's write flow
# keeps its own staging locations; only the ECHO is shaped like real's.
#
# remote_tmp is `~/.ansible/tmp` of the user the plugin runs as, so the
# tilde has to be EXPANDED for real: round996005 registered real's
# /root/.ansible/tmp/... against krikri's /root/~/.ansible/tmp/... -
# Crystal's File.expand_path does not expand a leading "~" (it just
# joins it onto the working directory), so the pin below must never be
# computed with it, or it would agree with the bug it is here to catch.
private EXPECTED_HOME = ENV["HOME"]? || System::User.find_by?(id: LibC.getuid.to_s).try(&.home_directory) || ""

private def with_temp_dir(&)
  dir = File.tempname("copy-src-echo-spec")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "copy content src echo in real's staged shape" do
  it "echoes ~/.ansible/tmp/ansible-tmp-.../.source for a plain content copy" do
    with_temp_dir do |dir|
      dest = File.join(dir, "current")

      result = PluginSpecHelper.run("copy", {"content" => "blocked\n", "dest" => dest})

      result["failed"]?.try(&.as_bool).wont_equal(true)
      result["src"].as_s.must_match(
        /\A#{Regex.escape(EXPECTED_HOME)}\/\.ansible\/tmp\/ansible-tmp-\d+\.\d+-\d+-\d+\/\.source\z/)
      # an unexpanded tilde anywhere in the path is the round996005 bug
      result["src"].as_s.includes?("~").must_equal(false)
    end
  end

  it "keeps the dest's extension on the echoed .source path" do
    # action/copy.py appends os.path.splitext(dest_file)[1] to tmp_src
    # ("ensure we keep suffix for validate").
    with_temp_dir do |dir|
      dest = File.join(dir, "current.txt")

      result = PluginSpecHelper.run("copy", {"content" => "blocked\n", "dest" => dest})

      result["failed"]?.try(&.as_bool).wont_equal(true)
      result["src"].as_s.must_match(/\/\.source\.txt\z/)
    end
  end

  it "echoes the same shape on the content force:false no-op path" do
    with_temp_dir do |dir|
      dest = File.join(dir, "current")
      File.write(dest, "blocked\n")

      result = PluginSpecHelper.run("copy", {
        "content" => "blocked\n",
        "dest"    => dest,
        "force"   => "false",
      })

      result["failed"]?.try(&.as_bool).wont_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["src"].as_s.must_match(
        /\A#{Regex.escape(EXPECTED_HOME)}\/\.ansible\/tmp\/ansible-tmp-\d+\.\d+-\d+-\d+\/\.source\z/)
      result["src"].as_s.includes?("~").must_equal(false)
    end
  end
end
