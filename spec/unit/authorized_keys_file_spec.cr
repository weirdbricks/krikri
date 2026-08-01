require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/authorized_keys_file"

private alias AuthorizedKeysFile = CrystalPlay::PluginHelpers::AuthorizedKeysFile

private RSA_KEY = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC test@example.com"

describe AuthorizedKeysFile do
  describe ".key_signature" do
    it "extracts type + blob, ignoring the trailing comment" do
      AuthorizedKeysFile.key_signature(RSA_KEY).should eq("ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC")
    end

    it "ignores leading options" do
      line = "command=\"/bin/true\",no-port-forwarding #{RSA_KEY}"
      AuthorizedKeysFile.key_signature(line).should eq("ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC")
    end

    it "returns nil for a comment line" do
      AuthorizedKeysFile.key_signature("# just a comment").should be_nil
    end

    it "returns nil for a blank line" do
      AuthorizedKeysFile.key_signature("   ").should be_nil
    end

    it "returns nil when no recognized key type is present" do
      AuthorizedKeysFile.key_signature("not a key at all").should be_nil
    end
  end

  describe ".ensure (present)" do
    it "adds the key to an empty file" do
      text, changed = AuthorizedKeysFile.ensure("", RSA_KEY, true)
      text.should eq("#{RSA_KEY}\n")
      changed.should be_true
    end

    it "appends the key after existing entries" do
      existing = "ssh-ed25519 AAAAC3 other@host\n"
      text, changed = AuthorizedKeysFile.ensure(existing, RSA_KEY, true)

      text.should eq("ssh-ed25519 AAAAC3 other@host\n#{RSA_KEY}\n")
      changed.should be_true
    end

    it "is idempotent when the key (by signature) is already present" do
      existing = "#{RSA_KEY}\n"
      _, changed = AuthorizedKeysFile.ensure(existing, RSA_KEY, true)

      changed.should be_false
    end

    it "treats a differing comment as the same key" do
      existing = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC someone-else@elsewhere\n"
      _, changed = AuthorizedKeysFile.ensure(existing, RSA_KEY, true)

      changed.should be_false
    end
  end

  describe ".ensure (absent)" do
    it "removes a matching key" do
      existing = "#{RSA_KEY}\nssh-ed25519 AAAAC3 other@host\n"
      text, changed = AuthorizedKeysFile.ensure(existing, RSA_KEY, false)

      text.should eq("ssh-ed25519 AAAAC3 other@host\n")
      changed.should be_true
    end

    it "is a no-op when the key isn't present" do
      existing = "ssh-ed25519 AAAAC3 other@host\n"
      text, changed = AuthorizedKeysFile.ensure(existing, RSA_KEY, false)

      text.should eq(existing)
      changed.should be_false
    end

    it "results in an empty string when removing the only key" do
      text, changed = AuthorizedKeysFile.ensure("#{RSA_KEY}\n", RSA_KEY, false)
      text.should eq("")
      changed.should be_true
    end
  end
end
