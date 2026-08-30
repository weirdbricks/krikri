require "../spec_helper"
require "../../src/krikri/plugin_helpers/docker_ref"

describe Krikri::PluginHelpers::DockerRef do
  describe ".split" do
    it "defaults to the latest tag when none is given" do
      Krikri::PluginHelpers::DockerRef.split("nginx").should eq({"nginx", "latest"})
    end

    it "splits a simple name:tag" do
      Krikri::PluginHelpers::DockerRef.split("nginx:1.25").should eq({"nginx", "1.25"})
    end

    it "doesn't mistake a registry port for a tag separator" do
      Krikri::PluginHelpers::DockerRef.split("myregistry:5000/app").should eq({"myregistry:5000/app", "latest"})
    end

    it "splits a registry-qualified ref with a real tag" do
      Krikri::PluginHelpers::DockerRef.split("myregistry:5000/app:latest").should eq({"myregistry:5000/app", "latest"})
    end

    it "handles a namespaced ref like library/nginx:1.25" do
      Krikri::PluginHelpers::DockerRef.split("library/nginx:1.25").should eq({"library/nginx", "1.25"})
    end
  end

  describe ".join" do
    it "joins name and tag back together" do
      Krikri::PluginHelpers::DockerRef.join("nginx", "1.25").should eq("nginx:1.25")
    end
  end

  describe ".same?" do
    it "matches identical refs" do
      Krikri::PluginHelpers::DockerRef.same?("nginx:latest", "nginx:latest").should be_true
    end

    it "matches a daemon-qualified ref against the short form (e.g. Podman's docker.io/library/ prefix)" do
      Krikri::PluginHelpers::DockerRef.same?("docker.io/library/nginx:latest", "nginx:latest").should be_true
      Krikri::PluginHelpers::DockerRef.same?("nginx:latest", "docker.io/library/nginx:latest").should be_true
    end

    it "does not match different images" do
      Krikri::PluginHelpers::DockerRef.same?("nginx:latest", "redis:latest").should be_false
    end

    it "does not match different tags" do
      Krikri::PluginHelpers::DockerRef.same?("nginx:latest", "nginx:1.25").should be_false
    end
  end
end
