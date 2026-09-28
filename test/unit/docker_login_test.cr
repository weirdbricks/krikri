require "../minitest_helper"
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
        Krikri::PluginHelpers::DockerLogin.hub?(url).must_equal(true)
      end
    end

    it "treats custom registries as non-hub" do
      Krikri::PluginHelpers::DockerLogin.hub?("your.private.registry.io").must_equal(false)
      Krikri::PluginHelpers::DockerLogin.hub?("ghcr.io").must_equal(false)
    end
  end

  describe ".decode_auth" do
    it "decodes base64 user:pass entries" do
      auth = Base64.strict_encode("docker:rekcod")
      decoded = Krikri::PluginHelpers::DockerLogin.decode_auth(auth).not_nil!
      decoded.wont_be_nil
      decoded[:username].must_equal("docker")
      decoded[:password].must_equal("rekcod")
    end

    it "supports colons inside passwords" do
      auth = Base64.strict_encode("docker:pa:ss:word")
      decoded = Krikri::PluginHelpers::DockerLogin.decode_auth(auth).not_nil!
      decoded.wont_be_nil
      decoded[:password].must_equal("pa:ss:word")
    end

    it "returns nil for missing or malformed entries" do
      Krikri::PluginHelpers::DockerLogin.decode_auth(nil).must_be_nil
      Krikri::PluginHelpers::DockerLogin.decode_auth("!!!not base64!!!").must_be_nil
    end
  end

  describe ".stored_credentials" do
    it "reads the registry's entry from a parsed config" do
      config = JSON.parse(%({"auths": {"https://index.docker.io/v1/": {"auth": "#{Base64.strict_encode("docker:rekcod")}"}}}))
      stored = Krikri::PluginHelpers::DockerLogin.stored_credentials(config, "https://index.docker.io/v1/").not_nil!
      stored.wont_be_nil
      stored[:username].must_equal("docker")
    end

    it "returns nil when the registry has no entry" do
      config = JSON.parse(%({"auths": {}}))
      Krikri::PluginHelpers::DockerLogin.stored_credentials(config, "ghcr.io").must_be_nil
      Krikri::PluginHelpers::DockerLogin.stored_credentials(nil, "ghcr.io").must_be_nil
    end
  end

  describe ".with_stored_credentials" do
    it "adds the entry while preserving other config keys" do
      config = JSON.parse(%({"experimental": "disabled", "auths": {"ghcr.io": {"auth": "old"}}}))
      updated = Krikri::PluginHelpers::DockerLogin.with_stored_credentials(config, "https://index.docker.io/v1/", "docker", "rekcod")
      parsed = JSON.parse(updated)
      parsed["experimental"].as_s.must_equal("disabled")
      stored = Krikri::PluginHelpers::DockerLogin.stored_credentials(parsed, "https://index.docker.io/v1/").not_nil!
      stored.wont_be_nil
      stored[:username].must_equal("docker")
      stored[:password].must_equal("rekcod")
    end

    it "replaces an existing entry for the registry" do
      config = JSON.parse(%({"auths": {"ghcr.io": {"auth": "old"}}}))
      updated = JSON.parse(Krikri::PluginHelpers::DockerLogin.with_stored_credentials(config, "ghcr.io", "user", "pass"))
      stored = Krikri::PluginHelpers::DockerLogin.stored_credentials(updated, "ghcr.io").not_nil!
      stored.wont_be_nil
      stored[:username].must_equal("user")
    end

    it "builds a minimal config from nothing" do
      updated = JSON.parse(Krikri::PluginHelpers::DockerLogin.with_stored_credentials(nil, "ghcr.io", "user", "pass"))
      Krikri::PluginHelpers::DockerLogin.stored_credentials(updated, "ghcr.io").wont_be_nil
    end
  end

  describe ".with_erased_credentials" do
    it "removes the entry and preserves the rest" do
      config = JSON.parse(%({"experimental": "disabled", "auths": {"ghcr.io": {"auth": "old"}, "docker.io": {"auth": "keep"}}}))
      updated = JSON.parse(Krikri::PluginHelpers::DockerLogin.with_erased_credentials(config, "ghcr.io").not_nil!.tap { |v| v.wont_be_nil })
      updated["auths"].as_h.has_key?("ghcr.io").must_equal(false)
      updated["auths"].as_h.has_key?("docker.io").must_equal(true)
      updated["experimental"].as_s.must_equal("disabled")
    end

    it "returns nil when there is nothing to erase" do
      config = JSON.parse(%({"auths": {}}))
      Krikri::PluginHelpers::DockerLogin.with_erased_credentials(config, "ghcr.io").must_be_nil
      Krikri::PluginHelpers::DockerLogin.with_erased_credentials(nil, "ghcr.io").must_be_nil
    end
  end

  describe ".login_command" do
    it "omits the registry argument for hub logins" do
      Krikri::PluginHelpers::DockerLogin.login_command("https://index.docker.io/v1/", "docker", "rekcod", nil)
        .must_equal("printf %s 'cmVrY29k' | base64 -d | docker login -u 'docker' --password-stdin")
    end

    it "passes custom registries and config dirs through" do
      Krikri::PluginHelpers::DockerLogin.login_command("your.private.registry.io", "yourself", "secrets3", "/tmp/.mydocker")
        .must_equal("printf %s 'c2VjcmV0czM=' | base64 -d | docker --config '/tmp/.mydocker' login -u 'yourself' --password-stdin 'your.private.registry.io'")
    end

    it "shell-quotes the registry so it can't inject extra shell operations" do
      Krikri::PluginHelpers::DockerLogin.login_command("reg.io; touch /tmp/pwned", "user", "pw", nil)
        .must_equal("printf %s 'cHc=' | base64 -d | docker login -u 'user' --password-stdin 'reg.io; touch /tmp/pwned'")
    end

    it "keeps single quotes in credentials out of argv entirely" do
      Krikri::PluginHelpers::DockerLogin.login_command("https://index.docker.io/v1/", "user", "pa'ss", nil)
        .must_equal("printf %s 'cGEnc3M=' | base64 -d | docker login -u 'user' --password-stdin")
    end
  end

  describe ".missing_credentials_msg" do
    it "lists both missing credentials" do
      Krikri::PluginHelpers::DockerLogin.missing_credentials_msg(nil, nil)
        .must_equal("state is present but all of the following are missing: username, password")
    end

    it "lists only the one missing credential" do
      Krikri::PluginHelpers::DockerLogin.missing_credentials_msg("docker", nil)
        .must_equal("state is present but all of the following are missing: password")
    end

    it "returns nil when both are present" do
      Krikri::PluginHelpers::DockerLogin.missing_credentials_msg("docker", "rekcod").must_be_nil
    end
  end
end
