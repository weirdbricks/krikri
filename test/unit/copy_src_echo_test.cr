require "../minitest_helper"

# The registered `src` echo for content copies, pinned to real's shape:
# the copy action plugin stages the content on the target as
# <remote_tmp>/ansible-tmp-<epoch.micro>-<pid>-<random>/.source and the
# module echoes that path back (round 995005 deploy_helper_helper_block:
# real /root/.ansible/tmp/ansible-tmp-.../.source, krikri its own
# .krikri-playbook-copy-<hex>.tmp next to the dest). Krikri's write flow
# keeps its own staging locations; only the ECHO is shaped like real's.
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
        /\A#{Regex.escape(File.expand_path("~"))}\/\.ansible\/tmp\/ansible-tmp-\d+\.\d+-\d+-\d+\/\.source\z/)
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
        /\A#{Regex.escape(File.expand_path("~"))}\/\.ansible\/tmp\/ansible-tmp-\d+\.\d+-\d+-\d+\/\.source\z/)
    end
  end
end
