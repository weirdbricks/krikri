require "../minitest_helper"

# Pins plugins/gem.cr's pre-flight probe and argument checks against real
# community.general.gem (live-diffed vs ansible-playbook 2.19.11 in
# the no-ruby container: Ansible's first command is always `<gem> --version`,
# so a missing/unexecutable binary fails before any state dispatch):
#
# - without `executable:`, get_bin_path('gem', True) fails with its own
#   "Failed to find required executable ..." wording
# - an `executable:` override is used VERBATIM: a path that cannot be
#   exec'd surfaces run_command's OSError shape (rc=errno, msg "Error
#   executing command.", the [Errno] exception text, space-joined cmd)
# - gem_source is mutually exclusive with repository and version (spec
#   level, before anything else)
describe "gem plugin pre-flight" do
  it "fails with get_bin_path wording when no gem binary exists" do
    result = PluginSpecHelper.run("gem", {"name" => "rake"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Failed to find required executable \"gem\" in paths: ")
  end

  it "fails a missing executable override with the OSError shape" do
    result = PluginSpecHelper.run("gem", {
      "name"       => "rake",
      "executable" => "/no/such/gem",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error executing command.")
    result["rc"].as_i.must_equal(2)
    result["cmd"].as_s.must_equal("/no/such/gem --version")
    result["exception"].as_s.must_equal("[Errno 2] No such file or directory: b'/no/such/gem'")
  end

  it "rejects gem_source together with repository (mutually exclusive)" do
    result = PluginSpecHelper.run("gem", {
      "name"       => "rake",
      "gem_source" => "/tmp/rake.gem",
      "repository" => "https://rubygems.org",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("parameters are mutually exclusive: gem_source|repository")
  end

  it "rejects gem_source together with version (mutually exclusive)" do
    result = PluginSpecHelper.run("gem", {
      "name"       => "rake",
      "gem_source" => "/tmp/rake.gem",
      "version"    => "1.0",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("parameters are mutually exclusive: gem_source|version")
  end
end
