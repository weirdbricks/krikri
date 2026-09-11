require "../spec_helper"
require "../../src/krikri/plugin_helpers/maven_artifact_command"

# Unit-tests the maven_artifact pure logic against real
# community.general.maven_artifact's own Artifact/MavenDownloader code
# (read from a live collection install) - the plugin's transfer paths
# need a repository, the string/XML/checksum shapes don't.
describe Krikri::PluginHelpers::MavenArtifactCommand do
  describe ".artifact_path" do
    it "maps group dots to slashes and appends the version" do
      Krikri::PluginHelpers::MavenArtifactCommand.artifact_path("org.apache.commons", "commons-lang3", "3.14.0")
        .should eq("org/apache/commons/commons-lang3/3.14.0")
      Krikri::PluginHelpers::MavenArtifactCommand.artifact_path("org.apache.commons", "commons-lang3", nil)
        .should eq("org/apache/commons/commons-lang3")
    end

    it "keeps a SNAPSHOT directory for timestamped snapshot versions" do
      Krikri::PluginHelpers::MavenArtifactCommand.artifact_path("com.example", "app", "1.2.3-20240101.123456-7")
        .should eq("com/example/app/1.2.3-SNAPSHOT")
      Krikri::PluginHelpers::MavenArtifactCommand.artifact_path("com.example", "app", "jgit-4.10.0.201806080211-r-20200101.101010-1")
        .should eq("com/example/app/jgit-4.10.0.201806080211-r-SNAPSHOT")
      Krikri::PluginHelpers::MavenArtifactCommand.artifact_path("com.example", "app", "1.2.3-SNAPSHOT")
        .should eq("com/example/app/1.2.3-SNAPSHOT")
    end
  end

  describe ".generated_filename / .dest_filename" do
    it "generates the artifact's own filename with optional classifier" do
      Krikri::PluginHelpers::MavenArtifactCommand.generated_filename("commons-lang3", nil, "jar")
        .should eq("commons-lang3.jar")
      Krikri::PluginHelpers::MavenArtifactCommand.generated_filename("commons-lang3", "sources", "jar")
        .should eq("commons-lang3-sources.jar")
    end

    it "joins the generated name under a directory dest, keep_name keeping the version" do
      Krikri::PluginHelpers::MavenArtifactCommand.dest_filename("/opt/app/", "commons-lang3", "3.14.0", nil, "jar", false)
        .should eq("/opt/app/commons-lang3.jar")
      Krikri::PluginHelpers::MavenArtifactCommand.dest_filename("/opt/app/", "commons-lang3", "3.14.0", nil, "jar", true)
        .should eq("/opt/app/commons-lang3-3.14.0.jar")
      Krikri::PluginHelpers::MavenArtifactCommand.dest_filename("/opt/app/", "commons-lang3", "3.14.0", "sources", "jar", true)
        .should eq("/opt/app/commons-lang3-3.14.0-sources.jar")
    end

    it "uses a file dest verbatim" do
      Krikri::PluginHelpers::MavenArtifactCommand.dest_filename("/opt/app/lib.jar", "commons-lang3", "3.14.0", nil, "jar", true)
        .should eq("/opt/app/lib.jar")
    end
  end

  describe ".latest_version" do
    it "takes the last version element of the metadata, not the highest" do
      xml = <<-XML
        <metadata>
          <versioning>
            <versions>
              <version>3.12.0</version>
              <version>3.14.0</version>
              <version>3.11.0</version>
            </versions>
          </versioning>
        </metadata>
      XML
      Krikri::PluginHelpers::MavenArtifactCommand.latest_version(xml).should eq("3.11.0")
    end

    it "returns nil when no versions are listed" do
      Krikri::PluginHelpers::MavenArtifactCommand.latest_version("<metadata><versioning/></metadata>")
        .should be_nil
    end
  end

  describe ".snapshot_version / .snapshot_timestamp_version" do
    metadata = <<-XML
      <metadata>
        <versioning>
          <snapshot>
            <timestamp>20240101.123456</timestamp>
            <buildNumber>7</buildNumber>
          </snapshot>
          <snapshotVersions>
            <snapshotVersion>
              <extension>jar</extension>
              <value>1.2.3-20240101.123456-7</value>
              <updated>20240101123456</updated>
            </snapshotVersion>
            <snapshotVersion>
              <classifier>sources</classifier>
              <extension>jar</extension>
              <value>1.2.3-20240101.111111-5</value>
              <updated>20240101111111</updated>
            </snapshotVersion>
          </snapshotVersions>
        </versioning>
      </metadata>
    XML

    it "resolves the snapshotVersion entry matching classifier+extension" do
      Krikri::PluginHelpers::MavenArtifactCommand.snapshot_version(metadata, "", "jar")
        .should eq("1.2.3-20240101.123456-7")
      Krikri::PluginHelpers::MavenArtifactCommand.snapshot_version(metadata, "sources", "jar")
        .should eq("1.2.3-20240101.111111-5")
    end

    it "falls back to timestamp/buildNumber" do
      Krikri::PluginHelpers::MavenArtifactCommand.snapshot_timestamp_version(metadata, "1.2.3-SNAPSHOT")
        .should eq("1.2.3-20240101.123456-7")
    end

    it "returns nil when the metadata has no snapshot info" do
      Krikri::PluginHelpers::MavenArtifactCommand.snapshot_timestamp_version(
        "<metadata><versioning/></metadata>", "1.2.3-SNAPSHOT").should be_nil
    end
  end

  describe ".checksum_matches?" do
    it "compares the first token case-insensitively (trailing filename ignored)" do
      Krikri::PluginHelpers::MavenArtifactCommand.checksum_matches?(
        "5f2e0a9d4a26e34c7e33a2b0a8a1d3f1", "5f2e0a9d4a26e34c7e33a2b0a8a1d3f1  commons-lang3-3.14.0.jar")
        .should be_true
      Krikri::PluginHelpers::MavenArtifactCommand.checksum_matches?(
        "5F2E0A9D4A26E34C7E33A2B0A8A1D3F1", "5f2e0a9d4a26e34c7e33a2b0a8a1d3f1")
        .should be_true
      Krikri::PluginHelpers::MavenArtifactCommand.checksum_matches?("aaaa", "bbbb")
        .should be_false
    end
  end
end
