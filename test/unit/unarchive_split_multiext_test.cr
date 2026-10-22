require "../minitest_helper"
require "../../src/krikri/plugin_helpers/multiext_split"

# Ansible's fetch_file (ansible/module_utils/urls.py) stages a URL
# download as tempfile prefix + 8 random chars + suffix, with prefix and
# suffix coming from _split_multiext(basename, count=2) - not
# os.path.splitext. Since unarchive echoes the staged path back as
# `src`, the difference is visible in task output (issue #225, verified
# against ansible-core 2.19.11).
describe "PluginHelpers::MultiextSplit" do
  it "moves the last two short suffix components to the extension" do
    Krikri::PluginHelpers::MultiextSplit.split("helm-v3.3.0-linux-amd64.tar.gz")
      .must_equal({"helm-v3.3.0-linux-amd64", ".tar.gz"})
  end

  it "keeps a two-component suffix intact for a tar.gz name" do
    Krikri::PluginHelpers::MultiextSplit.split("race.tar.gz").must_equal({"race", ".tar.gz"})
  end

  it "exposes Python rstrip's character-set semantics on suffix-like stems" do
    # rstrip(".tar") strips any trailing r/a/t/. characters, not a
    # literal ".tar" suffix - so "data.tar" trims down to "d".
    Krikri::PluginHelpers::MultiextSplit.split("data.tar.gz").must_equal({"d", ".tar.gz"})
  end

  it "moves a single short suffix to the extension" do
    Krikri::PluginHelpers::MultiextSplit.split("archive.zip").must_equal({"archive", ".zip"})
  end

  it "leaves a name whose only suffix is too short alone" do
    Krikri::PluginHelpers::MultiextSplit.split("a.b").must_equal({"a.b", ""})
  end

  it "leaves a name without any dot alone" do
    Krikri::PluginHelpers::MultiextSplit.split("plainname").must_equal({"plainname", ""})
  end

  it "leaves a trailing-dot name alone" do
    Krikri::PluginHelpers::MultiextSplit.split("name.").must_equal({"name.", ""})
  end

  it "leaves a hidden-style leading-dot name alone" do
    Krikri::PluginHelpers::MultiextSplit.split(".hiddenfile").must_equal({".hiddenfile", ""})
  end
end
