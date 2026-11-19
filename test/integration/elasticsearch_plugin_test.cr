require "../minitest_helper"

# community.general.elasticsearch_plugin (issue #1588). Real runs the
# module under --check too, and every expectation below was compared
# against ansible-core 2.21.6 with community.general 12.5.0 on this box
# (`-v --check`, so the module's own result dict is part of the output).
describe "elasticsearch_plugin plugin" do
  it "fails with real's installer-probe message before any state work" do
    missing = PluginSpecHelper.tmp_path("elasticsearch-plugin-missing")
    # A real host without Elasticsearch has neither installer on PATH,
    # nor /usr/share/elasticsearch/bin; empty PATH keeps that true here.
    result = PluginSpecHelper.run("elasticsearch_plugin", {
      "name"                => "repository-s3",
      "state"               => "present",
      "force"               => "true",
      "plugin_bin"          => missing,
      "_ansible_check_mode" => "true",
    }, env: {"PATH" => ""})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal(
      "#{missing} does not exist and no other valid plugin installers were found. Make sure Elasticsearch is installed.")
  end

  it "reports the unset installer parameter the way Python's None prints it" do
    result = PluginSpecHelper.run("elasticsearch_plugin", {
      "name" => "repository-s3", "state" => "present",
    }, env: {"PATH" => ""})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "None does not exist and no other valid plugin installers were found. Make sure Elasticsearch is installed.")
  end

  it "reports a check-mode install with the module's cmd/stdout/url/timeout result" do
    dir = PluginSpecHelper.tmp_path("elasticsearch-plugin-install")
    bin = File.join(dir, "elasticsearch-plugin")
    FileUtils.mkdir_p(File.join(dir, "plugins"))
    File.write(bin, "#!/bin/sh\nexit 0\n")
    File.chmod(bin, 0o755)

    result = PluginSpecHelper.run("elasticsearch_plugin", {
      "name"                => "analysis-icu",
      "state"               => "present",
      "plugin_bin"          => bin,
      "plugin_dir"          => File.join(dir, "plugins"),
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result["cmd"].as_a.map(&.as_s).must_equal([bin, "install", "analysis-icu"])
    result["name"].as_s.must_equal("analysis-icu")
    result["state"].as_s.must_equal("present")
    result["url"].raw.must_be_nil
    result["timeout"].as_s.must_equal("1m")
    result["stdout"].as_s.must_equal("check mode")
    result["stderr"].as_s.must_be_empty
    result["stdout_lines"].as_a.map(&.as_s).must_equal(["check mode"])
    result["stderr_lines"].as_a.must_be_empty
    result["msg"]?.must_be_nil
  end

  it "reproduces the legacy installer argv real builds from version" do
    dir = PluginSpecHelper.tmp_path("elasticsearch-plugin-legacy")
    bin = File.join(dir, "plugin")
    FileUtils.mkdir_p(File.join(dir, "plugins"))
    File.write(bin, "#!/bin/sh\nexit 0\n")
    File.chmod(bin, 0o755)

    result = PluginSpecHelper.run("elasticsearch_plugin", {
      "name"                => "mobz/elasticsearch-head",
      "state"               => "present",
      "version"             => "2.0.0",
      "url"                 => "http://example.test/plugin.zip",
      "force"               => "true",
      "plugin_bin"          => bin,
      "plugin_dir"          => File.join(dir, "plugins"),
      "_ansible_check_mode" => "true",
    })

    # Real assigns the versioned name to argv index 2, overwriting the
    # "--timeout" it just appended and orphaning its value - observed
    # verbatim from ansible's -v dump, so it is matched, not corrected.
    result["cmd"].as_a.map(&.as_s).must_equal([
      bin, "install", "mobz/elasticsearch-head/2.0.0", "1m",
      "--url", "http://example.test/plugin.zip", "--batch",
      "mobz/elasticsearch-head/2.0.0",
    ])
    result["changed"].as_bool.must_equal(true)
  end

  it "treats an installed plugin as unchanged and reports name+state only" do
    dir = PluginSpecHelper.tmp_path("elasticsearch-plugin-present")
    bin = File.join(dir, "elasticsearch-plugin")
    FileUtils.mkdir_p(File.join(dir, "plugins", "analysis-icu"))
    File.write(bin, "#!/bin/sh\nexit 0\n")
    File.chmod(bin, 0o755)

    result = PluginSpecHelper.run("elasticsearch_plugin", {
      "name"                => "analysis-icu",
      "state"               => "present",
      "plugin_bin"          => bin,
      "plugin_dir"          => File.join(dir, "plugins"),
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(false)
    result["name"].as_s.must_equal("analysis-icu")
    result["state"].as_s.must_equal("present")
    result["msg"]?.must_be_nil
    result["cmd"]?.must_be_nil
    result["stdout"]?.must_be_nil
  end
end
