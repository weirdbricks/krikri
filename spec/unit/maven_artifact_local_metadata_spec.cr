require "../spec_helper"
require "file_utils"

# community.general.maven_artifact's local (file://) repository surface:
# MavenDownloader reads maven-metadata-local.xml (NOT maven-metadata.xml)
# for file:// repositories - the plugin used to look for the remote name
# and never resolve version=latest locally. Found against real
# ansible-playbook via the podman-diff harness.
private def with_local_repo(&)
  repo = File.tempname("maven-artifact-spec")
  Dir.mkdir_p(File.join(repo, "krikri", "test", "1.0"))
  File.write(File.join(repo, "krikri", "test", "maven-metadata-local.xml"),
    <<-XML
    <?xml version="1.0" encoding="UTF-8"?>
    <metadata>
      <groupId>krikri</groupId>
      <artifactId>test</artifactId>
      <versioning>
        <versions>
          <version>0.9</version>
          <version>1.0</version>
        </versions>
      </versioning>
    </metadata>
    XML
  )
  jar = File.join(repo, "krikri", "test", "1.0", "test-1.0.jar")
  File.write(jar, "krikri-test-jar-content")
  begin
    yield repo, jar
  ensure
    FileUtils.rm_rf(repo)
  end
end

describe "maven_artifact local repository" do
  it "resolves version=latest through maven-metadata-local.xml" do
    with_local_repo do |repo, jar|
      dest_dir = File.join(repo, "dest")
      result = PluginSpecHelper.run("maven_artifact", {
        "group_id"       => "krikri",
        "artifact_id"    => "test",
        "dest"           => "#{dest_dir}/",
        "repository_url" => "file://#{repo}",
      })
      result["changed"].as_bool.should be_true
      result["failed"]?.should be_nil

      # keep_name defaults false -> the version is stripped from the
      # generated destination filename
      downloaded = File.join(dest_dir, "test.jar")
      File.exists?(downloaded).should be_true
      File.read(downloaded).should eq(File.read(jar))
    end
  end

  it "names the maven-metadata-local.xml file in the missing-metadata failure" do
    with_local_repo do |repo, _|
      result = PluginSpecHelper.run("maven_artifact", {
        "group_id"       => "krikri",
        "artifact_id"    => "missing",
        "dest"           => File.join(repo, "dest", "missing.jar"),
        "repository_url" => "file://#{repo}",
      })
      result["failed"].as_bool.should be_true
      result["msg"].as_s.should contain("maven-metadata-local.xml")
      result["msg"].as_s.should contain("can not find file")
    end
  end
end
