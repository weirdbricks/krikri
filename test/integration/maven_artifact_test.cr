require "../minitest_helper"
require "file_utils"
require "digest/md5"

# maven_artifact's parameter-validation failures and the file://
# repository path, exercised without network access. Real repository
# downloads (and the lean_delivery.jmeter round 210778 that needs them)
# belong to the live benchmark rounds.
describe "maven_artifact plugin" do
  it "fails when group_id is missing" do
    result = PluginSpecHelper.run("maven_artifact", {
      "artifact_id" => "app", "dest" => "/tmp/app.jar",
      "repository_url" => "https://repo1.maven.org/maven2",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("group_id")
  end

  it "fails when artifact_id is missing" do
    result = PluginSpecHelper.run("maven_artifact", {
      "group_id" => "com.example", "dest" => "/tmp/app.jar",
      "repository_url" => "https://repo1.maven.org/maven2",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("artifact_id")
  end

  it "fails when dest is missing" do
    result = PluginSpecHelper.run("maven_artifact", {
      "group_id"       => "com.example",
      "artifact_id"    => "app",
      "repository_url" => "https://repo1.maven.org/maven2",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("dest")
  end

  it "fails when version and version_by_spec are both given" do
    result = PluginSpecHelper.run("maven_artifact", {
      "group_id"        => "com.example",
      "artifact_id"     => "app",
      "dest"            => "/tmp/app.jar",
      "repository_url"  => "https://repo1.maven.org/maven2",
      "version"         => "1.0",
      "version_by_spec" => "[1.0,)",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("mutually exclusive")
  end

  it "fails explicitly on version_by_spec (deliberate limitation)" do
    result = PluginSpecHelper.run("maven_artifact", {
      "group_id"        => "com.example",
      "artifact_id"     => "app",
      "dest"            => "/tmp/app.jar",
      "repository_url"  => "https://repo1.maven.org/maven2",
      "version_by_spec" => "[1.0,)",
    })

    result["failed"].as_bool.must_equal(true)
    # Real main()'s import-time dependency checks run BEFORE the
    # Artifact() spec parsing - on a host without semantic_version (this
    # one), version_by_spec fails with missing_required_lib's
    # semantic_version boilerplate, never reaching the "not supported"
    # limitation message (live-verified vs 2.19.11 ordering).
    result["msg"].as_s.must_include(
      "Failed to import the required Python library (semantic_version) on ")
  end

  it "fails explicitly on s3:// repository URLs (deliberate limitation)" do
    result = PluginSpecHelper.run("maven_artifact", {
      "group_id"       => "com.example",
      "artifact_id"    => "app",
      "dest"           => "/tmp/app.jar",
      "repository_url" => "s3://bucket/maven",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("s3://")
  end

  it "fails cleanly when a file:// repository lacks the artifact" do
    repo = File.tempname("maven-repo")
    Dir.mkdir(repo)
    begin
      result = PluginSpecHelper.run("maven_artifact", {
        "group_id"       => "com.example",
        "artifact_id"    => "app",
        "version"        => "1.0",
        "dest"           => "/tmp/krikri-maven-app-1.0.jar",
        "repository_url" => "file://#{repo}",
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_include("Can not find local file")
    ensure
      FileUtils.rm_rf(repo)
    end
  end

  it "downloads from a file:// repository and verifies the checksum" do
    repo = File.tempname("maven-repo")
    Dir.mkdir(repo)
    FileUtils.mkdir_p("#{repo}/com/example/app/1.0")
    content = "krikri maven artifact payload\n"
    File.write("#{repo}/com/example/app/1.0/app-1.0.jar", content)
    File.write("#{repo}/com/example/app/1.0/app-1.0.jar.md5", Digest::MD5.hexdigest(content))
    dest = File.tempname("maven-dest")
    begin
      result = PluginSpecHelper.run("maven_artifact", {
        "group_id"       => "com.example",
        "artifact_id"    => "app",
        "version"        => "1.0",
        "dest"           => dest,
        "repository_url" => "file://#{repo}",
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      File.read(dest).must_equal(content)

      # second run: checksum (verify_change off by default) -> unchanged
      result = PluginSpecHelper.run("maven_artifact", {
        "group_id"       => "com.example",
        "artifact_id"    => "app",
        "version"        => "1.0",
        "dest"           => dest,
        "repository_url" => "file://#{repo}",
      })
      result["changed"].as_bool.must_equal(false)
    ensure
      FileUtils.rm_rf(repo)
      File.delete(dest) rescue nil
    end
  end

  # file:// repositories compare the destination file's checksum
  # against the source artifact's own checksum (the Ansible module's local
  # branch of is_invalid_checksum) - so the change-detection path is
  # exercised by corrupting dest and asking for verify_checksum: always.
  it "re-downloads when verify_checksum=always finds a corrupt destination" do
    repo = File.tempname("maven-repo")
    Dir.mkdir(repo)
    FileUtils.mkdir_p("#{repo}/com/example/app/1.0")
    content = "krikri maven artifact payload\n"
    File.write("#{repo}/com/example/app/1.0/app-1.0.jar", content)
    dest = File.tempname("maven-dest")
    File.write(dest, "corrupted\n")
    begin
      result = PluginSpecHelper.run("maven_artifact", {
        "group_id"        => "com.example",
        "artifact_id"     => "app",
        "version"         => "1.0",
        "dest"            => dest,
        "repository_url"  => "file://#{repo}",
        "verify_checksum" => "always",
      })

      result["changed"].as_bool.must_equal(true)
      File.read(dest).must_equal(content)
    ensure
      FileUtils.rm_rf(repo)
      File.delete(dest) rescue nil
    end
  end
end
