require "../minitest_helper"
require "../../src/krikri/variable_substitutor"

# password_hash's sha256/sha512 types go through passlib in Ansible -
# whose own DEFAULT rounds (535000/656000) show in the output's rounds=
# prefix even when only a salt was given (openssl passwd's fixed
# 5000-round hash diverged byte for byte). Known-answer vectors captured
# from passlib (== ansible-playbook 2.19.11 output, live-verified).
describe "Krikri::VarSubstitutor::FilterCore.password_hash (passlib-compatible sha-crypt)" do
  it "hashes sha512 with passlib's default rounds" do
    Krikri::VariableSubstitutor::FilterCore.password_hash("hello", "sha512", "mysalt")
      .must_equal("$6$rounds=656000$mysalt$mMWk1/71/712cx6xA3/Cq1qE0R7B2BDA2FPgmbySa7l3J4.y2eYwItEJRJZFDSUdAB3o/rIM.TZR3qDHk9Vp5/")
  end

  it "hashes sha256 with passlib's default rounds" do
    Krikri::VariableSubstitutor::FilterCore.password_hash("hello", "sha256", "mysalt")
      .must_equal("$5$rounds=535000$mysalt$w1QrE//RvCPjpCsmz.J/bih1OCrx7mmpPLAc/111C5.")
  end

  it "still hashes md5 through openssl" do
    Krikri::VariableSubstitutor::FilterCore.password_hash("hello", "md5", "salt1234")
      .must_equal("$1$salt1234$IubdVvT53nF05lWUJa9NC0")
  end
end
