require "../spec_helper"
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

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("group_id")
  end

  it "fails when artifact_id is missing" do
    result = PluginSpecHelper.run("maven_artifact", {
      "group_id" => "com.example", "dest" => "/tmp/app.jar",
      "repository_url" => "https://repo1.maven.org/maven2",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("artifact_id")
  end

  it "fails when dest is missing" do
    result = PluginSpecHelper.run("maven_artifact", {
      "group_id"       => "com.example",
      "artifact_id"    => "app",
      "repository_url" => "https://repo1.maven.org/maven2",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("dest")
  end

  it "fails when version and version_by_spec are both given" do
    result = PluginSpecHelper.run("maven_artifact", {
      "group_id"       => "com.example",
      "artifact_id"    => "app",
      "dest"           => "/tmp/app.jar",
      "repository_url" => "https://repo1.maven.org/maven2",
      "version"        => "1.0",
      "version_by_spec" => "[1.0,)",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("mutually exclusive")
  end

  it "fails explicitly on version_by_spec (deliberate limitation)" do
    result = PluginSpecHelper.run("maven_artifact", {
      "group_id"       => "com.example",
      "artifact_id"    => "app",
      "dest"           => "/tmp/app.jar",
      "repository_url" => "https://repo1.maven.org/maven2",
      "version_by_spec" => "[1.0,)",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("not supported")
  end

  it "fails explicitly on s3:// repository URLs (deliberate limitation)" do
    result = PluginSpecHelper.run("maven_artifact", {
      "group_id"       => "com.example",
      "artifact_id"    => "app",
      "dest"           => "/tmp/app.jar",
      "repository_url" => "s3://bucket/maven",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("s3://")
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

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should contain("Can not find local file")
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

      result["failed"]?.try(&.as_bool).should be_falsey
      result["changed"].as_bool.should be_true
      File.read(dest).should eq(content)

      # second run: checksum (verify_change off by default) -> unchanged
      result = PluginSpecHelper.run("maven_artifact", {
        "group_id"       => "com.example",
        "artifact_id"    => "app",
        "version"        => "1.0",
        "dest"           => dest,
        "repository_url" => "file://#{repo}",
      })
      result["changed"].as_bool.should be_false
    ensure
      FileUtils.rm_rf(repo)
      File.delete(dest) rescue nil
    end
  end

  # file:// repositories compare the destination file's checksum
  # against the source artifact's own checksum (the real module's local
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

      result["changed"].as_bool.should be_true
      File.read(dest).should eq(content)
    ensure
      FileUtils.rm_rf(repo)
      File.delete(dest) rescue nil
    end
  end
end
