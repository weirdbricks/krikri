require "base64"
require "digest/md5"
require "openssl"
require "openssl/hmac"

module Krikri
  module PluginHelpers
    # PostgresqlPasswordVerifier - pure logic for postgresql_user's
    # idempotency decision (see plugins/postgresql_user.cr): whether a
    # desired password differs from the role's stored verifier, ported
    # from real community.postgresql.postgresql_user's
    # user_should_we_change_password() so a repeat call with an unchanged
    # password reports changed: false instead of reissuing ALTER ROLE.
    #
    # SCRAM-SHA-256 verifiers store a salted, iterated hash, so the
    # stored value can never be compared to the plaintext directly;
    # instead the ServerKey is recomputed client-side from the plaintext
    # and the salt/iteration count parsed out of the stored verifier
    # (RFC 5802: SaltedPassword = Hi(password, salt, i), ServerKey =
    # HMAC(SaltedPassword, "Server Key")) - the same comparison the real
    # module performs. Pre-hashed inputs (a SCRAM verifier string or an
    # "md5" + 32-hex digest) are compared verbatim; a plaintext password
    # against a server whose default is md5 computes PostgreSQL's own
    # 'md5' + md5(password + username) form. Like the real module, an
    # unreadable-but-existing current value that is neither SCRAM nor
    # md5 against a scram-sha-256-default server always counts as
    # changed (the verifier cannot be recomputed without the salt).
    module PostgresqlPasswordVerifier
      # PostgreSQL's own pg_authid.rolpassword format:
      # SCRAM-SHA-256$<iterations>:<salt b64>$<StoredKey b64>:<ServerKey b64>
      SCRAM_SHA256_REGEX = /^SCRAM-SHA-256\$(\d+):([A-Za-z0-9+\/=]+)\$([A-Za-z0-9+\/=]+):([A-Za-z0-9+\/=]+)$/

      def self.needs_change?(current : String?, desired : String?, user : String, server_encryption : String) : Bool
        return false unless desired

        if desired.empty?
          return !current.nil?
        end

        if desired =~ SCRAM_SHA256_REGEX
          return desired != current
        end

        if current && (stored = current.match(SCRAM_SHA256_REGEX))
          return !scram_verifier_matches?(stored, desired)
        end

        if md5_verifier_format?(desired)
          return desired != current
        end

        case server_encryption
        when "md5"
          md5_verifier(user, desired) != current
        when "scram-sha-256"
          true
        else
          false
        end
      end

      # Recomputes the stored verifier's ServerKey from the plaintext.
      # The password is hashed verbatim - exactly what the server hashed
      # when the verifier was created (no saslprep, matching CREATE
      # USER/ALTER ROLE's own verifier generation; saslprep only applies
      # during SASL authentication itself). A malformed verifier falls
      # back to "different" - the real module's same except-clause.
      def self.scram_verifier_matches?(stored : Regex::MatchData, plaintext : String) : Bool
        iterations = stored[1].to_i
        salt = Base64.decode(stored[2])
        server_key = Base64.decode(stored[4])
        salted_password = OpenSSL::PKCS5.pbkdf2_hmac(plaintext, salt, iterations, OpenSSL::Algorithm::SHA256, 32)
        OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, salted_password, "Server Key") == server_key
      rescue
        false
      end

      def self.md5_verifier(user : String, plaintext : String) : String
        "md5" + Digest::MD5.hexdigest(plaintext + user)
      end

      # Real module's is_pg_passwd_md5: "md5" prefix + 32 hex digits.
      def self.md5_verifier_format?(value : String) : Bool
        value.size == 35 && value.starts_with?("md5") && value[3, 32].chars.all?(&.hex?)
      end
    end
  end
end
