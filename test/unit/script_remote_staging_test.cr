require "../minitest_helper"
require "set"
require "../../src/krikri/plugin_helpers/script_remote_staging"

# Pure half of the remote script's per-task staging (executor side): the
# dir name and the one-shot remote mkdir script mirror ansible's own
# shell.mkdtemp, so the staged file's path lands under the same
# /.ansible/tmp/ansible-tmp-<ts>-<pid>-<rand> mask and the mkdir'd tree
# comes out mode 0700.
describe "ScriptRemoteStaging.tmp_dir_name" do
  it "carries ansible's ansible-tmp-<epoch>-<pid>-<rand> name shape" do
    name = Krikri::PluginHelpers::ScriptRemoteStaging.tmp_dir_name
    name.must_match(/\Aansible-tmp-\d+\.\d+-\d+-\d+\z/)
  end

  it "never repeats a name (real's secrets.randbelow(2**48) space)" do
    names = Set(String).new
    50.times { names << Krikri::PluginHelpers::ScriptRemoteStaging.tmp_dir_name }
    names.size.must_equal(50)
  end
end

describe "ScriptRemoteStaging.mkdir_script" do
  it "mirrors ansible shell.mkdtemp's umask 077 one-shot mkdir shape" do
    Krikri::PluginHelpers::ScriptRemoteStaging.mkdir_script("~/.ansible/tmp", "ansible-tmp-1.2-3-4")
      .must_equal("{ umask 077 && mkdir -p $(echo ~/.ansible/tmp) && mkdir $(echo ~/.ansible/tmp/ansible-tmp-1.2-3-4) && echo KRIKRI-TMPDIR=$(echo ~/.ansible/tmp/ansible-tmp-1.2-3-4); }")
  end

  it "echoes the per-task dir back with the KRIKRI-TMPDIR= key" do
    script = Krikri::PluginHelpers::ScriptRemoteStaging.mkdir_script("/var/tmp/roles-tmp", "ansible-tmp-5.6-7-8")
    script.must_include("echo KRIKRI-TMPDIR=$(echo /var/tmp/roles-tmp/ansible-tmp-5.6-7-8)")
  end
end

describe "ScriptRemoteStaging.parsed_tmpdir" do
  it "returns the echoed absolute path" do
    Krikri::PluginHelpers::ScriptRemoteStaging.parsed_tmpdir("KRIKRI-TMPDIR=/root/.ansible/tmp/ansible-tmp-1792822794.6691642-3684055-8664083885542\n")
      .must_equal("/root/.ansible/tmp/ansible-tmp-1792822794.6691642-3684055-8664083885542")
  end

  it "nils on absent, non-absolute or blank echo answers" do
    Krikri::PluginHelpers::ScriptRemoteStaging.parsed_tmpdir("").must_be_nil
    Krikri::PluginHelpers::ScriptRemoteStaging.parsed_tmpdir("something else\n").must_be_nil
    Krikri::PluginHelpers::ScriptRemoteStaging.parsed_tmpdir("KRIKRI-TMPDIR=ansible-tmp-unexpanded\n").must_be_nil
    Krikri::PluginHelpers::ScriptRemoteStaging.parsed_tmpdir("KRIKRI-TMPDIR=\n").must_be_nil
  end
end
