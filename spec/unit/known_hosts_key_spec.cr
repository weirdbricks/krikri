require "../spec_helper"
require "../../src/krikri/plugin_helpers/known_hosts_key"

private alias KnownHostsKey = Krikri::PluginHelpers::KnownHostsKey

private KEY_LINE = "mfbenchhost2 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGUv5i6LyDtqn"

describe KnownHostsKey do
  describe ".hash_host_line" do
    it "hashes only the hostname field into the |1|salt|digest form" do
      hashed = KnownHostsKey.hash_host_line("mfbenchhost2", KEY_LINE)

      fields = hashed.split
      fields.size.should eq(3)
      fields[1].should eq("ssh-ed25519")
      fields[2].should eq("AAAAC3NzaC1lZDI1NTE5AAAAIGUv5i6LyDtqn")
      fields[0].should start_with("|1|")
    end

    it "uses a 20-byte salt and HMAC-SHA1 over the hostname, both base64" do
      hashed = KnownHostsKey.hash_host_line("mfbenchhost2", KEY_LINE)
      fields = hashed.split[0].split('|', remove_empty: true)

      fields[0].should eq("1")
      salt = Base64.decode(fields[1])
      salt.size.should eq(20)
      Base64.strict_encode(KnownHostsKey.hmac_digest(salt, "mfbenchhost2")).should eq(fields[2])
    end

    it "produces a different salt (and so a different line) each call" do
      one = KnownHostsKey.hash_host_line("mfbenchhost2", KEY_LINE)
      two = KnownHostsKey.hash_host_line("mfbenchhost2", KEY_LINE)

      one.should_not eq(two)
    end

    it "shifts the hashed field past an @cert-authority marker" do
      line = "@cert-authority mfbenchhost2 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGUv5i6LyDtqn"
      hashed = KnownHostsKey.hash_host_line("mfbenchhost2", line)

      fields = hashed.split
      fields[0].should eq("@cert-authority")
      fields[1].should start_with("|1|")
      fields[2].should eq("ssh-ed25519")
    end
  end
end
