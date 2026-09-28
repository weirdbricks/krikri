require "../minitest_helper"
require "../../src/krikri/plugin_helpers/known_hosts_key"

private alias KnownHostsKey = Krikri::PluginHelpers::KnownHostsKey

private KEY_LINE = "mfbenchhost2 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGUv5i6LyDtqn"

describe KnownHostsKey do
  describe ".hash_host_line" do
    it "hashes only the hostname field into the |1|salt|digest form" do
      hashed = KnownHostsKey.hash_host_line("mfbenchhost2", KEY_LINE)

      fields = hashed.split
      fields.size.must_equal(3)
      fields[1].must_equal("ssh-ed25519")
      fields[2].must_equal("AAAAC3NzaC1lZDI1NTE5AAAAIGUv5i6LyDtqn")
      expect(str_starts_with?(fields[0], "|1|")).must_equal(true)
    end

    it "uses a 20-byte salt and HMAC-SHA1 over the hostname, both base64" do
      hashed = KnownHostsKey.hash_host_line("mfbenchhost2", KEY_LINE)
      fields = hashed.split[0].split('|', remove_empty: true)

      fields[0].must_equal("1")
      salt = Base64.decode(fields[1])
      salt.size.must_equal(20)
      Base64.strict_encode(KnownHostsKey.hmac_digest(salt, "mfbenchhost2")).must_equal(fields[2])
    end

    it "produces a different salt (and so a different line) each call" do
      one = KnownHostsKey.hash_host_line("mfbenchhost2", KEY_LINE)
      two = KnownHostsKey.hash_host_line("mfbenchhost2", KEY_LINE)

      one.wont_equal(two)
    end

    it "shifts the hashed field past an @cert-authority marker" do
      line = "@cert-authority mfbenchhost2 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGUv5i6LyDtqn"
      hashed = KnownHostsKey.hash_host_line("mfbenchhost2", line)

      fields = hashed.split
      fields[0].must_equal("@cert-authority")
      expect(str_starts_with?(fields[1], "|1|")).must_equal(true)
      fields[2].must_equal("ssh-ed25519")
    end
  end
end
