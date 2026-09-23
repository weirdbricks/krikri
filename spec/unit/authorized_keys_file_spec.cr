require "../spec_helper"
require "../../src/krikri/plugin_helpers/authorized_keys_file"

private alias AuthorizedKeysFile = Krikri::PluginHelpers::AuthorizedKeysFile

private RSA_KEY     = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC test@example.com"
private ED25519_KEY = "ssh-ed25519 AAAAC3 m2@example"
private KEEP_KEY    = "ssh-ed25519 AAAAC3 keep@host"

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

    it "rewrites the line when only the comment differs (real Ansible compares the comment too)" do
      existing = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC someone-else@elsewhere\n"
      text, changed = AuthorizedKeysFile.ensure(existing, RSA_KEY, true)

      changed.should be_true
      text.should eq("#{RSA_KEY}\n")
    end

    it "treats a reordered key_options list as the same key (real Ansible compares the parsed option dict)" do
      existing = "no-agent-forwarding,command=\"/bin/true\" #{RSA_KEY}\n"
      text, changed = AuthorizedKeysFile.ensure(existing, "command=\"/bin/true\",no-agent-forwarding #{RSA_KEY}", true)

      changed.should be_false
      text.should eq(existing)
    end

    it "rewrites the line when key_options are added to an existing bare key" do
      bare = "ssh-ed25519 AAAAC3 m2@example"
      options = "command=\"/usr/bin/echo bench\",no-agent-forwarding ssh-ed25519 AAAAC3 m2@example"
      text, changed = AuthorizedKeysFile.ensure("#{bare}\n", options, true)

      changed.should be_true
      text.should eq("#{options}\n")
    end

    it "is idempotent when the options-prefixed line is already in the file" do
      options = "command=\"/usr/bin/echo bench\",no-agent-forwarding ssh-ed25519 AAAAC3 m2@example"
      _, changed = AuthorizedKeysFile.ensure("#{options}\n", options, true)

      changed.should be_false
    end
  end

  describe ".ensure_keys (multi-key present)" do
    it "appends every new key after existing ones in the order given" do
      text, changed = AuthorizedKeysFile.ensure_keys(
        "ssh-ed25519 AAAAC3-old old@host\n",
        [RSA_KEY, ED25519_KEY], true
      )

      text.should eq("ssh-ed25519 AAAAC3-old old@host\n#{RSA_KEY}\n#{ED25519_KEY}\n")
      changed.should be_true
    end

    it "is idempotent per-key when some keys are already present" do
      existing = "#{RSA_KEY}\n"
      text, changed = AuthorizedKeysFile.ensure_keys(existing, [RSA_KEY, ED25519_KEY], true)

      text.should eq("#{RSA_KEY}\n#{ED25519_KEY}\n")
      changed.should be_true

      text2, changed2 = AuthorizedKeysFile.ensure_keys(text, [RSA_KEY, ED25519_KEY], true)
      text2.should eq(text)
      changed2.should be_false
    end
  end

  describe ".ensure_keys (exclusive)" do
    it "removes every existing key whose signature isn't among the new keys" do
      existing = "#{RSA_KEY}\nssh-ed25519 AAAAC3-drop drop@host\n"

      text, changed = AuthorizedKeysFile.ensure_keys(existing, [ED25519_KEY], true, true)

      text.should eq("#{ED25519_KEY}\n")
      changed.should be_true
    end

    it "is a no-op when the file already holds exactly the new keys" do
      existing = "#{ED25519_KEY}\n"

      text, changed = AuthorizedKeysFile.ensure_keys(existing, [ED25519_KEY], true, true)

      text.should eq(existing)
      changed.should be_false
    end

    it "keeps lines without a recognizable signature (comments survive exclusive)" do
      existing = "# a comment\n#{RSA_KEY}\n"

      text, _ = AuthorizedKeysFile.ensure_keys(existing, [ED25519_KEY], true, true)

      text.should eq("# a comment\n#{ED25519_KEY}\n")
    end
  end

  describe ".ensure_keys (absent, multi-key)" do
    it "removes every matching key and reports changed once" do
      existing = "#{RSA_KEY}\nssh-ed25519 AAAAC3 m2@example\nssh-ed25519 AAAAC3-keep keep@host\n"

      text, changed = AuthorizedKeysFile.ensure_keys(
        existing, [RSA_KEY, "ssh-ed25519 AAAAC3 m2@example"], false
      )

      text.should eq("ssh-ed25519 AAAAC3-keep keep@host\n")
      changed.should be_true
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
