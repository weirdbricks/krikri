require "../spec_helper"
require "../../src/krikri/plugin_helpers/postgresql_password_verifier"

# Unit-tests postgresql_user's password-idempotency decision (the port of
# real community.postgresql.postgresql_user's
# user_should_we_change_password) against known SCRAM/MD5 verifier
# fixtures - no live server needed. The fixtures below were generated
# with the same RFC 5802 arithmetic PostgreSQL's own
# pg_authid.rolpassword uses (SaltedPassword = Hi(password, salt, i),
# ServerKey = HMAC(SaltedPassword, "Server Key"), StoredKey =
# SHA256(ClientKey)).
S3CRETPW_4096  = "SCRAM-SHA-256$4096:c2FsdDEyMzQ=$lNupe85ZNfVenWjoHjLdFS2FA3Xvqi8eGqZMYsJKxJI=:tseefbDYwMidnWO1jAFXTszxJya6j/Mff1XC7Y8PYmY="
S3CRETPW_7777  = "SCRAM-SHA-256$7777:c2FsdDEyMzQ=$/hxDyK3Q8KV/Xt282Ul1UeDzPVEKBm6YJrIk8TZf42k=:uM7q5SlKrf4L2MViKYO9U/l5XzFrf388kRJm7SKS1/w="
MYPW_ALICE_MD5 = "md5e17a4ffca30d594167b448936ec3f80c" # md5("mypw" + "alice")

Verifier = Krikri::PluginHelpers::PostgresqlPasswordVerifier

describe Krikri::PluginHelpers::PostgresqlPasswordVerifier do
  describe ".needs_change?" do
    it "is false when no password is requested" do
      Verifier.needs_change?(S3CRETPW_4096, nil, "alice", "scram-sha-256").should be_false
      Verifier.needs_change?(nil, nil, "alice", "scram-sha-256").should be_false
    end

    it "treats an empty desired password as 'no change' only when nothing is stored" do
      Verifier.needs_change?(nil, "", "alice", "scram-sha-256").should be_false
      Verifier.needs_change?(S3CRETPW_4096, "", "alice", "scram-sha-256").should be_true
    end

    it "compares a desired SCRAM verifier string verbatim against the stored one" do
      Verifier.needs_change?(S3CRETPW_4096, S3CRETPW_4096, "alice", "scram-sha-256").should be_false
      Verifier.needs_change?(S3CRETPW_4096, S3CRETPW_7777, "alice", "scram-sha-256").should be_true
      Verifier.needs_change?(nil, S3CRETPW_4096, "alice", "scram-sha-256").should be_true
    end

    it "recomputes the SCRAM ServerKey from a plaintext against a stored SCRAM verifier" do
      # Same password, same salt/iterations as the stored verifier -> the
      # recomputed ServerKey matches and the repeat call must be a no-op.
      Verifier.needs_change?(S3CRETPW_4096, "s3cretpw", "alice", "scram-sha-256").should be_false
      # Same plaintext but a verifier hashed at different iterations/salt
      # layout still matches because salt+iterations come from the stored
      # string itself.
      Verifier.needs_change?(S3CRETPW_7777, "s3cretpw", "alice", "scram-sha-256").should be_false
      # Different plaintext -> change.
      Verifier.needs_change?(S3CRETPW_4096, "wrongpw", "alice", "scram-sha-256").should be_true
      # Plaintext against a role with no stored password -> change.
      Verifier.needs_change?(nil, "s3cretpw", "alice", "scram-sha-256").should be_true
    end

    it "compares a desired MD5 verifier verbatim, regardless of server default" do
      Verifier.needs_change?(MYPW_ALICE_MD5, MYPW_ALICE_MD5, "alice", "scram-sha-256").should be_false
      Verifier.needs_change?(MYPW_ALICE_MD5, "md5d41d8cd98f00b204e9800998ecf8427e", "alice", "scram-sha-256").should be_true
    end

    it "computes PostgreSQL's md5(password + username) form for plaintext vs a server whose default is md5" do
      Verifier.needs_change?(MYPW_ALICE_MD5, "mypw", "alice", "md5").should be_false
      Verifier.needs_change?(MYPW_ALICE_MD5, "otherpw", "alice", "md5").should be_true
      # The username is part of the md5 form - the same password for a
      # different role name hashes differently.
      Verifier.needs_change?(MYPW_ALICE_MD5, "mypw", "bob", "md5").should be_true
    end

    it "always reports changed for plaintext against a non-md5 verifier the recomputation cannot check" do
      # Stored value is a legacy non-SCRAM form while the server default
      # is scram-sha-256 - real Ansible's own behavior (issue #688).
      Verifier.needs_change?(MYPW_ALICE_MD5, "s3cretpw", "alice", "scram-sha-256").should be_true
    end

    it "treats a 'md5'-prefixed string that is not a 35-char hex digest as plaintext" do
      # 34 chars - fails the length check, so it is hashed as a plaintext.
      not_a_verifier = "md5" + "x" * 31
      Verifier.needs_change?(MYPW_ALICE_MD5, not_a_verifier, "alice", "md5").should be_true
    end
  end

  describe ".scram_verifier_matches?" do
    it "accepts the plaintext that produced the verifier" do
      stored = S3CRETPW_4096.match!(Krikri::PluginHelpers::PostgresqlPasswordVerifier::SCRAM_SHA256_REGEX)
      Verifier.scram_verifier_matches?(stored, "s3cretpw").should be_true
      Verifier.scram_verifier_matches?(stored, "s3cretpw ").should be_false
    end

    it "falls back to 'different' on a malformed verifier" do
      # The salt is not valid base64 (wrong length for its char set) ->
      # rescue -> false (treat as different), matching the real module's
      # except-clause.
      malformed = "SCRAM-SHA-256$4096:abcde$abc:def"
      stored = malformed.match!(Krikri::PluginHelpers::PostgresqlPasswordVerifier::SCRAM_SHA256_REGEX)
      Verifier.scram_verifier_matches?(stored, "s3cretpw").should be_false
    end
  end

  describe ".md5_verifier_format?" do
    it "accepts md5 + 32 hex digits only" do
      Verifier.md5_verifier_format?(MYPW_ALICE_MD5).should be_true
      Verifier.md5_verifier_format?("md5" + "g" * 32).should be_false
      Verifier.md5_verifier_format?("md5abc").should be_false
      Verifier.md5_verifier_format?("plaintext").should be_false
    end
  end
end
