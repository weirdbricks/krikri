require "../minitest_helper"
require "file_utils"

# Issue #273 (honatas.openjdk_ppa): a name containing a glob character
# (`*?[]!`) goes through apt.py's fnmatch expansion, which fails a no-match
# with the plural "No package(s) matching 'X' available" (no "is") rather
# than the plain-name "No package matching 'X' is available".

private def with_apt_glob_shims(&)
  dir = PluginSpecHelper.tmp_path("fake-apt-glob-name")
  FileUtils.rm_r(dir) if File.exists?(dir)
  Dir.mkdir_p(dir)

  File.write(File.join(dir, "apt-cache"), "#!/bin/sh\nexit 0\n")
  File.write(File.join(dir, "dpkg-query"), "#!/bin/sh\nexit 0\n")
  File.write(File.join(dir, "apt-get"), "#!/bin/sh\nexit 100\n")
  ["apt-cache", "dpkg-query", "apt-get"].each do |name|
    File.chmod(File.join(dir, name), 0o755)
  end

  env = {"PATH" => "#{dir}:/usr/bin:/bin"}.to_json
  begin
    yield env
  ensure
    FileUtils.rm_r(dir) if File.exists?(dir)
  end
end

describe "apt with a glob-character name that matches nothing (issue 273)" do
  it "fails with the plural No package(s) matching wording" do
    with_apt_glob_shims do |env|
      result = PluginSpecHelper.run("apt", {
        "name"         => "[] +  ['krikri-no-such-jdk']",
        "state"        => "present",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("No package(s) matching '[] +  ['krikri-no-such-jdk']' available")
      result.as_h.has_key?("cache_updated").must_equal(false)
    end
  end
end
