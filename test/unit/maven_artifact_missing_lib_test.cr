require "../minitest_helper"

# Pins plugins/maven_artifact.cr's import-time dependency checks against
# real community.general.maven_artifact: main()'s HAS_LXML_ETREE /
# HAS_SEMANTIC_VERSION fail_json(missing_required_lib(...)) checks run
# right after the argument_spec validation and before anything else
# (live-diffed vs ansible-playbook 2.19.11 in the no-network
# container: the lxml failure beats version_by_spec spec parsing, the
# repository URL handling and every download attempt). The message is
# missing_required_lib's boilerplate: hostname's Python <sys.executable>.
describe "maven_artifact import-time library checks" do
  # This host has lxml but no semantic_version - so the semantic_version
  # check is the deterministic one to pin here (the lxml branch was
  # verified live in the generator container, where lxml is missing).
  it "fails version_by_spec with the semantic_version missing_required_lib boilerplate" do
    result = PluginSpecHelper.run("maven_artifact", {
      "group_id"        => "group",
      "artifact_id"     => "artifact",
      "dest"            => "/tmp/krikri-maven-spec-test/x.jar",
      "version_by_spec" => "1.2.3",
    })

    result["failed"].as_bool.must_equal(true)
    msg = result["msg"].as_s
    msg.must_include("Failed to import the required Python library (semantic_version) on ")
    msg.must_include("'s Python ")
    msg.must_include("Please read the module documentation and install it in the appropriate location.")
  end

  it "the library failure beats the spec-version parser failure" do
    result = PluginSpecHelper.run("maven_artifact", {
      "group_id"        => "group",
      "artifact_id"     => "artifact",
      "dest"            => "/tmp/krikri-maven-spec-test/x.jar",
      "version_by_spec" => "not-a-spec-at-all",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.as(String).must_include("Failed to import the required Python library (semantic_version) on ")
  end
end
