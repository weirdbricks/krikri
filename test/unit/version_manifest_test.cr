require "../minitest_helper"
require "../../src/krikri/version"

describe "version manifest" do
  it "keeps shard.yml's version in step with Krikri::VERSION" do
    manifest = YAML.parse(File.read(File.join(PluginSpecHelper::PROJECT_ROOT, "shard.yml")))
    manifest["version"].as_s.must_equal(Krikri::VERSION)
  end
end
