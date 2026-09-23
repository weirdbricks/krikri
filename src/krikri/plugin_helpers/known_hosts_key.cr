require "openssl/hmac"

module Krikri
  module PluginHelpers
    # KnownHostsKey - pure known_hosts-entry shaping (no I/O), so the
    # hash_host behavior is unit-testable with plain strings.
    module KnownHostsKey
      # Real Ansible's hash_host_key (ansible.builtin.known_hosts): only
      # the entry being written gets hashed - the hostname field (after
      # the optional @cert-authority/@revoked marker) becomes ssh's
      # |1|<salt>|<hash>, where salt is 20 random bytes and hash is
      # HMAC-SHA1(salt, hostname), both base64. Hashing must never touch
      # other entries: `ssh-keygen -H` re-hashes the WHOLE file, so plain
      # entries added without hash_host: true (the param's real default
      # is false) would end up hashed too, diverging from real Ansible's
      # byte output.
      def self.hash_host_line(host : String, key_line : String) : String
        parts = key_line.split(/\s+/)
        index = !parts.empty? && parts[0].starts_with?('@') ? 1 : 0
        return key_line if index >= parts.size

        salt = Random::Secure.random_bytes(20)
        digest = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA1, salt, host)
        parts[index] = "|1|#{Base64.strict_encode(salt)}|#{Base64.strict_encode(digest)}"
        parts.join(" ")
      end

      # Recomputes the |1|<salt>|<hash> hostname field for *host* from a
      # salt extracted out of an existing hashed field - used to verify
      # hash_host_line's output round-trips to the same digest.
      def self.hmac_digest(salt : Bytes, host : String) : Bytes
        OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA1, salt, host)
      end
    end
  end
end
