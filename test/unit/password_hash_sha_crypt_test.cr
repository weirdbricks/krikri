require "../minitest_helper"
require "../../src/krikri/variable_substitutor"

# ansible-core 2.21 hashes through libxcrypt instead of passlib, which
# changes the OUTPUT of a user-supplied salt: libxcrypt re-encodes the salt
# bytes with crypt's base64 and always writes the scheme's rounds/cost
# marker. Every expectation below is the output of a real 2.21.6 run
# (`ansible-playbook` on this host, same libcrypt).
describe "Krikri::VarSubstitutor::FilterCore.password_hash (libxcrypt)" do
  it "re-encodes the salt and keeps sha512's default rounds marker" do
    Krikri::VariableSubstitutor::FilterCore.password_hash("hello", "sha512", "mysalt")
      .must_equal("$6$rounds=656000$hZrQ$pHtC7xLocYGK7GZJsMh2WFqgHywV.q6jHM3uHVKbOx9zJzm7QViLInfJ12Ji3j4tIiAhprbEFUW.0DhUaBSAp1")
  end

  it "does the same for sha256" do
    Krikri::VariableSubstitutor::FilterCore.password_hash("hello", "sha256", "mysalt")
      .must_equal("$5$rounds=535000$hZrQ$FmC/9WaSUo2gDz6P0EwAlh7lqHucptGCb6JFpEqMAk5")
  end

  it "hashes md5 through the same backend" do
    Krikri::VariableSubstitutor::FilterCore.password_hash("hello", "md5", "salt1234")
      .must_equal("$1$n34Po3XA$K/u1LN/U7QRO89Ve2dXQi0")
  end

  it "supports bcrypt, which 2.21 gained with the libxcrypt backend" do
    Krikri::VariableSubstitutor::FilterCore.password_hash("hello", "bcrypt", "abcdefghijklmnopqrstuv")
      .must_equal("$2b$12$WUHhXETkX0fnYkrqZU3ta.hFIbHnUuRU.NZri1qesIxZDfk44YjJu")
  end

  it "honors libxcrypt's own rounds floor" do
    # libxcrypt clamps anything below 1000 up to 1000 (live-verified).
    Krikri::VariableSubstitutor::FilterCore.password_hash("hello", "sha512", "mysalt", nil, JSON::Any.new(999_i64))
      .matches?(/^\$6\$rounds=1000\$/).must_equal(true)
  end

  it "rejects a scheme the password_hash filter never exposed" do
    assert_raises_message(Exception, "yescrypt is not in the list of supported passlib algorithms: md5, blowfish, sha256, sha512") do
      Krikri::VariableSubstitutor::FilterCore.password_hash("hello", "yescrypt")
    end
  end

  it "rejects a salt longer than the scheme allows" do
    assert_raises_message(Exception, "invalid salt size supplied (17), expected at most 16") do
      Krikri::VariableSubstitutor::FilterCore.password_hash("hello", "sha512", "x" * 17)
    end
  end
end
