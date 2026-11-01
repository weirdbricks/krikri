require "../minitest_helper"

# Regression spec for issue #715 (justereseau.users): user.py's
# check_password_encrypted() warns on every run when `password` does not look
# like a crypt hash. Exercised through the real plugin in check mode against
# the current account so nothing is modified.
private TEST_USER_715 = ENV["USER"]?.try(&.empty?) == false ? ENV["USER"] : `id -un`.strip

describe "user plugin unhashed password warning" do
  it "warns when the password is plaintext" do
    result = PluginSpecHelper.run("user", {
      "name"                => TEST_USER_715,
      "password"            => "dssdsds",
      "_ansible_check_mode" => "true",
    })
    result["warnings"].as_a.map(&.as_s).must_include(
      "The input password appears not to have been hashed. The 'password' argument must be encrypted for this module to work properly.")
  end

  it "does not warn for a well-formed sha512 hash" do
    result = PluginSpecHelper.run("user", {
      "name"                => TEST_USER_715,
      "password"            => "$6$salt$" + "a" * 86,
      "_ansible_check_mode" => "true",
    })
    result["warnings"]?.must_be_nil
  end
end
