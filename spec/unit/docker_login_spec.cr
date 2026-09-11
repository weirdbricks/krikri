require "../spec_helper"
require "../../src/krikri/plugin_helpers/docker_login"
require "json"

# Unit-tests the docker_login logic against real community.docker
# .docker_login's own behavior (DockerFileStore get/store/erase: base64
# user:pass entries under auths[<registry>], 0600 config rewrite,
# required_if validation, hub-endpoint handling). Execution needs a real
# registry + docker CLI - the config JSON handling and command shapes
# don't.
describe Krikri::PluginHelpers::DockerLogin do
  describe ".hub?" do
    it "treats the default endpoint and hub aliases as the hub" do
      ["", "https://index.docker.io/v1/", "https://index.docker.io", "https://docker.io"].each do |url|
        Krikri::PluginHelpers::DockerLogin.hub?(url).should be_true
      end
    end

    it "treats custom registries as non-hub" do
      Krikri::PluginHelpers::DockerLogin.hub?("your.private.registry.io").should be_false
      Krikri::PluginHelpers::DockerLogin.hub?("ghcr.io").should be_false
    end
  end

  describe ".decode_auth" do
    it "decodes base64 user:pass entries" do
      auth = Base64.strict_encode("docker:rekcod")
      decoded = Krikri::PluginHelpers::DockerLogin.decode_auth(auth).should_not be_nil
      decoded[:username].should eq("docker")
      decoded[:password].should eq("rekcod")
    end

    it "supports colons inside passwords" do
      auth = Base64.strict_encode("docker:pa:ss:word")
      decoded = Krikri::PluginHelpers::DockerLogin.decode_auth(auth).should_not be_nil
      decoded[:password].should eq("pa:ss:word")
    end

    it "returns nil for missing or malformed entries" do
      Krikri::PluginHelpers::DockerLogin.decode_auth(nil).should be_nil
      Krikri::PluginHelpers::DockerLogin.decode_auth("!!!not base64!!!").should be_nil
    end
  end

  describe ".stored_credentials" do
    it "reads the registry's entry from a parsed config" do
      config = JSON.parse(%({"auths": {"https://index.docker.io/v1/": {"auth": "#{Base64.strict_encode("docker:rekcod")}"}}}))
      stored = Krikri::PluginHelpers::DockerLogin.stored_credentials(config, "https://index.docker.io/v1/").should_not be_nil
      stored[:username].should eq("docker")
    end

    it "returns nil when the registry has no entry" do
      config = JSON.parse(%({"auths": {}}))
      Krikri::PluginHelpers::DockerLogin.stored_credentials(config, "ghcr.io").should be_nil
      Krikri::PluginHelpers::DockerLogin.stored_credentials(nil, "ghcr.io").should be_nil
    end
  end

  describe ".with_stored_credentials" do
    it "adds the entry while preserving other config keys" do
      config = JSON.parse(%({"experimental": "disabled", "auths": {"ghcr.io": {"auth": "old"}}}))
      updated = Krikri::PluginHelpers::DockerLogin.with_stored_credentials(config, "https://index.docker.io/v1/", "docker", "rekcod")
      parsed = JSON.parse(updated)
      parsed["experimental"].as_s.should eq("disabled")
      stored = Krikri::PluginHelpers::DockerLogin.stored_credentials(parsed, "https://index.docker.io/v1/").should_not be_nil
      stored[:username].should eq("docker")
      stored[:password].should eq("rekcod")
    end

    it "replaces an existing entry for the registry" do
      config = JSON.parse(%({"auths": {"ghcr.io": {"auth": "old"}}}))
      updated = JSON.parse(Krikri::PluginHelpers::DockerLogin.with_stored_credentials(config, "ghcr.io", "user", "pass"))
      stored = Krikri::PluginHelpers::DockerLogin.stored_credentials(updated, "ghcr.io").should_not be_nil
      stored[:username].should eq("user")
    end

    it "builds a minimal config from nothing" do
      updated = JSON.parse(Krikri::PluginHelpers::DockerLogin.with_stored_credentials(nil, "ghcr.io", "user", "pass"))
      Krikri::PluginHelpers::DockerLogin.stored_credentials(updated, "ghcr.io").should_not be_nil
    end
  end

  describe ".with_erased_credentials" do
    it "removes the entry and preserves the rest" do
      config = JSON.parse(%({"experimental": "disabled", "auths": {"ghcr.io": {"auth": "old"}, "docker.io": {"auth": "keep"}}}))
      updated = JSON.parse(Krikri::PluginHelpers::DockerLogin.with_erased_credentials(config, "ghcr.io").should_not be_nil)
      updated["auths"].as_h.has_key?("ghcr.io").should be_false
      updated["auths"].as_h.has_key?("docker.io").should be_true
      updated["experimental"].as_s.should eq("disabled")
    end

    it "returns nil when there is nothing to erase" do
      config = JSON.parse(%({"auths": {}}))
      Krikri::PluginHelpers::DockerLogin.with_erased_credentials(config, "ghcr.io").should be_nil
      Krikri::PluginHelpers::DockerLogin.with_erased_credentials(nil, "ghcr.io").should be_nil
    end
  end

  describe ".login_command" do
    it "omits the registry argument for hub logins" do
      Krikri::PluginHelpers::DockerLogin.login_command("https://index.docker.io/v1/", "docker", "rekcod", nil)
        .should eq("docker login -u 'docker' -p 'rekcod'")
    end

    it "passes custom registries and config dirs through" do
      Krikri::PluginHelpers::DockerLogin.login_command("your.private.registry.io", "yourself", "secrets3", "/tmp/.mydocker")
        .should eq("docker --config '/tmp/.mydocker' login -u 'yourself' -p 'secrets3' your.private.registry.io")
    end

    it "shell-escapes single quotes in credentials" do
      Krikri::PluginHelpers::DockerLogin.login_command("https://index.docker.io/v1/", "user", "pa'ss", nil)
        .should eq(%(docker login -u 'user' -p 'pa'\\''ss'))
    end
  end

  describe ".missing_credentials_msg" do
    it "lists both missing credentials" do
      Krikri::PluginHelpers::DockerLogin.missing_credentials_msg(nil, nil)
        .should eq("state is present but all of the following are missing: username, password")
    end

    it "lists only the one missing credential" do
      Krikri::PluginHelpers::DockerLogin.missing_credentials_msg("docker", nil)
        .should eq("state is present but all of the following are missing: password")
    end

    it "returns nil when both are present" do
      Krikri::PluginHelpers::DockerLogin.missing_credentials_msg("docker", "rekcod").should be_nil
    end
  end
end
